import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action Button entry point.
///
/// **Stateless button, not a stateful toggle — and that is a signing
/// constraint, not a style choice.**
///
/// A `ControlWidgetToggle` needs a value provider to answer "am I recording?".
/// That provider runs in THIS process (the widget extension), so reading the
/// app's state would require an App Group — and App Groups cannot be signed
/// under free personal-team provisioning. They were the only paid-only
/// capability this design needed.
///
/// So: two plain buttons, and the Live Activity carries recording state.
/// ActivityKit passes ContentState through the system rather than a shared
/// container, so nothing here needs an entitlement. Do not "improve" this
/// into a toggle without re-reading the Distribution Plan — it would put the
/// $99/yr back on the critical path.
@available(iOS 26.0, *)
struct RecordingControl: ControlWidget {
    static let startKind = "com.pmelander.gabbro.control.start"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.startKind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Start Gabbro Recording")
        .description("Begin an on-device voice capture.")
    }
}
