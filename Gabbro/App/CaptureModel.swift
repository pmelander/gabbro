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
    /// Recorded in the note frontmatter. Read once here rather than per write,
    /// and from the transcriber rather than a hardcoded constant, because the
    /// engine itself is currently an open question.
    private let modelIdentifier: String

    public private(set) var jobs: [RecordingJob] = []
    public private(set) var lastError: String?

    /// Where the speech model is up to.
    ///
    /// This exists because the first build shipped without it and the app was
    /// unusable: `start()` awaited a prepare that downloaded ~626 MB before
    /// returning, so the record button sat dead for minutes with nothing on
    /// screen. The source spec had already called this out -- "show a real
    /// progress indicator; this is the app's worst first-run moment".
    public enum ModelState: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }
    }
    public private(set) var modelState: ModelState = .idle

    /// Serialises the capture lifecycle against double taps.
    ///
    /// Each tap of the record button spawns its own Task, so start() and
    /// stop() could both run twice concurrently. The visible consequence was
    /// an abort inside installTapOnBus; the invisible ones would have been
    /// duplicate background tasks, duplicate telemetry runs and a job written
    /// twice.
    private var lifecycleBusy = false

    /// Which job is being transcribed right now, so the queue can show
    /// progress against the actual row rather than a detached bar.
    public private(set) var transcribingJobID: UUID?

    /// Non-nil while a transcript is being caught up, 0...1.
    ///
    /// A 25-minute recording can take many minutes to transcribe after Stop.
    /// Leaving that silent is the same mistake as the model download: the app
    /// looks hung when it is working.
    public private(set) var transcribeProgress: Double?
    private var activity: Activity<RecordingActivityAttributes>?

    private init() {
        // The real thing. StubTranscriber stays in the codebase because it
        // proved the whole capture/render/share path before the model existed,
        // and six crash-fix cycles ran through it without the model muddying
        // the picture — but nothing reaches it now.
        // The real engine. StubTranscriber stays in the codebase because it
        // proved the whole capture/render/share path before any model existed,
        // and several crash-fix cycles ran through it cleanly -- but nothing
        // reaches it now.
        let transcriber = WhisperTranscriber()
        self.coordinator = TranscriptionCoordinator(transcriber: transcriber)
        self.modelIdentifier = transcriber.modelIdentifier
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
                // Keep the WHOLE trail, not just the last line. The last line
                // says where it died; the sequence says how it got there —
                // which loop iteration, how many tokens, what offset. Readable
                // in Files under Diagnostics.
                Breadcrumbs.preserve(trail.full)
            }
            jobs = await JobStore.shared.all()
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            // Model preparation runs at LAUNCH, not on first record tap, and
            // in its own task so the UI comes up immediately and can show the
            // download. Pending jobs wait for it — they need the model too.
            Task { await self.prepareModel() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Capture

    /// Set false to produce the battery baseline M0's battery gate compares
    /// against: same 20-minute locked capture, inference disabled. An absolute
    /// battery number means nothing; the ratio is the decision.
    public var inferenceEnabled = true

    /// Downloads and loads the speech model, reporting progress as it goes.
    /// Safe to call again after a failure — that is what the Retry button does.
    public func prepareModel() async {
        guard !modelState.isReady else { return }

        // Breadcrumbs with memory readings, because a jetsam kill leaves NO
        // app crash log -- it writes JetsamEvent-<date>.ips instead, under a
        // name you will not find by searching for the app. These are written
        // synchronously, so they survive the kill and the trail says how much
        // headroom was left when it happened.
        Breadcrumbs.drop("model:prepare-begin avail=\(Self.availableMB())MB")
        modelState = .downloading(0)
        var lastDecile = -1
        do {
            try await coordinator.prepare { fraction in
                Task { @MainActor in
                    // Downloading until the bytes are in; loading and warming
                    // the model afterwards is its own wait worth naming.
                    self.modelState = fraction >= 1 ? .loading : .downloading(fraction)
                }
                // One breadcrumb per 10%, not per callback -- this fires often
                // and each one is a synchronous file write.
                let decile = Int(fraction * 10)
                if decile > lastDecile {
                    lastDecile = decile
                    Breadcrumbs.drop("model:download \(decile * 10)% avail=\(Self.availableMB())MB")
                }
            }
            Breadcrumbs.drop("model:downloaded avail=\(Self.availableMB())MB")
            modelState = .ready
            Breadcrumbs.drop("model:ready avail=\(Self.availableMB())MB")
            // Anything recovered at launch (force-quit, jetsam, or an
            // interruption whose .ended never arrived) can finish now.
            await drainPending()
        } catch {
            Breadcrumbs.drop("model:failed \(error.localizedDescription)")
            modelState = .failed(error.localizedDescription)
        }
    }

    /// Which model, and how much room is left. Shown in the UI because the
    /// model choice is the main lever when preparation dies.
    public var modelDescription: String {
        "\(modelIdentifier) · \(Self.availableMB()) MB free"
    }

    /// Headroom before jetsam, in MB. Same measurement the M0 memory gate
    /// uses, surfaced here because model load is where it is most at risk.
    nonisolated static func availableMB() -> Int {
        M0Telemetry.availableMemoryBytes() / (1024 * 1024)
    }

    public func start() async {
        guard modelState.isReady else {
            lastError = "The speech model is not ready yet."
            return
        }
        guard !lifecycleBusy, !recorder.isRecording else { return }
        lifecycleBusy = true
        defer { lifecycleBusy = false }
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
        guard !lifecycleBusy, recorder.isRecording else { return }
        lifecycleBusy = true
        defer { lifecycleBusy = false }

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
            // Split deliberately. `job = await coordinator.drain(job: job)`
            // assigns to a local that the right-hand side also reads, in an
            // async function where locals live in a heap frame and get dynamic
            // exclusivity checks. Landing the result in a separate constant
            // first means the read and the write cannot share a window.
            Breadcrumbs.drop("stop:before-drain-call")
            transcribingJobID = job.id
            let drained = await coordinator.drain(job: job, isLive: false) { fraction in
                Task { @MainActor in self.transcribeProgress = fraction }
            }
            transcribeProgress = nil
            transcribingJobID = nil
            Breadcrumbs.drop("stop:after-drain-call")
            job = drained
            Breadcrumbs.drop("stop:after-drain-assign")
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
                modelRevision: modelIdentifier,
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
    @MainActor
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

    /// Work the queue whenever the app comes to the foreground.
    ///
    /// Real-time transcription is not a requirement — a queue is fine — but
    /// only if it actually drains without being asked. Transcription can take
    /// minutes and cannot finish inside a background window, so the foreground
    /// is where it happens.
    public func resumeQueue() async {
        guard modelState.isReady, !lifecycleBusy, transcribingJobID == nil else { return }
        guard !(await JobStore.shared.pendingWork().isEmpty) else { return }
        await drainPending()
    }

    private func drainPending() async {
        for pending in await JobStore.shared.pendingWork() {
            transcribingJobID = pending.id
            let finished = await coordinator.drain(job: pending, isLive: false) { fraction in
                Task { @MainActor in self.transcribeProgress = fraction }
            }
            transcribeProgress = nil
            transcribingJobID = nil
            try? await JobStore.shared.upsert(finished)
            if finished.state == .ready {
                _ = try? renderer.write(
                    job: finished,
                    modelRevision: modelIdentifier,
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

    /// Deletes the recording, its audio and the rendered note on this device.
    ///
    /// Refuses while the job is in flight — deleting audio out from under a
    /// running transcription would leave the coordinator reading a file that
    /// no longer exists.
    public func delete(_ job: RecordingJob) async {
        guard transcribingJobID != job.id,
              !(recorder.isRecording && recorder.job?.id == job.id) else {
            lastError = "That recording is still being worked on."
            return
        }
        if let url = noteURL(for: job) {
            try? FileManager.default.removeItem(at: url)
        }
        try? await JobStore.shared.delete(job.id)
        jobs = await JobStore.shared.all()
    }

    /// True when deleting would destroy the only copy — the transcript has not
    /// reached the vault yet, so there is nothing to fall back on. Drives
    /// whether the UI asks first.
    public func deleteIsLastCopy(_ job: RecordingJob) -> Bool {
        job.state != .shared
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
