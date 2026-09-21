import SwiftUI

/// Deliberately thin. M1 is a walking skeleton: record, stop, share, retry.
/// Queue UI, settings, templates and retention are M2.
struct CaptureView: View {
    @Environment(CaptureModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                recordButton

                if model.recorder.isRecording {
                    Text("Recording — you can lock the phone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                List(model.jobs) { job in
                    row(for: job)
                }
                .listStyle(.plain)
            }
            .padding(.top, 32)
            .navigationTitle("Gabbro")
            .alert(
                "Something went wrong",
                isPresented: .constant(model.lastError != nil),
                actions: { Button("OK") {} },
                message: { Text(model.lastError ?? "") }
            )
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if model.recorder.isRecording { await model.stop() } else { await model.start() }
            }
        } label: {
            Image(systemName: model.recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(model.recorder.isRecording ? .red : .accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.recorder.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private func row(for job: RecordingJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Spacer()
                statusBadge(for: job)
            }

            if !job.transcript.isEmpty {
                Text(job.transcript)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let reason = job.promiseWithdrawnReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if job.state == .ready || job.state == .shared, let url = model.noteURL(for: job) {
                // A FILE URL, not Data or String. Handing over a string loses
                // the filename and can send Obsidian's share extension down a
                // different branch. Confirmed 2026-09-21: a shared .md becomes
                // a note, not an attachment.
                ShareLink(item: url) {
                    Label(
                        model.wouldDuplicate(job) ? "Share again (creates a duplicate)" : "Share to Obsidian",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.subheadline)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    Task { await model.markShared(job) }
                })
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(for job: RecordingJob) -> some View {
        Text(job.state.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color(for: job.state).opacity(0.15), in: Capsule())
            .foregroundStyle(color(for: job.state))
    }

    private func color(for state: RecordingJob.State) -> Color {
        switch state {
        case .recording: .red
        case .captured, .transcribing: .orange
        case .ready: .green
        case .shared: .secondary
        case .failed: .pink
        }
    }
}
