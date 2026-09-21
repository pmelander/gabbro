import Foundation

/// Joins consecutive chunk transcripts across their overlap region.
///
/// Naive concatenation duplicates words at every seam, because each chunk
/// carries `Chunking.overlap` seconds of audio its neighbour also saw. This is
/// the algorithm success criterion 4 tests, so it is specified here rather
/// than deferred.
///
/// Approach: find the longest token-text run at the end of the accumulated
/// transcript that also appears at the start of the incoming chunk, within the
/// overlap window. Keep the earlier chunk's copy — its tokens had more
/// left-context, which is where a TDT decoder is most confident. Ties break
/// toward the longer match.
public enum OverlapMerge {
    /// Maximum tokens to consider on either side of a seam. The overlap is
    /// 1.5 s; natural speech runs ~3 tokens/second, so 24 is generous headroom.
    static let searchWindow = 24

    public static func merge(_ accumulated: [Token], with incoming: [Token]) -> [Token] {
        guard !accumulated.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return accumulated }

        let tailStart = max(0, accumulated.count - searchWindow)
        let tail = Array(accumulated[tailStart...])
        let head = Array(incoming.prefix(searchWindow))

        // Longest suffix of `tail` that is a prefix of `head`.
        var bestOverlap = 0
        for length in stride(from: min(tail.count, head.count), through: 1, by: -1) {
            let suffix = tail.suffix(length).map(normalize)
            let prefix = head.prefix(length).map(normalize)
            if suffix.elementsEqual(prefix) {
                bestOverlap = length
                break
            }
        }

        // No match: the seam fell inside a silence, or the decoder disagreed
        // with itself across the boundary. Concatenating is correct here —
        // dropping tokens on a failed match would lose speech, which is worse
        // than a duplicated word.
        return accumulated + incoming.dropFirst(bestOverlap)
    }

    /// Comparison is on normalized text: the decoder may punctuate or
    /// capitalize the same word differently depending on right-context, and a
    /// seam should not survive merely because one side ended with a comma.
    private static func normalize(_ token: Token) -> String {
        token.text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isPunctuation }
    }
}

/// Chunk geometry. VAD proposes boundaries; these are the caps that apply when
/// it does not find one in time.
public enum Chunking {
    /// Hard cap on a chunk. Exact, not approximate — it governs a correctness
    /// criterion.
    public static let capSeconds: Double = 12.0
    /// Overlap carried into the next chunk when a cap cut is forced.
    public static let overlapSeconds: Double = 1.5
    /// Raised cap under `.serious` thermal pressure, paired with a 50% duty
    /// cycle. Backlog then grows at ~0.5x real time.
    public static let thermalCapSeconds: Double = 30.0

    /// Silence at or above this length becomes a paragraph break in the
    /// rendered markdown. Success criterion 5 grades paragraphs, so something
    /// has to produce them.
    public static let paragraphSilenceSeconds: Double = 1.5

    /// Below this there is nothing worth running the model on. Guards against
    /// grinding through slivers at the end of a segment.
    public static let minChunkSeconds: Double = 0.25

    public static var capFrames: Int { Int(capSeconds * Double(WAVWriter.sampleRate)) }
    public static var overlapFrames: Int { Int(overlapSeconds * Double(WAVWriter.sampleRate)) }
    public static var minChunkFrames: Int { Int(minChunkSeconds * Double(WAVWriter.sampleRate)) }
}
