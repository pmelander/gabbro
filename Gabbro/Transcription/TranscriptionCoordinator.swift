import Foundation
import OSLog

/// Drives inference **during** capture, not after it.
///
/// This is what closes the post-Stop background problem rather than working
/// around it. While the audio session is live, `UIBackgroundModes: audio`
/// legitimately covers execution — so chunks are transcribed as they close,
/// and by the time the user hits Stop only the tail remains (≤ 12 s of audio,
/// ~6 s of work at the 2x speed gate).
///
/// The record-then-transcribe alternative guarantees the problem: minutes of
/// ANE inference owed at exactly the moment the assertion is weakest.
public actor TranscriptionCoordinator {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Coordinator")

    private let transcriber: Transcriber
    private let renderer = MarkdownRenderer()
    private var thermal = ThermalPolicy()

    // MARK: Backpressure thresholds
    //
    // Two, and the first is DERIVED rather than picked. At the 2x speed gate,
    // 8 s of audio is ~4 s of work, and 4 s plus render must fit inside
    // criterion 6's 10 s. Criterion 6 keys off this one.
    public static let promiseThresholdSeconds: Double = 8.0
    /// Hard stop for incremental inference. Above this, finish at next
    /// foreground instead.
    public static let abandonThresholdSeconds: Double = 90.0

    public init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    public func prepare() async throws {
        // Cold model load is a one-off cost, reported separately from
        // steady-state throughput so it cannot skew the speed gate.
        let started = ContinuousClock.now
        try await transcriber.prepare()
        let elapsed = ContinuousClock.now - started
        await M0Telemetry.shared.noteModelLoad(
            seconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            artifactBytes: nil // M0 step 1: record the real artifact size here.
        )
    }

    /// Transcribes whatever is outstanding on this job, in chunk order.
    ///
    /// Returns the job in its new state. Safe to call repeatedly: it resumes
    /// from `transcribedFrames` and the recovery unit is the whole chunk.
    @discardableResult
    public func drain(job input: RecordingJob) async -> RecordingJob {
        var job = input
        var tokens: [Token] = []

        for index in job.segments.indices {
            let segment = job.segments[index]
            let url = JobStore.shared.audioDirectory.appendingPathComponent(segment.filename)

            var offset = segment.transcribedFrames
            while offset < segment.frameCount {
                if thermal.shouldSuspend {
                    job.state = .captured
                    job.promiseWithdrawnReason = "Device too warm; will finish when it cools"
                    log.notice("Thermal suspend at \(job.backlogSeconds, privacy: .public)s backlog")
                    await M0Telemetry.shared.noteEvent(
                        "thermal suspend at \(Int(job.backlogSeconds))s backlog"
                    )
                    return job
                }
                if job.backlogSeconds > Self.abandonThresholdSeconds {
                    job.state = .captured
                    job.promiseWithdrawnReason = "Fell behind; will finish next time you open Gabbro"
                    await M0Telemetry.shared.noteEvent(
                        "backlog abandon threshold breached at \(Int(job.backlogSeconds))s"
                    )
                    return job
                }

                let cap = thermal.chunkCapFrames
                let count = min(cap, segment.frameCount - offset)
                guard count > 0 else { break }

                do {
                    let samples = try WAVWriter.readFloat32(
                        from: url, frameOffset: offset, frameCount: count
                    )
                    // Wall clock around the inference call only. This ratio is
                    // the speed gate, and the telemetry keeps only the chunks
                    // that ran while the device was locked — a foreground
                    // measurement would flatter the design into passing.
                    let started = ContinuousClock.now
                    let result = try await transcriber.transcribe(samples: samples)
                    let elapsed = ContinuousClock.now - started
                    await M0Telemetry.shared.noteChunk(
                        audioSeconds: Double(count) / Double(WAVWriter.sampleRate),
                        wallSeconds: Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1e18
                    )
                    await M0Telemetry.shared.noteBacklog(seconds: job.backlogSeconds)

                    tokens = OverlapMerge.merge(tokens, with: result.tokens)
                    for code in result.languages where !job.detectedLanguages.contains(code) {
                        job.detectedLanguages.append(code)
                    }
                } catch {
                    // Retry is per chunk; completed chunks are kept. Audio is
                    // always retained, so nothing here is terminal.
                    job.state = .failed
                    job.failureReason = error.localizedDescription
                    log.error("Chunk failed: \(error.localizedDescription, privacy: .public)")
                    return job
                }

                // Advance by the chunk minus its overlap, so the next window
                // re-reads the tail the merge aligns on.
                offset += max(1, count - Chunking.overlapFrames)
                job.segments[index].transcribedFrames = min(offset, segment.frameCount)

                await thermal.yieldIfThrottled()
            }
        }

        job.transcript = renderer.paragraphs(from: tokens)
        job.state = job.transcript.isEmpty ? .failed : .ready
        if job.transcript.isEmpty { job.failureReason = "No speech detected" }
        return job
    }

    /// True while the 10-second-at-Stop promise still holds.
    public func promiseHolds(for job: RecordingJob) -> Bool {
        job.backlogSeconds <= Self.promiseThresholdSeconds && !thermal.shouldSuspend
    }
}

/// Graded thermal response.
///
/// The source spec's flat "pause the queue on .serious" was written for
/// record-then-transcribe. Under incremental inference a flat pause grows the
/// untranscribed tail without bound and then demands it all complete in 10
/// seconds at Stop — precisely when the device is hottest. So: degrade, then
/// suspend, and say so out loud rather than silently.
struct ThermalPolicy {
    var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    var shouldSuspend: Bool { state == .critical }

    /// Under `.serious`, raise the cap to 30 s and halve the duty cycle.
    /// Backlog then grows at ~0.5x real time, tripping the 8 s promise
    /// threshold after roughly 16 s of continued speech.
    var chunkCapFrames: Int {
        state == .serious
            ? Int(Chunking.thermalCapSeconds * Double(WAVWriter.sampleRate))
            : Chunking.capFrames
    }

    /// The other half of the 50% duty cycle: sleep for as long as the last
    /// chunk took. Cheap approximation, and it keeps the ANE off long enough
    /// to matter on a small chassis.
    func yieldIfThrottled() async {
        guard state == .serious else { return }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
