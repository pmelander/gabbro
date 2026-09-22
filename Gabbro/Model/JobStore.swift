import Foundation
import OSLog

/// On-disk home for jobs, audio segments and rendered markdown.
///
/// Everything lives under `Documents/`, which is what makes the Files-app
/// recovery affordance work (`UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`). Two consequences are deliberate and
/// booked in the design doc:
///
/// - **Excluded from iCloud backup.** Retained audio in `Documents/` would
///   otherwise be uploaded to iCloud Backup, which contradicts both "radios
///   off" and the source spec's "no audio leaves the phone, ever". Success
///   criterion 1 would not catch it, because it is OS traffic, not app traffic.
/// - **Readable after first unlock.** File protection is
///   `.completeUntilFirstUserAuthentication`, because writes must succeed
///   while the screen is locked. Anything stricter silently loses audio from
///   the first lock onward.
public actor JobStore {
    public static let shared = JobStore()

    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "JobStore")
    private let fm = FileManager.default

    /// Free space below which a new recording is refused outright.
    public static let minimumFreeBytesToStart: Int64 = 250 * 1_024 * 1_024
    /// Free space at which an in-flight recording finalizes its segment and stops.
    public static let hardAbortFreeBytes: Int64 = 100 * 1_024 * 1_024

    private var jobs: [UUID: RecordingJob] = [:]

    // MARK: - Directories

    private var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public nonisolated var audioDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
    }

    public nonisolated var notesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// M0 reports. Visible in Files, which is how measurements get off the
    /// phone when there is no Mac and therefore no Instruments.
    public nonisolated var diagnosticsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var jobsFile: URL {
        documents.appendingPathComponent("jobs.json")
    }

    // MARK: - Lifecycle

    public func prepare() throws {
        for dir in [audioDirectory, notesDirectory, diagnosticsDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try excludeFromBackup(dir)
            try setProtection(dir)
        }
        try load()
        try recoverInterrupted()
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private func setProtection(_ url: URL) throws {
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Persistence

    /// Persist before advancing state, never after. A crash between the state
    /// change and the write is the case this ordering exists to survive.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Array(jobs.values))
        try data.write(to: jobsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func load() throws {
        guard fm.fileExists(atPath: jobsFile.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode([RecordingJob].self, from: Data(contentsOf: jobsFile))
        jobs = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: - Crash and suspension recovery

    /// Runs at launch. Repairs WAV headers left with placeholder sizes by a
    /// force-quit or a jetsam kill, and demotes any job still marked
    /// `recording` or `transcribing` to `captured` so the queue picks it up.
    ///
    /// This is also the miss path for an interruption whose `.ended`
    /// notification never arrived because the app was suspended — see
    /// `AudioSessionManager`.
    private func recoverInterrupted() throws {
        var recovered = 0
        for (id, var job) in jobs where job.state == .recording || job.state == .transcribing {
            // Same hazard as TranscriptionCoordinator.drain: iterating
            // `job.segments.indices` holds a read access open across a body
            // that mutates `job.segments`. Snapshot the count instead.
            // Re-attach audio the job record does not know about.
            //
            // Segments are persisted the moment their file is created, but
            // builds before that fix wrote the WAV without ever recording the
            // segment — so a force-quit left audio on disk that nothing
            // pointed at, and recovery looped over an empty list. Files are
            // named "<jobID>-<index>.wav", which is enough to reconstruct.
            // This also rescues recordings stranded by those builds.
            let known = Set(job.segments.map(\.filename))
            let prefix = "\(id.uuidString)-"
            let onDisk = (try? fm.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
            for name in onDisk.sorted()
            where name.hasPrefix(prefix) && name.hasSuffix(".wav") && !known.contains(name) {
                let url = audioDirectory.appendingPathComponent(name)
                // `try?` flattens here: repairHeader is `throws -> Double?`,
                // so this binds a Double, not a Double?.
                guard let seconds = try? WAVWriter.repairHeader(at: url), seconds > 0
                else { continue }
                let index = Int(name.dropFirst(prefix.count).dropLast(4)) ?? job.segments.count
                job.segments.append(.init(
                    index: index, filename: name,
                    frameCount: Int(seconds * Double(WAVWriter.sampleRate)),
                    transcribedFrames: 0
                ))
                log.notice("Recovered orphaned segment \(name, privacy: .public)")
            }
            job.segments.sort { $0.index < $1.index }

            // Then repair the headers of everything, known or recovered. A
            // force-quit leaves placeholder sizes in the RIFF header, so the
            // real length comes from the file on disk.
            let segmentCount = job.segments.count
            for i in 0..<segmentCount {
                let url = audioDirectory.appendingPathComponent(job.segments[i].filename)
                if let seconds = try? WAVWriter.repairHeader(at: url) {
                    job.segments[i].frameCount = Int(seconds * Double(WAVWriter.sampleRate))
                }
            }

            // Anything with no audio at all is a failed start, not a recovery.
            job.state = job.segments.contains { $0.frameCount > 0 } ? .captured : .failed
            if job.state == .failed { job.failureReason = "No audio was captured" }
            jobs[id] = job
            recovered += 1
        }
        if recovered > 0 {
            log.notice("Recovered \(recovered, privacy: .public) interrupted job(s) at launch")
            try save()
        }
    }

    // MARK: - Free space

    public nonisolated func freeBytes() -> Int64 {
        let values = try? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public nonisolated func hasRoomToStart() -> Bool {
        freeBytes() > Self.minimumFreeBytesToStart
    }

    public nonisolated func mustAbortForSpace() -> Bool {
        freeBytes() < Self.hardAbortFreeBytes
    }

    // MARK: - CRUD

    public func upsert(_ job: RecordingJob) throws {
        jobs[job.id] = job
        try save()
    }

    public func job(_ id: UUID) -> RecordingJob? { jobs[id] }

    public func all() -> [RecordingJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func pendingWork() -> [RecordingJob] {
        all().filter { $0.state == .captured || $0.state == .transcribing }
    }

    /// Explicit purge only. Retention default is 30 days, manual — never a
    /// quiet automatic sweep, because the audio is the sole recovery path.
    public func purgeAudio(for id: UUID) throws {
        guard var job = jobs[id], job.isPurgeable else { return }
        for segment in job.segments {
            try? fm.removeItem(at: audioDirectory.appendingPathComponent(segment.filename))
        }
        job.segments = []
        jobs[id] = job
        try save()
    }

    public func totalStoreBytes() -> Int64 {
        var total: Int64 = 0
        for dir in [audioDirectory, notesDirectory] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
