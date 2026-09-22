import CoreML
import Foundation
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

    public init() {}

    public let reportsDetectedLanguage = false
    public let modelIdentifier = "parakeet-tdt-0.6b-v3"

    // HELD: the engine choice is reopened, so this deliberately calls no
    // FluidAudio API rather than guessing at one.
    //
    // The first build against the documented signatures failed on every one:
    // `SlidingWindowAsrManager(models:)` took no such argument, and
    // `transcribeChunk` does not exist on that type in 0.15.6. The published
    // docs describe `main`, not the pinned tag, so they are not a usable
    // source. CI now dumps the real public API from the checked-out source --
    // that dump is the ground truth to implement against.
    //
    // More importantly, Parakeet v3 cannot serve Norwegian at all, which is a
    // stated non-negotiable. Implementing against the right signatures is
    // wasted if the engine changes, so this waits on that decision.

    public func prepare() async throws {
        throw TranscriberError.modelUnavailable(
            "Engine decision pending: Parakeet v3 has no Norwegian. See the design doc."
        )
    }

    public func feed(_ samples: [Float], isLast: Bool) async throws -> TranscriptionResult {
        throw TranscriberError.notPrepared
    }

    public func reset() async {}
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
    public let modelIdentifier = "stub"

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
