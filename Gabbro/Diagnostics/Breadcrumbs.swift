import Foundation
import OSLog

/// A stack trace for people without a debugger.
///
/// There is no Mac in this loop, so a crash is a black box: the app vanishes
/// and `OSLog` output never reaches anyone. `M0Telemetry` cannot help, because
/// it writes its report at the *end* of a run and a crash never gets there.
///
/// So this drops a durable marker at each stage of a risky sequence,
/// synchronously, straight to disk. At next launch the trail is read back: if
/// the last marker is not a completion, that is where the app died. Crude, and
/// it has narrowed a crash to a single line more than once.
///
/// Visible in Files alongside the M0 reports, and surfaced in the UI at launch
/// so a crash cannot pass unnoticed.
public enum Breadcrumbs {
    private static let log = Logger(subsystem: "com.pmelander.gabbro", category: "Breadcrumbs")

    private static var url: URL {
        JobStore.shared.diagnosticsDirectory
            .appendingPathComponent("breadcrumbs.txt")
    }

    /// Append a marker and get it onto disk before returning. The whole point
    /// is surviving a process that is about to die, so this is deliberately
    /// synchronous and unbuffered — do not "optimise" it onto a queue.
    public static func drop(_ marker: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(marker)\n"
        log.debug("\(marker, privacy: .public)")
        let fm = FileManager.default
        let dir = JobStore.shared.diagnosticsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Reads the trail and clears it. Call once at launch.
    ///
    /// - Returns: the last marker recorded, or nil if the trail was empty or
    ///   had been closed out cleanly.
    public static func readAndClear() -> (last: String, full: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: url)

        let lines = text.split(separator: "\n").map(String.init)
        guard let lastLine = lines.last else { return nil }
        // A trail that ends in a completion marker is a clean run, not a crash.
        if lastLine.hasSuffix(Marker.stopDone) || lastLine.hasSuffix(Marker.startDone) {
            return nil
        }
        return (lastLine, text)
    }

    /// Stage names. Kept as constants so a rename cannot silently break the
    /// "did it finish cleanly" check above.
    public enum Marker {
        public static let startBegin = "start:begin"
        public static let startDone = "start:done"
        public static let stopBegin = "stop:begin"
        public static let stopRecorderStopped = "stop:recorder-stopped"
        public static let stopDrainBegin = "stop:drain-begin"
        public static let stopDrainDone = "stop:drain-done"
        public static let stopRendered = "stop:rendered"
        public static let stopEngineReleased = "stop:engine-released"
        public static let stopTelemetryWritten = "stop:telemetry-written"
        public static let stopActivityEnded = "stop:activity-ended"
        public static let stopDone = "stop:done"
    }
}
