import SwiftUI

/// Deliberately thin. M1 is a walking skeleton: record, stop, share, retry.
/// Queue UI, settings, templates and retention are M2.
struct CaptureView: View {
    @Environment(CaptureModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// Non-nil while the share sheet is up. Presenting by item rather than by
    /// bool keeps the job identity attached, so the completion handler marks
    /// the right note shared.
    @State private var sharingJob: RecordingJob?
    /// Set when a swipe-delete needs confirming first. Only for recordings
    /// whose transcript has not reached the vault yet.
    @State private var pendingDelete: RecordingJob?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                recordButton

                modelStatus

                if model.recorder.isRecording, let job = model.recorder.job {
                    VStack(spacing: 4) {
                        // Counts up from when capture began. The one thing you
                        // want on screen while recording is how long you have
                        // been talking.
                        Text(job.createdAt, style: .timer)
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text("Recording — you can lock the phone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // No debugger in this loop, so a crash has to announce itself.
                if let stage = model.lastCrashStage {
                    Label("Previous run ended at: \(stage)", systemImage: "ant.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .padding(.horizontal)
                }

                List(model.jobs) { job in
                    row(for: job)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                // Confirm only when it would destroy the only
                                // copy. Once a note is in Obsidian, deleting
                                // the local original is not destructive and an
                                // extra tap is just friction.
                                if model.deleteIsLastCopy(job) {
                                    pendingDelete = job
                                } else {
                                    Task { await model.delete(job) }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.plain)

                if let summary = model.lastPurgeSummary {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(summary).font(.caption)
                        Spacer()
                        Button("OK") { model.dismissPurgeSummary() }.font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }

                if model.storeBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: model.storeBytes, countStyle: .file)) on device · audio kept \(JobStore.retentionDays) days")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                }
            }
            .padding(.top, 32)
            .navigationTitle("Gabbro")
            .alert(
                "Something went wrong",
                isPresented: .constant(model.lastError != nil),
                actions: { Button("OK") {} },
                message: { Text(model.lastError ?? "") }
            )
            // Transcription cannot finish in a background window, so the
            // queue moves whenever the app is in front. Without this a
            // "Queued" row would sit there until the user tapped something.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await model.resumeQueue()
                        await model.runRetention()
                    }
                }
            }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: .constant(pendingDelete != nil),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { job in
                Button("Delete recording and audio", role: .destructive) {
                    Task { await model.delete(job) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This has not been shared to Obsidian yet, so the audio is the only copy. Deleting cannot be undone.")
            }
            .sheet(item: $sharingJob) { job in
                if let url = model.noteURL(for: job) {
                    // Marked shared only when the user actually completed a
                    // share. Dismissing the sheet leaves the note unshared,
                    // which is the point: `markShared` drives the duplicate
                    // warning.
                    ShareSheet(url: url) { completed in
                        if completed { Task { await model.markShared(job) } }
                        sharingJob = nil
                    }
                }
            }
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
                .foregroundStyle(tintForRecordButton)
        }
        .buttonStyle(.plain)
        // Disabled until the model is on disk and loaded. Previously this was
        // tappable during a multi-minute download and simply did nothing,
        // which read as a broken app.
        .disabled(!model.modelState.isReady && !model.recorder.isRecording)
        .accessibilityLabel(model.recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var tintForRecordButton: Color {
        if model.recorder.isRecording { return .red }
        return model.modelState.isReady ? .accentColor : .secondary
    }

    /// Never leave the first run silent. A several-hundred-MB download with no
    /// indicator is indistinguishable from a hang.
    @ViewBuilder
    private var modelStatus: some View {
        switch model.modelState {
        case .idle:
            Label("Preparing…", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.secondary)

        case .downloading(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
                Text("Downloading speech model — \(Int(fraction * 100))%")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("One time, a few hundred MB. Wi-Fi recommended.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(model.modelDescription)
                    .font(.caption2).foregroundStyle(.tertiary)
            }

        case .loading:
            VStack(spacing: 6) {
                ProgressView()
                Text("Loading model onto the Neural Engine…")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        case .ready:
            EmptyView()

        case .failed(let reason):
            VStack(spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await model.prepareModel() } }
                    .buttonStyle(.bordered)
                Text(model.modelDescription)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func row(for job: RecordingJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Text(Self.duration(job.totalDurationSeconds))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                statusBadge(for: job)
            }

            // Queue transparency: every row says what is happening to it.
            if model.transcribingJobID == job.id {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.transcribeProgress ?? 0)
                    Text("Transcribing — \(Int((model.transcribeProgress ?? 0) * 100))%  ·  on device")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let purged = job.audioPurgedAt {
                Label(
                    "Audio removed \(purged.formatted(.relative(presentation: .named))) · transcript kept",
                    systemImage: "clock.badge.xmark"
                )
                .font(.caption).foregroundStyle(.tertiary)
            } else if job.state == .captured {
                Label("Queued — will transcribe when Gabbro is open",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
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

            if job.state == .ready || job.state == .shared, model.noteURL(for: job) != nil {
                // A plain Button presenting ShareSheet, NOT a ShareLink.
                // ShareLink cannot report completion, and attaching a
                // simultaneousGesture to find out made the first tap mark the
                // note shared without ever opening the share sheet.
                Button {
                    sharingJob = job
                } label: {
                    Label(
                        model.wouldDuplicate(job) ? "Share again (creates a duplicate)" : "Share to Obsidian",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
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

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
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
