import AVFoundation
import Foundation
import OSLog

/// Owns the `AVAudioSession`: category, input route, and interruptions.
///
/// Interruption handling is the hardest part of background audio and the one
/// success criterion 2b turns on. The important case is not the one that
/// works — it is the one where `.ended` never arrives.
public final class AudioSessionManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "AudioSession")
    private let session = AVAudioSession.sharedInstance()

    /// Fired when the system tore down capture. The recorder finalizes the
    /// current segment.
    public var onInterruptionBegan: (@Sendable () -> Void)?
    /// Fired only when the system says resumption is allowed. Opens a NEW
    /// segment in the same job.
    public var onInterruptionEndedShouldResume: (@Sendable () -> Void)?
    /// Route changed mid-capture (AirPods connected or pulled out).
    public var onRouteChanged: (@Sendable (RecordingJob.InputRoute) -> Void)?

    public init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: nil
        ) { [weak self] note in self?.handleInterruption(note) }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.onRouteChanged?(self.currentRoute())
        }
    }

    // MARK: - Activation

    public func activate() throws {
        // `.measurement` disables AGC and system voice processing, which the
        // source spec chose for a clean ASR signal. Note that the M0 fixture
        // is deliberately noisy handheld street audio, where disabling input
        // processing may be the WRONG call — M0 step 4 A/Bs this rather than
        // inheriting it.
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(Double(WAVWriter.sampleRate))
        try preferBuiltInMic()
        try session.setActive(true)
    }

    /// Only after the tail chunk has rendered and the job reached `.ready`.
    /// Deactivating at Stop would drop the execution assertion mid-inference.
    public func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Input route

    /// A walking capture is likely on AirPods, and HFP input is narrowband —
    /// that costs more accuracy than the `.measurement` A/B can recover. Force
    /// the built-in mic; record whatever we actually got in the job either way.
    private func preferBuiltInMic() throws {
        guard let inputs = session.availableInputs else { return }
        if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        }
    }

    public func currentRoute() -> RecordingJob.InputRoute {
        guard let port = session.currentRoute.inputs.first else { return .other }
        switch port.portType {
        case .builtInMic: return .builtIn
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return .bluetooth
        case .headsetMic, .usbAudio: return .wired
        default: return .other
        }
    }

    // MARK: - Permission

    /// Three states, and they need different handling — collapsing them to a
    /// bool is what produced the "grant it in Settings" dead end, where
    /// Settings had no toggle to offer because the app had never asked.
    ///
    /// iOS only lists an app under Settings -> Privacy -> Microphone once the
    /// app has actually requested access. `.undetermined` means *we* have not
    /// asked yet; sending the user to Settings at that point is a dead end.
    public enum MicPermission {
        /// Never requested. Must prompt — Settings cannot help here.
        case undetermined
        case granted
        /// Explicitly refused. Settings is now the only route.
        case denied
    }

    public static var micPermission: MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }

    /// Checked before an intent starts anything. A Lock Screen entry point
    /// cannot prompt, so the failure must be visible and actionable rather
    /// than a silent no-op recording.
    public static func hasMicrophonePermission() -> Bool {
        micPermission == .granted
    }

    /// Prompts. Only ever call this from the foreground.
    ///
    /// Wrapped around the completion-handler API rather than the async
    /// overload: this is the form that has existed since iOS 17 and it costs
    /// nothing to not gamble on the bridge.
    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // `.appWasSuspended` as an interruption reason is iOS telling you
            // directly that it suspends audio apps which stop doing audio.
            log.notice("Interruption began")
            onInterruptionBegan?()

        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                log.notice("Interruption ended, resuming into a new segment")
                onInterruptionEndedShouldResume?()
            } else {
                log.notice("Interruption ended without shouldResume; job stays captured")
            }

        @unknown default:
            break
        }
    }

    // MARK: - The miss path
    //
    // A backgrounded recorder interrupted by a call is commonly SUSPENDED, and
    // may never receive `.ended` at all — it can stay suspended until next
    // foreground. Nothing above fires in that case, by definition.
    //
    // The recovery is therefore not here. It is in `JobStore.recoverInterrupted()`,
    // which runs at launch, repairs the WAV header, and demotes the job to
    // `.captured` so the queue finishes it. The user is notified via
    // `UNUserNotificationCenter` rather than finding a silently truncated note.
    //
    // M0 step 5 exists to find out which of the two actually happens on this
    // device: resume, or suspend-and-recover. Criterion 2b accepts either, but
    // the design has to say which one ships.
}
