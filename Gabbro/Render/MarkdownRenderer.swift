import Foundation

/// Turns a finished job into the markdown file that gets shared.
///
/// Raw verbatim transcript. No LLM shaping in v1 — that was decided
/// explicitly, and Apple Foundation Models is parked rather than dead.
public struct MarkdownRenderer: Sendable {
    public init() {}

    /// `2026-09-21-1432-voice.md`
    public func filename(for job: RecordingJob) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(f.string(from: job.createdAt))-voice.md"
    }

    public func render(job: RecordingJob, modelRevision: String) -> String {
        var out = "---\n"
        out += "created: \(iso8601(job.createdAt))\n"
        out += "duration: \(humanDuration(job.totalDurationSeconds))\n"
        // Omitted entirely when the model does not surface detected language,
        // rather than emitted as a guess. A list, never a scalar — a single
        // code is wrong by construction for a code-switched note.
        if !job.detectedLanguages.isEmpty {
            out += "language: [\(job.detectedLanguages.joined(separator: ", "))]\n"
        }
        out += "input_route: \(job.inputRoute.rawValue)\n"
        out += "model: parakeet-tdt-0.6b-v3\n"
        out += "model_revision: \(modelRevision)\n"
        out += "tags: [voice]\n"
        out += "---\n\n"
        out += job.transcript
        if !job.transcript.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Paragraph rule: break on VAD silence at or above
    /// `Chunking.paragraphSilenceSeconds`, use the decoder's own punctuation
    /// verbatim, never hard-wrap. Success criterion 5 grades "every
    /// paragraph", so the transcript has to have some.
    public func paragraphs(from tokens: [Token]) -> String {
        guard !tokens.isEmpty else { return "" }
        var out = ""
        var previousEnd = tokens[0].start
        for token in tokens {
            if token.start - previousEnd >= Chunking.paragraphSilenceSeconds, !out.isEmpty {
                out += "\n\n"
                out += token.text.trimmingCharacters(in: .whitespaces)
            } else {
                out += token.text
            }
            previousEnd = token.end
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the note next to the audio, ready for `ShareSheet` to hand over
    /// as a **file URL**. Handing over `Data` or a `String` loses the filename
    /// and can route the share extension down a different branch.
    public func write(job: RecordingJob, modelRevision: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(filename(for: job))
        let text = render(job: job, modelRevision: modelRevision)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        return url
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private func humanDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60)m\(String(format: "%02d", total % 60))s"
    }
}
