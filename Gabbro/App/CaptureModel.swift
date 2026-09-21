import ActivityKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Ties recorder, coordinator and Live Activity together. One instance, owned
/// by the app, reachable from the App Intents (which run in the app's process
/// when declared in the app target — that is what makes an intent-driven
/// start possible at all).
@MainActor
@Observable
public final class CaptureModel: RecordingControlHandling {
    public static let shared = CaptureModel()

    public let recorder = AudioRecorder()
    private let coordinator: TranscriptionCoordinator
    private let renderer = MarkdownRenderer()

    public private(set) var jobs: [RecordingJob] = []
    public private(set) var lastError: String?
    private var activity: Activity<RecordingActivityAttributes>?

    private init() {
        // Swap to ParakeetTranscriber() once the M0 step 1 checklist in
        // ParakeetTranscriber.swift is answered. The stub is the sanctioned
        // early fake — pipeline first, model second.
        self.coordinator = TranscriptionCoordinator(transcriber: StubTranscriber())
    }

    // MARK: - RecordingControlHandling
    //
    // Registered at launch so the shared intents — compiled into both targets
    // but executed in this process — can reach app-only code.

    public func startCapture() async throws { await start() }
    public func stopCapture() async { await stop() }
    public nonisolated func microphoneIsAuthorized() -> Bool {
        AudioSessionManager.hasMicrophonePermission()
    }

    /// Set when the previous run died mid-sequence. Shown in the UI so a
    /// crash cannot pass unnoticed with no debugger attached.
    public private(set) var lastCrashStage: String?

    public func bootstrap() async {
        RecordingControl_Registry.handler = self
        do {
            try await JobStore.shared.prepare()

            // Read the trail before anything else can overwrite it. A trail
            // that does not end in a completion marker means the previous run
            // died at that stage.
            if let trail = Breadcrumbs.readAndClear() {
                lastCrashStage = trail.last
                await M0Telemetry.shared.noteEvent("previous run ended at \(trail.last)")
            }
            jobs = await JobStore.shared.all()
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            // Anything recovered at launch (force-quit, jetsam, or an
            // interruption whose .ended never arrived) is finished here.
            await drainPending()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Capture

    /// Set false to produce the battery baseline M0's battery gate compares
    /// against: same 20-minute locked capture, inference disabled. An absolute
    /// battery number means nothing; the ratio is the decision.
    public var inferenceEnabled = true

    public func start() async {
        // Ask before checking. This is the foreground path, so it is the only
        // place that CAN prompt — the Lock Screen intent cannot, which is why
        // it only ever checks.
        //
        // Without this the app checked a permission it had never requested,
        // found `.undetermined`, and told the user to grant it in Settings —
        // where no toggle existed, because iOS does not list an app under
        // Privacy -> Microphone until the app has actually asked.
        switch AudioSessionManager.micPermission {
        case .undetermined:
            guard await AudioSessionManager.requestMicrophonePermission() else {
                lastError = RecorderError.microphonePermissionDenied.errorDescription
                return
            }
        case .denied:
            lastError = RecorderError.microphonePermissionDenied.errorDescription
            return
        case .granted:
            break
        }

        Breadcrumbs.drop(Breadcrumbs.Marker.startBegin)
        do {
            try await coordinator.prepare()
            try await recorder.start()
            if let job = recorder.job {
                await M0Telemetry.shared.begin(jobID: job.id, inferenceEnabled: inferenceEnabled)
                await startActivity(for: job)
            }
            Breadcrumbs.drop(Breadcrumbs.Marker.startDone)
        } catch {
            lastError = error.localizedDescription
            Breadcrumbs.drop(Breadcrumbs.Marker.startDone)
        }
    }

    public func stop() async {
        // Held across the ENTIRE tail: transcription, render, and engine
        // teardown. This is the mechanism premise 7 rests on — an active
        // audio session alone does not hold background execution, only a
        // running I/O unit does, and Stop can arrive from the Lock Screen
        // with the app already backgrounded.
        Breadcrumbs.drop(Breadcrumbs.Marker.stopBegin)

        // The expiration handler MUST end the task synchronously before it
        // returns. Apple is explicit: fail to, and the system terminates the
        // app. The first version only kicked off an async Task and returned,
        // which is that termination path exactly.
        let taskBox = BackgroundTaskBox()
        taskBox.id = UIApplication.shared.beginBackgroundTask(withName: "gabbro.tail") { [weak self] in
            Breadcrumbs.drop("stop:bgtask-expired")
            Task { @MainActor in await self?.recorder.markCapturedOnExpiry() }
            taskBox.end()          // synchronous, before returning
        }
        defer { taskBox.end() }    // idempotent

        await recorder.stop()
        Breadcrumbs.drop(Breadcrumbs.Marker.stopRecorderStopped)
        guard var job = recorder.job else { return }

        await updateActivity(phase: .finishing, job: job)
        Breadcrumbs.drop(Breadcrumbs.Marker.stopDrainBegin)
        if inferenceEnabled {
            job = await coordinator.drain(job: job)
        } else {
            // Battery-baseline run: capture and store, transcribe nothing.
            job.state = .captured
            job.promiseWithdrawnReason = "Battery baseline run — inference disabled"
        }
        Breadcrumbs.drop(Breadcrumbs.Marker.stopDrainDone)
        try? await JobStore.shared.upsert(job)

        if job.state == .ready {
            _ = try? renderer.write(
                job: job,
                modelRevision: ParakeetTranscriber.modelRevision,
                to: JobStore.shared.notesDirectory
            )
        }
        Breadcrumbs.drop(Breadcrumbs.Marker.stopRendered)

        // Only now: the tail is done, so the engine and session can go.
        recorder.releaseEngine()
        Breadcrumbs.drop(Breadcrumbs.Marker.stopEngineReleased)
        // Written after releaseEngine so the report covers the full tail
        // window — the part of the run most likely to be suspended.
        await M0Telemetry.shared.end(outcome: job.state.rawValue)
        Breadcrumbs.drop(Breadcrumbs.Marker.stopTelemetryWritten)
        await updateActivity(phase: job.state == .ready ? .ready : .failed, job: job)
        await endActivity()
        Breadcrumbs.drop(Breadcrumbs.Marker.stopActivityEnded)

        jobs = await JobStore.shared.all()
        if job.state != .ready { await notifyUnfinished(job) }
        Breadcrumbs.drop(Breadcrumbs.Marker.stopDone)
    }

    /// Holds a background task id so the expiration handler can end it
    /// synchronously without capturing a local `var` it also assigns to.
    /// `end()` is idempotent, because both the handler and the `defer` call it.
    private final class BackgroundTaskBox {
        private let lock = NSLock()
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            lock.lock(); defer { lock.unlock() }
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private func drainPending() async {
        for pending in await JobStore.shared.pendingWork() {
            let finished = await coordinator.drain(job: pending)
            try? await JobStore.shared.upsert(finished)
            if finished.state == .ready {
                _ = try? renderer.write(
                    job: finished,
                    modelRevision: ParakeetTranscriber.modelRevision,
                    to: JobStore.shared.notesDirectory
                )
            }
        }
        jobs = await JobStore.shared.all()
    }

    // MARK: - Sharing

    /// The file URL handed to `ShareSheet`. A file URL, never `Data` or
    /// `String` — those lose the filename and can route Obsidian's share
    /// extension down a different branch.
    public func noteURL(for job: RecordingJob) -> URL? {
        let url = JobStore.shared.notesDirectory
            .appendingPathComponent(renderer.filename(for: job))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func markShared(_ job: RecordingJob) async {
        var updated = job
        updated.state = .shared
        updated.sharedAt = Date()
        try? await JobStore.shared.upsert(updated)
        jobs = await JobStore.shared.all()
    }

    /// Re-sharing is allowed but warns: Obsidian's picker will not deduplicate
    /// and you get a second note.
    public func wouldDuplicate(_ job: RecordingJob) -> Bool {
        job.state == .shared
    }

    // MARK: - Live Activity
    //
    // Mandatory, not decorative: on iOS 26 an intent conforming to
    // AudioRecordingIntent must maintain one for the duration or the system
    // stops the recording. It is also the only UI channel that reaches the
    // user while the screen is locked.

    private func startActivity(for job: RecordingJob) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            startedAt: job.createdAt, phase: .recording
        )
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(jobID: job.id),
            content: .init(state: state, staleDate: nil)
        )
    }

    private func updateActivity(phase: RecordingActivityAttributes.Phase, job: RecordingJob) async {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            startedAt: job.createdAt,
            phase: phase,
            backlogSeconds: job.backlogSeconds,
            promiseWithdrawnReason: job.promiseWithdrawnReason
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    private func endActivity() async {
        await activity?.end(nil, dismissalPolicy: .after(.now + 8))
        activity = nil
    }

    private func notifyUnfinished(_ job: RecordingJob) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording saved, transcript pending"
        content.body = job.promiseWithdrawnReason ?? "Open Gabbro to finish transcribing."
        let request = UNNotificationRequest(
            identifier: job.id.uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
