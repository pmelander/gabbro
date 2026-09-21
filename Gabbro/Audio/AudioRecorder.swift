import AVFoundation
import Foundation
import OSLog
import UIKit

/// Microphone capture into durable, segmented Int16 WAV on disk.
///
/// The subtle part is `stop()`. See the comment there before changing it.
@MainActor
public final class AudioRecorder: ObservableObject {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Recorder")

    private let engine = AVAudioEngine()
    private let sessionManager = AudioSessionManager()
    private var converter: AVAudioConverter?
    private var writer: WAVWriter?

    /// True while the tap should append to disk. Goes false at Stop, while the
    /// tap itself keeps running.
    private var isAppending = false

    @Published public private(set) var job: RecordingJob?
    @Published public private(set) var isRecording = false

    public var onSegmentGrew: ((Int) -> Void)?

    public init() {
        sessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor in self?.finalizeCurrentSegment() }
        }
        sessionManager.onInterruptionEndedShouldResume = { [weak self] in
            Task { @MainActor in try? self?.openNewSegment() }
        }
        sessionManager.onRouteChanged = { [weak self] route in
            Task { @MainActor in self?.job?.inputRoute = route }
        }
    }

    // MARK: - Start

    public func start() async throws {
        guard AudioSessionManager.hasMicrophonePermission() else {
            throw RecorderError.microphonePermissionDenied
        }
        guard await JobStore.shared.hasRoomToStart() else {
            throw RecorderError.insufficientStorage
        }

        try sessionManager.activate()

        var newJob = RecordingJob(inputRoute: sessionManager.currentRoute())
        self.job = newJob
        try await JobStore.shared.upsert(newJob)

        try openNewSegment()
        try installTapAndStart()

        isRecording = true
        isAppending = true
        newJob.state = .recording
        self.job = newJob
        log.notice("Recording started, job \(newJob.id, privacy: .public)")
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // The input node is typically 48 kHz. Parakeet wants 16 kHz mono
        // Float32; Int16 conversion happens at the disk boundary in WAVWriter.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WAVWriter.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.formatUnavailable }

        converter = AVAudioConverter(from: inputFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, target: target)
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated func handle(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        Task { @MainActor [weak self] in
            guard let self, self.isAppending, let converter = self.converter,
                  let writer = self.writer else { return }

            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

            var error: NSError?
            var supplied = false
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0,
                  let channel = out.floatChannelData?[0] else { return }

            do {
                try writer.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
                self.syncSegmentLength()
                if await JobStore.shared.mustAbortForSpace() {
                    self.log.error("Disk nearly full, aborting capture")
                    await self.stop(reason: .outOfSpace)
                }
            } catch {
                self.log.error("Write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Segments

    private func openNewSegment() throws {
        guard var current = job else { return }
        let index = current.segments.count
        let name = "\(current.id.uuidString)-\(index).wav"
        let url = JobStore.shared.audioDirectory.appendingPathComponent(name)
        writer = try WAVWriter(creatingAt: url)
        current.segments.append(
            .init(index: index, filename: name, frameCount: 0, transcribedFrames: 0)
        )
        job = current
    }

    private func finalizeCurrentSegment() {
        isAppending = false
        try? writer?.finalizeAndClose()
        syncSegmentLength()
        writer = nil
    }

    private func syncSegmentLength() {
        guard var current = job, let writer, !current.segments.isEmpty else { return }
        current.segments[current.segments.count - 1].frameCount = writer.frameCount
        job = current
        onSegmentGrew?(writer.frameCount)
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
    /// there is no foreground transition standing between it and suspension —
    /// it can be suspended on the next runloop turn, mid-inference.
    ///
    /// Two mechanisms, both required:
    ///   1. Keep the tap running (discarding buffers) until the job is `.ready`.
    ///   2. Take `beginBackgroundTask` FIRST, before tearing anything down.
    ///
    /// Booked consequence: the orange mic indicator and the recording Live
    /// Activity stay lit for several seconds after the user presses Stop. That
    /// is expected, needs a line of UI explanation, and will otherwise read as
    /// a bug during criterion 2 and 6 testing.
    public func stop(reason: StopReason = .user) async {
        guard isRecording else { return }

        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "gabbro.tail") { [weak self] in
            // Expiry: persist as `captured` so the next launch finishes it.
            // Never let the system kill us mid-write.
            Task { @MainActor in await self?.markCapturedOnExpiry() }
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        isAppending = false
        finalizeCurrentSegment()

        if var current = job {
            current.state = .captured
            if reason == .outOfSpace { current.promiseWithdrawnReason = "Storage full" }
            job = current
            try? await JobStore.shared.upsert(current)
        }

        isRecording = false
        log.notice("Stopped (\(String(describing: reason), privacy: .public)); tap still running for tail")

        // The caller (TranscriptionCoordinator) drains the tail, renders, and
        // then calls `releaseEngine()`. Only at that point does the session go.
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
    }

    private func markCapturedOnExpiry() async {
        guard var current = job else { return }
        current.state = .captured
        current.promiseWithdrawnReason = "Backgrounded before the transcript finished"
        job = current
        try? await JobStore.shared.upsert(current)
    }

    /// Tears down the engine and the audio session. Call ONLY once the job has
    /// reached `.ready` — not at Stop.
    public func releaseEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sessionManager.deactivate()
        log.notice("Engine stopped and session deactivated")
    }
}

public enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case insufficientStorage
    case formatUnavailable

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Open Gabbro and grant it in Settings."
        case .insufficientStorage:
            "Not enough free space to start recording."
        case .formatUnavailable:
            "Could not create the 16 kHz mono capture format."
        }
    }
}
