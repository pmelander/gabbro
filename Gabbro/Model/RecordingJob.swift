import Foundation

/// A capture and everything downstream of it.
///
/// A job is an **ordered list of segments**, not one file. An audio session
/// interruption (incoming call, another app seizing the session, a route
/// change) splits a recording rather than ending it. See
/// `AudioSessionManager` for the interruption paths, including the one where
/// `.ended` never arrives.
public struct RecordingJob: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Capture live; incremental inference running.
        case recording
        /// Audio complete; tail or backlog outstanding.
        case captured
        /// Tail running inside the still-held background task.
        case transcribing
        /// Markdown rendered, awaiting share.
        case ready
        /// Handed to the share sheet.
        case shared
        /// Retryable. Audio is always retained.
        case failed
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var index: Int
        /// Filename only, resolved against the store directory. Absolute URLs
        /// do not survive app container path changes between installs.
        public var filename: String
        public var frameCount: Int
        /// Frames already fed to the transcriber. Recovery unit is the whole
        /// chunk: on resume, re-run from this offset rather than attempting to
        /// resume mid-chunk.
        public var transcribedFrames: Int

        public var durationSeconds: Double {
            Double(frameCount) / Double(WAVWriter.sampleRate)
        }

        public var untranscribedSeconds: Double {
            Double(max(0, frameCount - transcribedFrames)) / Double(WAVWriter.sampleRate)
        }
    }

    /// What the microphone was actually on. HFP (AirPods) input is narrowband
    /// and costs more accuracy than the `.measurement` A/B can recover, so it
    /// is recorded per job and emitted in frontmatter rather than assumed.
    public enum InputRoute: String, Codable, Sendable {
        case builtIn
        case bluetooth
        case wired
        case other
    }

    public var id: UUID
    public var createdAt: Date
    public var state: State
    public var segments: [Segment]
    public var inputRoute: InputRoute
    /// Merged transcript, populated as chunks complete.
    public var transcript: String
    /// Language codes as detected, if the ASR surfaces them at all. A list,
    /// not a scalar: a single code is wrong by construction for the
    /// code-switched notes this app exists to capture.
    public var detectedLanguages: [String]
    public var failureReason: String?
    public var sharedAt: Date?
    /// Set when the 10-second-at-Stop promise was withdrawn, with the reason.
    public var promiseWithdrawnReason: String?

    public init(id: UUID = UUID(), createdAt: Date = Date(), inputRoute: InputRoute = .builtIn) {
        self.id = id
        self.createdAt = createdAt
        self.state = .recording
        self.segments = []
        self.inputRoute = inputRoute
        self.transcript = ""
        self.detectedLanguages = []
    }

    public var totalDurationSeconds: Double {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Captured audio not yet fed to the transcriber. Drives both backpressure
    /// thresholds in `TranscriptionCoordinator`.
    public var backlogSeconds: Double {
        segments.reduce(0) { $0 + $1.untranscribedSeconds }
    }

    /// Audio is the only recovery path for a bad transcript, so it survives
    /// until an explicit purge — never an automatic one.
    public var isPurgeable: Bool {
        state == .shared || state == .ready
    }
}
