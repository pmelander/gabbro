import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity.
///
/// Two jobs, both load-bearing:
///
/// 1. **It is mandatory.** On iOS 26 an intent conforming to
///    `AudioRecordingIntent` must start and maintain a Live Activity for the
///    duration of the recording, or the system stops the recording.
/// 2. **It is the only UI channel that reaches a locked screen.** Three things
///    the design promises to surface have nowhere else to go: withdrawal of
///    the 10-second-at-Stop promise under thermal pressure, a backlog breach,
///    and the interruption miss path.
///
/// It also carries recording state, which is why the Control Center button can
/// stay stateless and the project can avoid an App Group it could not sign.
@available(iOS 26.0, *)
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding()
                .activityBackgroundTint(.black.opacity(0.65))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(context.state.phase))
                        .foregroundStyle(tint(context.state.phase))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(headline(context.state)).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording {
                        Text(context.state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: 56)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .recording {
                        Button(intent: StopRecordingIntent()) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .tint(.red)
                    } else if let reason = context.state.promiseWithdrawnReason {
                        Text(reason).font(.caption2).foregroundStyle(.orange)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context.state.phase))
                    .foregroundStyle(tint(context.state.phase))
            } compactTrailing: {
                if context.state.phase == .recording {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 40)
                }
            } minimal: {
                Image(systemName: icon(context.state.phase))
                    .foregroundStyle(tint(context.state.phase))
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: RecordingActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(state.phase))
                .font(.title2)
                .foregroundStyle(tint(state.phase))

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(state)).font(.subheadline.weight(.medium))
                if let reason = state.promiseWithdrawnReason {
                    Text(reason).font(.caption2).foregroundStyle(.orange)
                } else if state.phase == .recording {
                    Text("On-device. Nothing leaves your phone.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if state.phase == .recording {
                Text(state.startedAt, style: .timer)
                    .font(.headline.monospacedDigit())
                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private func headline(_ state: RecordingActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .recording: "Recording"
        // The mic indicator stays lit here, deliberately: the engine tap runs
        // past Stop so the tail chunk can finish inside a live audio session.
        // Expected, not a bug.
        case .finishing: "Finishing transcript…"
        case .ready: "Note ready to share"
        case .failed: "Saved — transcript pending"
        }
    }

    private func icon(_ phase: RecordingActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: "mic.fill"
        case .finishing: "waveform"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ phase: RecordingActivityAttributes.Phase) -> Color {
        switch phase {
        case .recording: .red
        case .finishing: .orange
        case .ready: .green
        case .failed: .yellow
        }
    }
}
