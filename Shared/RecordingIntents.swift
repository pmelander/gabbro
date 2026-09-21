import AppIntents
import Foundation

/// The bridge that lets a shared intent reach app-only code.
///
/// The intents below are compiled into BOTH targets, because the
/// `ControlWidget` in the extension has to reference the intent type. Their
/// bodies only ever *execute* in the app's process — that is what
/// `LiveActivityIntent` / `AudioRecordingIntent` conformance buys, and it is
/// the reason a locked-screen start might be possible at all. An intent that
/// ran in the widget extension process could never host a capture session:
/// that process has no `UIBackgroundModes: audio`.
///
/// So the extension compiles a `perform()` that finds no handler and does
/// nothing, and the app registers the real one at launch.
public protocol RecordingControlHandling: AnyObject, Sendable {
    @MainActor func startCapture() async throws
    @MainActor func stopCapture() async
    nonisolated func microphoneIsAuthorized() -> Bool
}

public enum RecordingControl_Registry {
    @MainActor public static var handler: (any RecordingControlHandling)?
}

public struct MicrophoneNotAuthorized: LocalizedError {
    public init() {}
    /// Points at the app, not at Settings. An intent can fire before the app
    /// has ever requested access, and in that state Settings has no toggle to
    /// offer — iOS does not list an app under Privacy > Microphone until it
    /// has asked. Opening the app once is the only thing that works in both
    /// the never-asked and the denied case.
    public var errorDescription: String? {
        "Open Gabbro once to grant microphone access, then try again."
    }
}

// MARK: - Intents

// M0 SPIKE (design doc, "Entry and exit"):
//   Does a ControlWidget-hosted intent conforming to AudioRecordingIntent +
//   LiveActivityIntent start capture from the LOCKED screen on this device
//   and OS build?
//
// Both readings of Apple's docs are live. AudioRecordingIntent is documented
// as an intent that *starts* recording; Apple also documents that recording
// cannot be initiated from a fully backgrounded state. Shipped prior art
// appears to manage it. Find out empirically, then delete the losing branch.
//
// If the spike FAILS: set `openAppWhenRun = true` below. The cost is Face ID,
// required because foregrounding an app needs an unlocked device — not
// because the intent touches the microphone.

@available(iOS 26.0, *)
public struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Start Recording"
    public static var description = IntentDescription(
        "Starts a Gabbro voice capture. Audio is transcribed on this device and never leaves it."
    )

    /// Leave false while the M0 spike is open.
    public static var openAppWhenRun = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let handler = RecordingControl_Registry.handler else { return .result() }
        // A locked-screen entry point cannot prompt for permission. Fail
        // visibly rather than starting a silent no-op recording.
        guard handler.microphoneIsAuthorized() else { throw MicrophoneNotAuthorized() }
        try await handler.startCapture()
        return .result()
    }
}

@available(iOS 26.0, *)
public struct StopRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Stop Recording"
    public static var description = IntentDescription(
        "Stops the current capture and finishes the transcript."
    )

    /// Stopping from the Lock Screen is the well-supported case: the session
    /// already exists, so this never needs to foreground anything.
    public static var openAppWhenRun = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await RecordingControl_Registry.handler?.stopCapture()
        return .result()
    }
}

@available(iOS 26.0, *)
public struct GabbroShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start a \(.applicationName) capture", "Record with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "mic.circle.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop the \(.applicationName) capture"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle.fill"
        )
    }
}
