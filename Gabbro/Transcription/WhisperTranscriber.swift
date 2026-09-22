import Foundation
import OSLog
import WhisperKit

/// Whisper on the Apple Neural Engine, via WhisperKit.
///
/// ## Why not Parakeet
///
/// Parakeet TDT v3 is the better model for this app's usual case — it handles
/// mid-sentence code-switching properly, which Whisper does not. It was the
/// original choice and it lost on one fact: its language set is the 24 EU
/// official languages plus Russian and Ukrainian, so **it has no Norwegian**.
/// Norway is not in the EU. That is structural, not a gap awaiting a patch,
/// and Norwegian is a hard requirement here. FluidAudio wraps only Parakeet
/// and Nemotron, so the whole library went with it.
///
/// ## What that costs, stated plainly
///
/// **Whisper decides one language per ~30 s window.** A sentence that switches
/// from Swedish to English mid-flow gets forced into one of them. That is
/// exactly the artefact the source spec set out to avoid, and it is the price
/// of Norwegian. Success criterion 5 should be read with this in mind.
///
/// ## Seams
///
/// Whisper chunks internally when handed one long array, but separate
/// `transcribe` calls share no context — so a word landing on a slice edge can
/// be clipped. We feed 30 s slices to match its native window, which minimises
/// but does not eliminate this. An M0 check: transcribe the fixture whole, then
/// sliced, and compare.
public actor WhisperTranscriber: Transcriber {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Whisper")

    /// Whisper reports the language it detected, so unlike Parakeet the
    /// frontmatter `language` field can be populated for real.
    public nonisolated let reportsDetectedLanguage = true
    public nonisolated let modelIdentifier: String

    private let modelName: String
    private var pipe: WhisperKit?
    /// Slice timings are relative to the slice. Offset them onto the whole
    /// recording's timeline, which is what `Token` promises.
    private var elapsed: TimeInterval = 0

    /// Default is the compressed large-v3 variant. M0 decides whether it fits:
    /// the memory gate wants ≥ 400 MB headroom while locked and backgrounded,
    /// and a ~626 MB model plus activations may not leave it. `small` and
    /// `base` are the fallbacks if it does not — quality drops, Norwegian
    /// noticeably so.
    public init(modelName: String = "large-v3-v20240930_626MB") {
        self.modelName = modelName
        self.modelIdentifier = "whisper-\(modelName)"
    }

    public func prepare() async throws {
        guard pipe == nil else { return }
        let started = ContinuousClock.now
        pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
        elapsed = 0
        let took = ContinuousClock.now - started
        log.notice("WhisperKit ready: \(self.modelName, privacy: .public) in \(took.components.seconds, privacy: .public)s")
    }

    public func feed(_ samples: [Float], isLast: Bool) async throws -> TranscriptionResult {
        guard let pipe else { throw TranscriberError.notPrepared }

        // language: nil means auto-detect, which is what we want and the whole
        // reason for the engine change. wordTimestamps gives the timings the
        // paragraph rule and deferred audio-seek both need.
        let options = DecodingOptions(
            language: nil,
            wordTimestamps: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        let sliceStart = elapsed
        var tokens: [Token] = []
        var languages: [String] = []

        for result in results {
            // Non-optional String, not String? — Whisper always reports
            // something. It can still be empty, so that is the real check.
            let code = result.language
            if !code.isEmpty, !languages.contains(code) {
                languages.append(code)
            }
            for segment in result.segments {
                if let words = segment.words, !words.isEmpty {
                    for word in words {
                        tokens.append(Token(
                            text: word.word,
                            start: sliceStart + TimeInterval(word.start),
                            end: sliceStart + TimeInterval(word.end)
                        ))
                    }
                } else {
                    // No word timings: fall back to segment granularity so the
                    // paragraph rule still has something to work with.
                    tokens.append(Token(
                        text: segment.text,
                        start: sliceStart + TimeInterval(segment.start),
                        end: sliceStart + TimeInterval(segment.end)
                    ))
                }
            }
        }

        elapsed += Double(samples.count) / Double(WAVWriter.sampleRate)
        return TranscriptionResult(tokens: tokens, languages: languages)
    }

    public func reset() async {
        elapsed = 0
    }
}
