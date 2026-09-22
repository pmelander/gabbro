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
///
/// ## Why `drain` never mutates a `RecordingJob`
///
/// Three successive builds aborted here with a Swift exclusivity violation:
///
///     swift_beginAccess -> AccessSet::insert -> fatalError -> SIGABRT
///     TranscriptionCoordinator.drain(job:) + 132
///
/// Two surgical fixes were attempted from that backtrace and neither helped.
/// The offset stayed at exactly +132 across three quite different function
/// bodies, and the trace carried `<deduplicated_symbol>` frames — identical
/// code folding was on, so that symbol could not be trusted to name the real
/// function at all.
///
/// So this is structural rather than surgical. `drain` holds **no mutable
/// `RecordingJob`**: it copies the segment list out once, accumulates into
/// plain value locals, and assembles the result in a single pass at the end.
/// There is no read-overlapping-write on any aggregate anywhere in the
/// function, so the class of bug is gone regardless of which line the runtime
/// was really pointing at.
///
/// Two rules to keep it that way:
///  - Do not add a stored `var` to this actor and call an `async` method on
///    it. That holds an access open across the suspension point.
///  - Do not use a nested function or closure that captures a mutable local.
///    Capturing makes the local escaping, which turns static exclusivity
///    checks into dynamic ones and reintroduces exactly this failure. The
///    helpers at the bottom are statics taking parameters by value for that
///    reason.
public actor TranscriptionCoordinator {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Coordinator")

    private let transcriber: Transcriber
    private let renderer = MarkdownRenderer()

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
        await M0Telemetry.shared.noteModelLoad(
            seconds: Self.seconds(ContinuousClock.now - started),
            artifactBytes: nil // M0 step 1: record the real artifact size here.
        )
    }

    /// Transcribes whatever is outstanding on this job, in chunk order.
    ///
    /// Returns a NEW job value. Safe to call repeatedly: it resumes from
    /// `transcribedFrames` and the recovery unit is the whole chunk.
    @discardableResult
    public func drain(job input: RecordingJob) async -> RecordingJob {
        // One immutable copy of the segment list, and plain value locals for
        // everything that changes. Nothing below touches `input` again until
        // `assemble` builds the result. See the type doc for why.
        // Streaming transcriber: clear any state from a previous recording
        // before feeding this one, or its timeline continues from the last.
        await transcriber.reset()

        let segments = input.segments
        var progress = segments.map(\.transcribedFrames)
        var languages = input.detectedLanguages
        var tokens: [Token] = []
        // Telemetry is accumulated here and submitted once after the loops.
        // Three actor hops per chunk was both wasteful and three extra
        // suspension points inside a loop that mutates locals.
        var chunkTimings: [(audioSeconds: Double, wallSeconds: Double)] = []
        var maxBacklog = 0.0

        for index in 0..<segments.count {
            let segment = segments[index]
            let url = JobStore.shared.audioDirectory.appendingPathComponent(segment.filename)
            var offset = progress[index]
            let isFinalSegment = index == segments.count - 1

            while offset < segment.frameCount {
                let backlog = Self.backlogSeconds(segments: segments, progress: progress)

                if ThermalPolicy.shouldSuspend {
                    log.notice("Thermal suspend at \(backlog, privacy: .public)s backlog")
                    let note = "thermal suspend at \(Int(backlog))s backlog"
                    Task { await M0Telemetry.shared.noteEvent(note) }
                    return Self.assemble(
                        input, progress: progress, languages: languages, transcript: nil,
                        state: .captured, reason: "Device too warm; will finish when it cools"
                    )
                }
                if backlog > Self.abandonThresholdSeconds {
                    let note = "backlog abandon threshold breached at \(Int(backlog))s"
                    Task { await M0Telemetry.shared.noteEvent(note) }
                    return Self.assemble(
                        input, progress: progress, languages: languages, transcript: nil,
                        state: .captured,
                        reason: "Fell behind; will finish next time you open Gabbro"
                    )
                }

                let remaining = segment.frameCount - offset
                let count = min(ThermalPolicy.feedFrames, remaining)
                let isFinalSlice = isFinalSegment && count == remaining

                // A sliver is not worth a disk read, unless it is the very
                // last slice -- the transcriber needs `isLast` to flush.
                guard count >= Chunking.minFeedFrames || isFinalSlice else {
                    progress[index] = segment.frameCount
                    break
                }

                do {
                    let samples = try WAVWriter.readFloat32(
                        from: url, frameOffset: offset, frameCount: count
                    )
                    // Wall clock around the inference call only. This ratio is
                    // the speed gate, and the telemetry keeps only the chunks
                    // that ran while the device was locked -- a foreground
                    // measurement would flatter the design into passing.
                    let started = ContinuousClock.now
                    let result = try await transcriber.feed(samples, isLast: isFinalSlice)
                    chunkTimings.append((
                        audioSeconds: Double(count) / Double(WAVWriter.sampleRate),
                        wallSeconds: Self.seconds(ContinuousClock.now - started)
                    ))
                    maxBacklog = max(maxBacklog, backlog)

                    // No merge step. Timings arrive on the whole recording's
                    // timeline with the seams already handled, so appending in
                    // feed order is the whole of it.
                    tokens.append(contentsOf: result.tokens)
                    for code in result.languages where !languages.contains(code) {
                        languages.append(code)
                    }
                } catch {
                    // Retry is per slice; completed slices are kept. Audio is
                    // always retained, so nothing here is terminal.
                    log.error("Slice failed: \(error.localizedDescription, privacy: .public)")
                    return Self.assemble(
                        input, progress: progress, languages: languages, transcript: nil,
                        state: .failed, failure: error.localizedDescription
                    )
                }

                // Straight advance, no overlap to back up over.
                offset += count
                progress[index] = offset

                await ThermalPolicy.yieldIfThrottled()
            }
        }

        await M0Telemetry.shared.noteChunks(chunkTimings, maxBacklogSeconds: maxBacklog)
        let transcript = renderer.paragraphs(from: tokens)
        return Self.assemble(
            input, progress: progress, languages: languages, transcript: transcript,
            state: transcript.isEmpty ? .failed : .ready,
            failure: transcript.isEmpty ? "No speech detected" : nil
        )
    }

    /// True while the 10-second-at-Stop promise still holds.
    public func promiseHolds(for job: RecordingJob) -> Bool {
        job.backlogSeconds <= Self.promiseThresholdSeconds && !ThermalPolicy.shouldSuspend
    }

    // MARK: - Helpers
    //
    // Static, with everything passed by value. Deliberately NOT nested
    // functions: a nested function capturing `progress` would make it
    // escaping, turning static exclusivity checks into dynamic ones and
    // reintroducing the crash this rewrite exists to remove.

    private static func backlogSeconds(
        segments: [RecordingJob.Segment], progress: [Int]
    ) -> Double {
        var total = 0.0
        for i in 0..<min(segments.count, progress.count) {
            total += Double(max(0, segments[i].frameCount - progress[i]))
                / Double(WAVWriter.sampleRate)
        }
        return total
    }

    /// The single place a `RecordingJob` is built. One pass, no loop holding
    /// an access, no mutation of anything the caller still owns.
    private static func assemble(
        _ input: RecordingJob,
        progress: [Int],
        languages: [String],
        transcript: String?,
        state: RecordingJob.State,
        reason: String? = nil,
        failure: String? = nil
    ) -> RecordingJob {
        var out = input
        let count = min(out.segments.count, progress.count)
        for i in 0..<count {
            out.segments[i].transcribedFrames = progress[i]
        }
        out.detectedLanguages = languages
        if let transcript { out.transcript = transcript }
        out.state = state
        if let reason { out.promiseWithdrawnReason = reason }
        out.failureReason = failure
        return out
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Deliberately an `enum` of statics with NO stored state.
///
/// This was a `struct` held in a `private var thermal` on the coordinator.
/// Calling `await thermal.yieldIfThrottled()` on a stored property holds an
/// exclusivity access open across the suspension point — a genuine hazard,
/// though it turned out not to be the one that was firing.
///
/// There was never any state to store: every member below reads `ProcessInfo`
/// live. No property, no access, no conflict.
enum ThermalPolicy {
    static var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    static var shouldSuspend: Bool { state == .critical }

    /// Under `.serious`, raise the feed size to 30 s and halve the duty cycle.
    /// Backlog then grows at ~0.5x real time, tripping the 8 s promise
    /// threshold after roughly 16 s of continued speech.
    static var feedFrames: Int {
        state == .serious
            ? Int(Chunking.thermalFeedSeconds * Double(WAVWriter.sampleRate))
            : Chunking.feedFrames
    }

    /// The other half of the 50% duty cycle: yield long enough to keep the ANE
    /// off on a small chassis.
    static func yieldIfThrottled() async {
        guard state == .serious else { return }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
