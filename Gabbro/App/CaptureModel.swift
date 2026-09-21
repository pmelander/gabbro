import ActivityKit
import Foundation
import Observation
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

    public func bootstrap() async {
        RecordingControl_Registry.handler = self
        do {
            try await JobStore.shared.prepare()
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
        do {
            try await coordinator.prepare()
            try await recorder.start()
            if let job = recorder.job {
                await M0Telemetry.shared.begin(jobID: job.id, inferenceEnabled: inferenceEnabled)
                await startActivity(for: job)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() async {
        await recorder.stop()
        guard var job = recorder.job else { return }

        await updateActivity(phase: .finishing, job: job)
        if inferenceEnabled {
            job = await coordinator.drain(job: job)
        } else {
            // Battery-baseline run: capture and store, transcribe nothing.
            job.state = .captured
            job.promiseWithdrawnReason = "Battery baseline run — inference disabled"
        }
        try? await JobStore.shared.upsert(job)

        if job.state == .ready {
            _ = try? renderer.write(
                job: job,
                modelRevision: ParakeetTranscriber.modelRevision,
                to: JobStore.shared.notesDirectory
            )
        }

        // Only now: the tail is done, so the engine and session can go.
        recorder.releaseEngine()
        // Written after releaseEngine so the report covers the full tail
        // window — the part of the run most likely to be suspended.
        await M0Telemetry.shared.end(outcome: job.state.rawValue)
        await updateActivity(phase: job.state == .ready ? .ready : .failed, job: job)
        await endActivity()

        jobs = await JobStore.shared.all()
        if job.state != .ready { await notifyUnfinished(job) }
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

    /// The file URL handed to `ShareLink`. A file URL, never `Data` or
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
