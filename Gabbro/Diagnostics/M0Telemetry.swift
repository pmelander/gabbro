import Foundation
import OSLog
import UIKit
import os

/// Self-measurement for M0, because there is no debugger here.
///
/// Development happens on Windows: CI builds an unsigned .ipa, you sideload
/// it, and the phone is on its own. No Instruments, no console, no
/// breakpoints. So the app measures itself and writes a report to
/// `Documents/Diagnostics/`, which is visible in Files because
/// `UIFileSharingEnabled` is set.
///
/// This is not a nice-to-have. M0 has four gates and a stop-the-project
/// failure policy; without numbers there is no gate, only a vibe.
///
/// **What it deliberately measures, and why each one:**
/// - *Available memory*, via `os_proc_available_memory()`, not RSS. RSS is
///   measured against an unstated limit, and a backgrounded app gets a
///   tighter jetsam limit than a foreground one. The gate is headroom.
/// - *Thermal state over time*, sampled — a single reading at the end tells
///   you nothing about minute 18.
/// - *Battery delta*, against a baseline run with inference disabled. An
///   absolute number is meaningless; the ratio is the decision.
/// - *Throughput as RTF*, audio-seconds per wall-clock-second, measured while
///   locked. CPU/ML work runs markedly slower backgrounded, so a foreground
///   measurement would flatter the design into passing.
/// - *Lock state*, tracked, so a run that never actually locked is marked
///   invalid instead of quietly passing under easy conditions.
public actor M0Telemetry {
    public static let shared = M0Telemetry()

    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "M0")

    // MARK: Gates (from the design doc — change these and you change M0)

    /// Sustained single-stream throughput, measured under lock.
    public static let speedGateRTF: Double = 2.0
    /// Headroom before jetsam, not resident size.
    public static let memoryGateAvailableBytes: Int = 400 * 1_024 * 1_024
    /// Anything at or above this fails.
    public static let thermalGateCeiling = ProcessInfo.ThermalState.serious

    // MARK: State

    private var run: Run?
    private var sampler: Task<Void, Never>?
    private var lockObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Lifecycle

    /// Call when a capture starts. `inferenceEnabled: false` produces the
    /// battery baseline the real run is compared against.
    public func begin(jobID: UUID, inferenceEnabled: Bool) async {
        await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true }

        run = Run(
            jobID: jobID,
            inferenceEnabled: inferenceEnabled,
            startedAt: Date(),
            deviceModel: await Self.deviceModel(),
            systemVersion: await MainActor.run { UIDevice.current.systemVersion },
            batteryStart: await MainActor.run { Double(UIDevice.current.batteryLevel) }
        )

        await observeLockState()
        startSampling()
        log.notice("M0 run began, inference=\(inferenceEnabled, privacy: .public)")
    }

    /// Call once the job reaches `.ready` (or fails). Writes the report.
    @discardableResult
    public func end(outcome: String) async -> URL? {
        sampler?.cancel()
        sampler = nil
        await removeLockObservers()

        guard var finished = run else { return nil }
        finished.endedAt = Date()
        finished.batteryEnd = await MainActor.run { Double(UIDevice.current.batteryLevel) }
        finished.outcome = outcome
        run = nil

        do {
            let url = try write(finished)
            log.notice("M0 report written: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            log.error("M0 report failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Recording events

    /// Called by `TranscriptionCoordinator` after every chunk. The ratio of
    /// these two numbers is the speed gate.
    public func noteChunk(audioSeconds: Double, wallSeconds: Double) {
        guard wallSeconds > 0 else { return }
        run?.chunks.append(.init(
            at: Date(), audioSeconds: audioSeconds, wallSeconds: wallSeconds,
            availableBytes: Self.availableMemoryBytes()
        ))
    }

    /// Cold model load is a separate, one-off cost from steady-state
    /// throughput and is reported separately.
    public func noteModelLoad(seconds: Double, artifactBytes: Int?) {
        run?.modelLoadSeconds = seconds
        run?.modelArtifactBytes = artifactBytes
    }

    public func noteBacklog(seconds: Double) {
        run?.maxBacklogSeconds = max(run?.maxBacklogSeconds ?? 0, seconds)
    }

    public func noteEvent(_ text: String) {
        run?.events.append(.init(at: Date(), text: text))
        log.notice("M0 event: \(text, privacy: .public)")
    }

    // MARK: - Sampling

    private func startSampling() {
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func sample() async {
        let locked = await MainActor.run { !UIApplication.shared.isProtectedDataAvailable }
        run?.samples.append(.init(
            at: Date(),
            availableBytes: Self.availableMemoryBytes(),
            thermal: ProcessInfo.processInfo.thermalState.label,
            battery: await MainActor.run { Double(UIDevice.current.batteryLevel) },
            locked: locked
        ))
    }

    /// `protectedDataWillBecomeUnavailable` is the reliable signal that the
    /// device actually locked — there is no direct "is the screen locked" API.
    private func observeLockState() async {
        let center = NotificationCenter.default
        let locked = center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: nil
        ) { _ in Task { await M0Telemetry.shared.noteEvent("device locked") } }

        let unlocked = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: nil
        ) { _ in Task { await M0Telemetry.shared.noteEvent("device unlocked") } }

        lockObservers = [locked, unlocked]
    }

    private func removeLockObservers() async {
        lockObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lockObservers = []
    }

    // MARK: - Memory

    /// Headroom before jetsam, in bytes.
    ///
    /// `os_proc_available_memory()` returns 0 when called from an extension
    /// or in some simulator contexts. A zero is reported as-is rather than
    /// hidden, so a broken measurement cannot look like a passing one.
    public static func availableMemoryBytes() -> Int {
        os_proc_available_memory()
    }

    private static func deviceModel() async -> String {
        var info = utsname()
        uname(&info)
        let raw = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }
        return raw ?? "unknown"
    }

    // MARK: - Report

    private func write(_ run: Run) throws -> URL {
        let dir = JobStore.shared.diagnosticsDirectory
        try FileManager.default.createDirectory(withIntermediateDirectories: true, at: dir)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("m0-\(stamp.string(from: run.startedAt)).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Report(run)).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Data

extension M0Telemetry {
    struct Run {
        var jobID: UUID
        var inferenceEnabled: Bool
        var startedAt: Date
        var endedAt: Date?
        var deviceModel: String
        var systemVersion: String
        var batteryStart: Double
        var batteryEnd: Double = -1
        var outcome: String = "unknown"
        var modelLoadSeconds: Double?
        var modelArtifactBytes: Int?
        var maxBacklogSeconds: Double = 0
        var samples: [Sample] = []
        var chunks: [Chunk] = []
        var events: [Event] = []
    }

    struct Sample: Codable {
        var at: Date
        var availableBytes: Int
        var thermal: String
        var battery: Double
        var locked: Bool
    }

    struct Chunk: Codable {
        var at: Date
        var audioSeconds: Double
        var wallSeconds: Double
        var availableBytes: Int
        var rtf: Double { wallSeconds > 0 ? audioSeconds / wallSeconds : 0 }
    }

    struct Event: Codable {
        var at: Date
        var text: String
    }

    /// What lands in Files. Verdict first — the raw samples are there if you
    /// want them, but the four gates are the point.
    struct Report: Codable {
        var verdict: Verdict
        var run: RunSummary
        var samples: [Sample]
        var chunks: [Chunk]
        var events: [Event]

        init(_ r: Run) {
            let duration = (r.endedAt ?? Date()).timeIntervalSince(r.startedAt)
            let lockedSamples = r.samples.filter(\.locked)
            let lockedChunks = r.chunks.filter { chunk in
                r.samples.last { $0.at <= chunk.at }?.locked ?? false
            }

            // The speed gate is measured on chunks that ran while LOCKED.
            // A foreground measurement flatters the design into passing.
            let measured = lockedChunks.isEmpty ? r.chunks : lockedChunks
            let audio = measured.reduce(0) { $0 + $1.audioSeconds }
            let wall = measured.reduce(0) { $0 + $1.wallSeconds }
            let rtf = wall > 0 ? audio / wall : 0

            // Memory gate is the WORST sample, not the average.
            let memoryPool = lockedSamples.isEmpty ? r.samples : lockedSamples
            let minAvailable = memoryPool.map(\.availableBytes).filter { $0 > 0 }.min() ?? 0

            let worstThermal = r.samples.map(\.thermal).max(by: { ThermalRank.of($0) < ThermalRank.of($1) }) ?? "nominal"
            let batteryUsed = (r.batteryStart >= 0 && r.batteryEnd >= 0)
                ? max(0, r.batteryStart - r.batteryEnd) * 100 : -1

            self.run = RunSummary(
                jobID: r.jobID.uuidString,
                inferenceEnabled: r.inferenceEnabled,
                startedAt: r.startedAt,
                durationSeconds: duration,
                deviceModel: r.deviceModel,
                systemVersion: r.systemVersion,
                outcome: r.outcome,
                modelLoadSeconds: r.modelLoadSeconds,
                modelArtifactBytes: r.modelArtifactBytes,
                maxBacklogSeconds: r.maxBacklogSeconds,
                lockedForSeconds: Double(lockedSamples.count) * 5.0,
                chunkCount: r.chunks.count,
                chunksMeasuredWhileLocked: lockedChunks.count
            )

            self.verdict = Verdict(
                // A run that never locked, or is shorter than 20 minutes,
                // cannot answer the question M0 asks. Mark it invalid rather
                // than letting easy conditions produce a pass.
                valid: !lockedSamples.isEmpty && duration >= 1200 && !measured.isEmpty,
                validityNote: Self.validityNote(
                    locked: !lockedSamples.isEmpty, duration: duration, chunks: measured.count
                ),
                speedRTF: rtf,
                speedGate: rtf >= M0Telemetry.speedGateRTF ? "PASS" : "FAIL",
                minAvailableBytes: minAvailable,
                memoryGate: minAvailable >= M0Telemetry.memoryGateAvailableBytes ? "PASS" : "FAIL",
                worstThermal: worstThermal,
                thermalGate: ThermalRank.of(worstThermal) < ThermalRank.of("serious") ? "PASS" : "FAIL",
                batteryPercentUsed: batteryUsed,
                batteryGate: "MEASURE — compare against an inferenceEnabled:false run of the same length"
            )

            self.samples = r.samples
            self.chunks = r.chunks
            self.events = r.events
        }

        static func validityNote(locked: Bool, duration: Double, chunks: Int) -> String {
            var problems: [String] = []
            if !locked { problems.append("device never locked during the run") }
            if duration < 1200 { problems.append("run was \(Int(duration))s, gates are specified for 1200s") }
            if chunks == 0 { problems.append("no chunks transcribed") }
            return problems.isEmpty ? "valid" : "INVALID: " + problems.joined(separator: "; ")
        }
    }

    struct RunSummary: Codable {
        var jobID: String
        var inferenceEnabled: Bool
        var startedAt: Date
        var durationSeconds: Double
        var deviceModel: String
        var systemVersion: String
        var outcome: String
        var modelLoadSeconds: Double?
        var modelArtifactBytes: Int?
        var maxBacklogSeconds: Double
        var lockedForSeconds: Double
        var chunkCount: Int
        var chunksMeasuredWhileLocked: Int
    }

    struct Verdict: Codable {
        var valid: Bool
        var validityNote: String
        var speedRTF: Double
        var speedGate: String
        var minAvailableBytes: Int
        var memoryGate: String
        var worstThermal: String
        var thermalGate: String
        var batteryPercentUsed: Double
        var batteryGate: String
    }

    enum ThermalRank {
        static func of(_ label: String) -> Int {
            switch label {
            case "nominal": 0
            case "fair": 1
            case "serious": 2
            case "critical": 3
            default: 0
            }
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
