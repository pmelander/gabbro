import Foundation

/// The ASR boundary.
///
/// Streaming, not one-shot: audio is fed a slice at a time as VAD segments
/// close, which is what keeps inference inside the live audio session instead
/// of owing minutes of it after Stop.
///
/// The boundary has now earned itself twice over. It absorbed the engine
/// changing outright -- Parakeet/FluidAudio to Whisper/WhisperKit, forced by
/// Norwegian -- without anything above it moving, and `StubTranscriber` behind
/// it is what let the whole capture, render and share path be proven before
/// any model existed.
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
    /// True for Whisper, which returns the language it detected, so the
    /// frontmatter `language` field can be populated for real. It was false
    /// under Parakeet, which detects internally but surfaces nothing.
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
