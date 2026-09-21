import ActivityKit
import Foundation

/// Live Activity state, shared between the app and the widget extension.
///
/// This is the design's UI channel while the screen is locked. Three things are
/// promised to the user in that state and have nowhere else to surface:
/// thermal withdrawal of the 10-second promise, backlog breach, and the
/// interruption miss path.
///
/// It is also mandatory, not decorative: on iOS 26 an intent conforming to
/// `AudioRecordingIntent` must start and maintain a Live Activity for the
/// duration of the recording, or the system stops the recording.
///
/// ActivityKit passes `ContentState` through the system, NOT through an App
/// Group — which is what lets this project sign under free personal-team
/// provisioning. Do not replace this with shared-container state.
public struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// When capture began. Drives the elapsed-time timer in the UI.
        public var startedAt: Date
        /// Job lifecycle, mirrored from `RecordingJob.State`.
        public var phase: Phase
        /// Seconds of captured-but-not-yet-transcribed audio.
        public var backlogSeconds: Double
        /// Set when the 10-second-at-Stop promise no longer holds, with the
        /// reason shown to the user rather than silently degrading.
        public var promiseWithdrawnReason: String?

        public init(
            startedAt: Date,
            phase: Phase,
            backlogSeconds: Double = 0,
            promiseWithdrawnReason: String? = nil
        ) {
            self.startedAt = startedAt
            self.phase = phase
            self.backlogSeconds = backlogSeconds
            self.promiseWithdrawnReason = promiseWithdrawnReason
        }
    }

    public enum Phase: String, Codable, Hashable, Sendable {
        case recording
        /// Stop pressed. The engine tap is still running and a background task
        /// is held while the tail chunk finishes — see `AudioRecorder.stop()`.
        case finishing
        case ready
        case failed
    }

    /// Stable id so the app can find and end its own activity after a relaunch.
    public var jobID: UUID

    public init(jobID: UUID) {
        self.jobID = jobID
    }
}
