import Foundation

/// How much audio we hand the transcriber at a time.
///
/// This is a **feed size, not an overlap window**. An earlier version of this
/// file also held an `OverlapMerge` that cut overlapping windows and stitched
/// the results by token alignment — that was deleted once
/// `SlidingWindowAsrManager` turned out to do the same job, and better: it
/// owns the overlap internally and returns token timings already mapped onto
/// the whole recording's timeline. Do not reintroduce an overlap here; two
/// layers of window logic would fight.
public enum Chunking {
    /// Audio handed over per call under normal conditions.
    public static let feedSeconds: Double = 12.0

    /// Larger slices under `.serious` thermal pressure, paired with a 50% duty
    /// cycle. Backlog then grows at ~0.5x real time, tripping the 8 s promise
    /// threshold after roughly 16 s of continued speech.
    public static let thermalFeedSeconds: Double = 30.0

    /// Below this there is nothing worth a disk read and an inference call.
    /// The final slice is flagged `isLast` instead, so the transcriber flushes
    /// whatever it is holding.
    public static let minFeedSeconds: Double = 0.25

    /// Silence at or above this length becomes a paragraph break in the
    /// rendered markdown. Success criterion 5 grades paragraphs, so something
    /// has to produce them.
    public static let paragraphSilenceSeconds: Double = 1.5

    public static var feedFrames: Int { Int(feedSeconds * Double(WAVWriter.sampleRate)) }
    public static var minFeedFrames: Int { Int(minFeedSeconds * Double(WAVWriter.sampleRate)) }
}
