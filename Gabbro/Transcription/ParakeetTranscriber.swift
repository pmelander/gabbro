import CoreML
import Foundation
import FluidAudio
import OSLog

/// Parakeet TDT 0.6B v3 on the Apple Neural Engine, via FluidAudio.
///
/// ## Language coverage — read before assuming
///
/// Parakeet v3 covers **the 24 EU official languages plus Russian and
/// Ukrainian**. That framing matters more than the count, because it explains
/// the gaps: **Norwegian and Icelandic are NOT supported.** Norway and Iceland
/// are not EU members. Swedish, Danish and Finnish are all covered.
///
/// This is structural, not an oversight, so do not expect a point release to
/// add them. If Norwegian is ever required, Parakeet cannot do it and the
/// alternative is Whisper — which detects one language per ~30 s window and so
/// degrades exactly the mid-note code-switching this app exists to capture.
///
/// ## Why this uses SlidingWindowAsrManager
///
/// It takes audio a slice at a time via `transcribeChunk(_:isLastChunk:)` and
/// returns `tokenTimings` mapped onto the whole recording's timeline, handling
/// seams internally. That deleted our own chunker and token-alignment merge.
///
/// ## First-compile warning
///
/// These call signatures come from FluidAudio's `main` documentation while the
/// package is pinned to 0.15.6, and the two doc pages disagree with each other
/// in places (`configure(models:)` vs `initialize(models:)` vs
/// `loadModels(_:)`). Expect the first CI run to correct exact names — that is
/// a compiler error away and cheap to fix, which is why this is no longer
/// stubbed out. `StubTranscriber` remains so the app still runs meanwhile.
public actor ParakeetTranscriber: Transcriber {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Parakeet")

    /// Pinned. Do not track a default branch — the source spec is explicit,
    /// and it is the difference between a reproducible build and a model that
    /// silently changes under you.
    ///
    /// NOTE: `ModelRegistry.baseURL` overrides the registry *URL*, which is
    /// not the same as pinning a commit. Whether a specific revision can be
    /// pinned at all is an open M0 question.
    public static let modelRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"

    private var manager: SlidingWindowAsrManager?
    /// Highest token start time accepted so far.
    ///
    /// Guards against double-counting if `transcribeChunk` turns out to return
    /// cumulative rather than incremental tokens — the docs do not say which,
    /// and appending blindly would duplicate the entire transcript per slice.
    /// Filtering on a monotonically increasing start time is correct either
    /// way, so this does not need the answer.
    private var lastAcceptedStart: TimeInterval = -1

    public init() {}

    public let reportsDetectedLanguage = false

    public func prepare() async throws {
        guard manager == nil else { return }

        // ~460 MB per the source spec, but unverified: the HF repo holds
        // several quantisation variants (INT8, int8-linear, Int4 encoders with
        // an unquantised decoder — no FP16) and its 3.59 GB total is the whole
        // repo including history, not a download. Record the real figure on
        // device; M0 step 1 is authorised to fail the design if it is
        // FP16-sized.
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        manager = try await SlidingWindowAsrManager(models: models)
        lastAcceptedStart = -1
        log.notice("Parakeet v3 loaded")

        // COMPUTE UNITS — verify on device, this is not cosmetic.
        //
        // iPhone apps cannot use the GPU in the background. CoreML's default
        // is .all, which includes it, so if any part of the encoder or the TDT
        // decode loop lands on the GPU then inference fails on exactly the
        // locked-screen path this whole architecture depends on.
        //
        // FluidAudio's VadManager takes MLComputeUnits and defaults to
        // .cpuAndNeuralEngine, and the ASR config is reported to as well — but
        // API.md does not document it on the ASR managers. If it cannot be
        // set, that is a design-level finding, not a note.
        // "Zero GPU work scheduled while locked" is an M0 pass condition.
    }

    public func feed(_ samples: [Float], isLast: Bool) async throws -> TranscriptionResult {
        guard let manager else { throw TranscriberError.notPrepared }

        let result = try await manager.transcribeChunk(samples, isLastChunk: isLast)
        let timings = result.tokenTimings ?? []

        var fresh: [Token] = []
        for timing in timings where timing.startTime > lastAcceptedStart {
            fresh.append(Token(text: timing.token, start: timing.startTime, end: timing.endTime))
            lastAcceptedStart = timing.startTime
        }
        return TranscriptionResult(tokens: fresh)
    }

    public func reset() async {
        manager?.reset()
        lastAcceptedStart = -1
    }
}

/// A transcriber that returns fixed text, for wiring the pipeline end to end
/// before the model is real.
///
/// This is the one thing the design says is safe to fake early: "bundled
/// fixtures before microphone integration, a pre-installed model before the
/// downloader UX". It earned its place — the whole capture, render and share
/// path was proven against it, and six crash-fix cycles ran through it without
/// the model muddying the picture.
///
/// It is NOT a fallback ASR. Never ship a path that reaches this.
public actor StubTranscriber: Transcriber {
    private let fixture: String
    private var elapsed: TimeInterval = 0

    public let reportsDetectedLanguage = false

    public init(fixture: String = "Det här är en testinspelning. This is a test recording.") {
        self.fixture = fixture
    }

    public func prepare() async throws {}

    public func feed(_ samples: [Float], isLast: Bool) async throws -> TranscriptionResult {
        let duration = Double(samples.count) / Double(WAVWriter.sampleRate)
        let words = fixture.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return TranscriptionResult(tokens: []) }
        let step = duration / Double(words.count)
        let base = elapsed
        let tokens = words.enumerated().map { i, w in
            Token(
                text: i == 0 && base == 0 ? w : " " + w,
                start: base + Double(i) * step,
                end: base + Double(i + 1) * step
            )
        }
        elapsed += duration
        return TranscriptionResult(tokens: tokens)
    }

    public func reset() async { elapsed = 0 }
}
