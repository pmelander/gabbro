import Foundation

/// A transcriber that returns fixed text, for wiring the pipeline end to end
/// before the model is real.
///
/// This is the one thing the design says is safe to fake early. It earned its
/// place: the whole capture, render and share path was proven against it, and
/// several crash-fix cycles ran through it without a 600 MB model muddying the
/// picture.
///
/// It is NOT a fallback ASR. Never ship a path that reaches this.
public actor StubTranscriber: Transcriber {
    private let fixture: String
    private var elapsed: TimeInterval = 0

    public nonisolated let reportsDetectedLanguage = false
    public nonisolated let modelIdentifier = "stub"

    public init(fixture: String = "Det här är en testinspelning. This is a test recording.") {
        self.fixture = fixture
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

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
