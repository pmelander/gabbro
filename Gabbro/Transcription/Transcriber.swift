import Foundation

/// The ASR boundary.
///
/// This protocol exists because FluidAudio is pre-1.0 and actively churning
/// (0.15.6, pushed 2026-09-10), and the source spec's own §9 risk table calls
/// for a swappable dependency. It is also what would let sherpa-onnx or
/// whisper.cpp in — though note the M0 failure policy: a failed gate is a
/// project stop, not a substitution, because Whisper detects one language per
/// ~30 s window and that degrades the code-switching criterion specifically.
public protocol Transcriber: Sendable {
    /// Loads the model. Expensive; call once. Cold load time is an M0
    /// measurement.
    func prepare() async throws

    /// Transcribes one window of 16 kHz mono Float32 samples.
    func transcribe(samples: [Float]) async throws -> TranscriptionResult

    /// Whether the backing model reports a detected language at all.
    /// Parakeet v3 takes no language *input* — detection is strictly
    /// automatic with no prompt prefix and no flag. Whether it surfaces the
    /// detected code as *output* is a separate question and an M0 check; the
    /// frontmatter `language` field is omitted entirely when this is false.
    var reportsDetectedLanguage: Bool { get }
}

public struct TranscriptionResult: Sendable {
    public var tokens: [Token]
    /// Language codes as detected, if available. Empty when the model does not
    /// surface them.
    public var languages: [String]

    public init(tokens: [Token], languages: [String] = []) {
        self.tokens = tokens
        self.languages = languages
    }

    public var text: String {
        tokens.map(\.text).joined()
    }
}

/// A token plus its timing. Timings are what make overlap merge possible, and
/// they are also the raw material for timestamp-linked audio playback — the
/// deferred feature the markdown renderer must not foreclose.
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
    case notImplemented(String)
    case modelUnavailable(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let s): "Not implemented: \(s)"
        case .modelUnavailable(let s): "Model unavailable: \(s)"
        case .inferenceFailed(let s): "Inference failed: \(s)"
        }
    }
}
