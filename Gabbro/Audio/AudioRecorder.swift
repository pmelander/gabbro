// @preconcurrency because AVFAudio is not Sendable-annotated: AVAudioPCMBuffer
// and AVAudioConverter cross the tap callback boundary by design, and the
// compiler cannot know the audio thread owns them exclusively. The compiler
// itself suggests this import for exactly this case.
@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog
import QuartzCore
import UIKit

/// Converts and writes on the audio thread, with no actor hop per buffer.
///
/// The first version of this hopped to `@MainActor` inside the tap callback.
/// At 4096 frames on a 48 kHz input that is roughly twelve scheduling hops a
/// second on a real-time thread, which is exactly the thing not to do in an
/// audio callback — and it was also what produced the captured-var and
/// non-Sendable-buffer warnings. Conversion is synchronous here; the UI is
/// notified on a throttle instead.
private final class AudioTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private let target: AVAudioFormat
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var appending = false

    init(target: AVAudioFormat) { self.target = target }

    func begin(writer: WAVWriter, inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
        self.converter = AVAudioConverter(from: inputFormat, to: target)
        self.appending = true
    }

    /// Stop appending, but leave the file open. Used when the engine must keep
    /// running past Stop so the tail chunk can finish inside a live session.
    func stopAppending() {
        lock.lock(); defer { lock.unlock() }
        appending = false
    }

    func finalizeSegment() -> Int {
        lock.lock(); defer { lock.unlock() }
        appending = false
        let frames = writer?.frameCount ?? 0
        try? writer?.finalizeAndClose()
        writer = nil
        converter = nil
        return frames
    }

    /// Called on the audio thread. Returns the segment's frame count, or nil
    /// when not appending (which is the normal state during the tail window).
    func consume(_ buffer: AVAudioPCMBuffer) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard appending, let converter, let writer else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return writer.frameCount
        }

        var error: NSError?
        var supplied = false
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else {
            return writer.frameCount
        }
        try? writer.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        return writer.frameCount
    }
}

/// Rate-limits the audio thread's hops to the main actor.
///
/// A 4096-frame buffer at 48 kHz fires roughly twelve times a second. The UI
/// does not need that, and neither does the disk-space check.
private final class SyncThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: CFTimeInterval
    private var last: CFTimeInterval = 0

    init(interval: CFTimeInterval) { self.interval = interval }

    func shouldFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}

/// Microphone capture into durable, segmented Int16 WAV on disk.
///
/// The subtle part is `stop()`. Read the comment there before changing it.
///
/// `@Observable`, not `ObservableObject`, and that is load-bearing:
/// `CaptureModel` is `@Observable` and holds this. SwiftUI's Observation
/// tracking does not bridge into a nested `ObservableObject` -- reading
/// `model.recorder.isRecording` in a view would track `recorder` and then
/// read `isRecording` off something the view is not subscribed to. The state
/// flipped and nothing redrew: tapping record started a recording with no
/// visible change whatsoever.
@MainActor
@Observable
public final class AudioRecorder {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Recorder")

    private let engine = AVAudioEngine()
    private let sessionManager = AudioSessionManager()
    private var sink: AudioTapSink?

    public private(set) var job: RecordingJob?
    public private(set) var isRecording = false

    /// UI/state sync is throttled rather than per-buffer. See `SyncThrottle`.
    private static let syncInterval: CFTimeInterval = 0.5

    /// True from the start of `releaseEngine()` onward.
    ///
    /// `AVAudioSession.setActive(false)` can itself post an interruption
    /// notification, which re-enters `finalizeCurrentSegment()` — and because
    /// the writer is already gone by then, it reported a frame count of zero
    /// and overwrote the real length of the segment just recorded. Silent data
    /// loss, not a crash, which is worse.
    private var isTearingDown = false

    /// True between entering `start()` and the tap being live.
    ///
    /// Without it, two taps on the record button spawn two Tasks, both reach
    /// `installTapOnBus`, and the second raises an ObjC exception —
    /// uncatchable from Swift, so the process aborts. That is exactly what
    /// happened when the button looked dead during the model download and got
    /// tapped again.
    private var isStarting = false

    public init() {
        sessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTearingDown else { return }
                self.finalizeCurrentSegment()
            }
        }
        sessionManager.onInterruptionEndedShouldResume = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTearingDown, self.isRecording else { return }
                try? await self.openNewSegment()
            }
        }
        sessionManager.onRouteChanged = { [weak self] route in
            Task { @MainActor in
                guard let self, !self.isTearingDown else { return }
                self.job?.inputRoute = route
            }
        }
    }

    // MARK: - Start

    public func start() async throws {
        // Re-entry guard first. Everything below assumes a single caller.
        guard !isRecording, !isStarting else {
            log.notice("start() ignored: already recording or starting")
            return
        }
        isStarting = true
        defer { isStarting = false }

        // Last line of defence. The foreground path in CaptureModel prompts
        // before reaching here; an intent-driven start cannot prompt, so it
        // arrives here and fails with a message that says the right thing.
        switch AudioSessionManager.micPermission {
        case .granted: break
        case .undetermined: throw RecorderError.microphonePermissionNotRequested
        case .denied: throw RecorderError.microphonePermissionDenied
        }
        // nonisolated on the actor — no await, it is a plain synchronous read.
        guard JobStore.shared.hasRoomToStart() else {
            throw RecorderError.insufficientStorage
        }

        isTearingDown = false
        try sessionManager.activate()

        var newJob = RecordingJob(inputRoute: sessionManager.currentRoute())
        newJob.state = .recording
        self.job = newJob
        try await JobStore.shared.upsert(newJob)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WAVWriter.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.formatUnavailable }

        sink = AudioTapSink(target: target)
        try await openNewSegment()
        try installTapAndStart()

        isRecording = true
        log.notice("Recording started, job \(newJob.id, privacy: .public)")
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // installTapOnBus raises an ObjC exception rather than throwing, and
        // Swift cannot catch that — it is an immediate abort. So rule out both
        // of its causes here, where we can fail cleanly instead.
        //
        // 1. A tap already on the bus. Removing when none is installed is a
        //    no-op, so this is free insurance.
        input.removeTap(onBus: 0)
        // 2. A degenerate format, which is what you get when the session is
        //    not active or the microphone is held by something else.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }

        guard let sink else { throw RecorderError.formatUnavailable }
        let throttle = SyncThrottle(interval: Self.syncInterval)

        // Capture `sink` and `throttle` directly. Do NOT reach back through
        // `self` for main-actor state here: this closure runs on the audio
        // thread, so `MainActor.assumeIsolated` would trap at runtime rather
        // than politely fail.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let frames = sink.consume(buffer) else { return }
            guard throttle.shouldFire() else { return }
            Task { @MainActor in self?.syncSegmentLength(frames: frames) }
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: - Segments

    private func openNewSegment() async throws {
        guard var current = job, let sink else { return }
        let index = current.segments.count
        let name = "\(current.id.uuidString)-\(index).wav"
        let url = JobStore.shared.audioDirectory.appendingPathComponent(name)
        let writer = try WAVWriter(creatingAt: url)
        sink.begin(writer: writer, inputFormat: engine.inputNode.outputFormat(forBus: 0))
        current.segments.append(
            .init(index: index, filename: name, frameCount: 0, transcribedFrames: 0)
        )
        job = current

        // PERSIST NOW. The segment record has to reach disk the moment the
        // file exists, or a force-quit leaves a job saying `recording` with an
        // empty segment list and a WAV on disk that nothing points at —
        // recovery then loops over zero segments and finds nothing. That is
        // exactly what happened, and it is the rule JobStore's own comment
        // states: persist before advancing state, never after.
        //
        // frameCount stays 0 here on purpose; recovery derives the real length
        // from the file on disk via WAVWriter.repairHeader, so it does not
        // need updating on every buffer.
        try await JobStore.shared.upsert(current)
    }

    private func finalizeCurrentSegment() {
        guard let sink else { return }
        let frames = sink.finalizeSegment()
        syncSegmentLength(frames: frames)
    }

    private func syncSegmentLength(frames: Int) {
        guard var current = job, !current.segments.isEmpty else { return }
        current.segments[current.segments.count - 1].frameCount = frames
        job = current

        // Disk check on the throttled path, not per buffer.
        if JobStore.shared.mustAbortForSpace() {
            log.error("Disk nearly full, aborting capture")
            Task { await self.stop(reason: .outOfSpace) }
        }
    }

    // MARK: - Stop

    public enum StopReason { case user, outOfSpace, thermal }

    /// Stop means **stop appending to the WAV**. It does not mean stop the engine.
    ///
    /// This is the load-bearing detail of the whole design, and the obvious
    /// implementation is wrong:
    ///
    /// The background execution assertion is held by `mediaserverd` only while
    /// the app is *actively recording* — while a running I/O unit is moving
    /// frames. It is NOT held by `setActive(true)`. Apple's Audio Session
    /// Programming Guide says to deactivate when not actively recording, and
    /// explicitly says to "use a background task instead of streaming silence
    /// to keep the app from being suspended".
    ///
    /// Stop arrives from the Lock Screen with the app already backgrounded, so
    /// no foreground transition stands between it and suspension — it can be
    /// suspended on the next runloop turn, mid-inference.
    ///
    /// Two mechanisms, both required:
    ///   1. Keep the tap running (discarding buffers) until the job is `.ready`.
    ///   2. Take `beginBackgroundTask` FIRST, before tearing anything down.
    ///
    /// Booked consequence: the orange mic indicator and the recording Live
    /// Activity stay lit for several seconds after Stop. Expected, needs a
    /// line of UI explanation, and will otherwise read as a bug during
    /// criterion 2 and 6 testing.
    /// The background task is NOT taken here. It is taken by
    /// `CaptureModel.stop()` and held across the whole tail — transcription,
    /// render, engine teardown — because that is the work that needs
    /// protecting. Taking it here and releasing it at the end of this method
    /// (the first version) wrapped only the segment finalize and expired
    /// before the inference it existed to cover.
    public func stop(reason: StopReason = .user) async {
        guard isRecording else { return }

        finalizeCurrentSegment()

        if var current = job {
            current.state = .captured
            if reason == .outOfSpace { current.promiseWithdrawnReason = "Storage full" }
            job = current
            try? await JobStore.shared.upsert(current)
        }

        isRecording = false
        log.notice("Stopped (\(String(describing: reason), privacy: .public)); tap still running for tail")
    }

    /// Called from the background-task expiration handler in `CaptureModel`.
    /// Persists as `captured` so the next launch finishes the transcript
    /// rather than losing it.
    public func markCapturedOnExpiry() async {
        guard var current = job else { return }
        current.state = .captured
        current.promiseWithdrawnReason = "Backgrounded before the transcript finished"
        job = current
        try? await JobStore.shared.upsert(current)
    }

    /// Tears down the engine and the audio session. Call ONLY once the job has
    /// reached `.ready` — never at Stop.
    public func releaseEngine() {
        isTearingDown = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sessionManager.deactivate()
        sink = nil
        log.notice("Engine stopped and session deactivated")
    }
}

public enum RecorderError: LocalizedError {
    /// Explicitly refused, or refused at the prompt. Settings is the route back.
    case microphonePermissionDenied
    /// Never requested, and we are somewhere that cannot prompt — i.e. a Lock
    /// Screen intent. Telling the user to visit Settings here would be a dead
    /// end: iOS has no entry to show until the app has asked.
    case microphonePermissionNotRequested
    case insufficientStorage
    case formatUnavailable
    /// The input node reported a zero format — session inactive, or the
    /// microphone is being held by another app.
    case inputUnavailable

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone > Gabbro."
        case .microphonePermissionNotRequested:
            "Open Gabbro and press record once to grant microphone access. It cannot be granted from the Lock Screen."
        case .insufficientStorage:
            "Not enough free space to start recording."
        case .formatUnavailable:
            "Could not create the 16 kHz mono capture format."
        case .inputUnavailable:
            "The microphone is not available right now. Another app may be using it."
        }
    }
}
