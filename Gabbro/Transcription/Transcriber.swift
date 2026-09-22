import Foundation

/// The ASR boundary.
///
/// Streaming, not one-shot. FluidAudio's `SlidingWindowAsrManager` already
/// takes audio a slice at a time and returns token timings positioned on the
/// whole recording's timeline, with the seams handled internally — so we feed
/// it in order rather than cutting overlapping windows and stitching the
/// results ourselves. Our own chunker and token-alignment merge were deleted
/// when that was discovered; the reuse ladder says stop at the first rung
/// that holds, and this holds.
///
/// The protocol still exists because FluidAudio is pre-1.0 and churning, and
/// because `StubTranscriber` behind it is what let the whole pipeline be
/// proven end to end before the model was real. Note the M0 failure policy
/// though: a failed gate is a project stop, not a substitution.
public protocol Transcriber: Sendable {
    /// Loads the model. Expensive; call once. Cold load time is an M0
    /// measurement, reported separately so it cannot skew the speed gate.
    func prepare() async throws

    /// Feed the next slice of audio, in recording order.
    ///
    /// - Parameter isLast: true for the final slice, so the implementation can
    ///   flush whatever it is holding.
    /// - Returns: tokens whose `start`/`end` are on the **whole recording's**
    ///   timeline, not the slice's.
    func feed(_ samples: [Float], isLast: Bool) async throws -> TranscriptionResult

    /// Discard streaming state. Call before feeding a different recording.
    func reset() async

    /// What produced the transcript, for the note's frontmatter. On the
    /// protocol rather than on a concrete type because the engine itself is
    /// now in question -- see the design doc on Norwegian.
    nonisolated var modelIdentifier: String { get }

    /// Whether the backing model reports a detected language at all.
    ///
    /// Parakeet v3 takes no language *input* — detection is strictly
    /// automatic, no prompt prefix and no flag. As of FluidAudio 0.15.x it
    /// does not appear to surface the detected code as *output* either:
    /// `ASRResult` exposes text, confidence and token timings. So this is
    /// false and `MarkdownRenderer` omits the frontmatter `language` field
    /// entirely rather than emitting a guess.
    nonisolated var reportsDetectedLanguage: Bool { get }
}

public struct TranscriptionResult: Sendable {
    public var tokens: [Token]
    /// Language codes as detected, if ever available. Empty in practice.
    public var languages: [String]

    public init(tokens: [Token], languages: [String] = []) {
        self.tokens = tokens
        self.languages = languages
    }

    public var text: String {
        tokens.map(\.text).joined()
    }
}

/// A token plus its timing, on the full recording's timeline.
///
/// Timings drive the paragraph rule (break on silence ≥ 1.5 s) and are the
/// raw material for timestamp-linked audio playback, the deferred feature the
/// renderer must not foreclose.
public struct Token: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum TranscriberError: LocalizedError {
    case notPrepared
    case modelUnavailable(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared: "Transcriber was used before prepare() completed."
        case .modelUnavailable(let s): "Model unavailable: \(s)"
        case .inferenceFailed(let s): "Inference failed: \(s)"
        }
    }
}
