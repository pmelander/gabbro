import Foundation

/// Streaming 16 kHz mono Int16 WAV writer with crash-safe header repair.
///
/// Two design decisions live here, both from
/// `docs/designs/voice-capture-obsidian-ios.md`:
///
/// 1. **Int16 on disk, not Float32.** 16 kHz mono Float32 is 64 KB/s
///    (3.84 MB/min, ~77 MB per 20-minute note). Int16 halves that to
///    ~1.92 MB/min. Conversion back to Float32 happens at read time for the
///    model. This is quantization, not lossless — immaterial to WER, but do
///    not describe it as free.
///
/// 2. **Header repair at open.** A RIFF header written when the file is
///    created carries placeholder sizes. After a force-quit the file claims a
///    length it does not have, and most readers reject or truncate it. Success
///    criterion 3 ("force-quit mid-recording loses no audio") fails without
///    the repair below.
public final class WAVWriter {
    public static let sampleRate: Int = 16_000
    public static let channels: Int = 1
    public static let bitsPerSample: Int = 16

    private static let headerSize = 44
    private static let riffSizeOffset = 4
    private static let dataSizeOffset = 40

    private let handle: FileHandle
    public let url: URL
    private(set) public var frameCount: Int = 0

    /// Once closed, every further seek/write/close on a `FileHandle` raises an
    /// **ObjC exception** (`NSFileHandleOperationException`), and `try?` does
    /// NOT catch those — it is an immediate, un-debuggable process exit with
    /// no Swift error anywhere. So closure is tracked explicitly and every
    /// entry point is guarded. Cheap; the failure mode it prevents is not.
    private var isClosed = false

    /// Creates the file and writes a header with placeholder sizes.
    public init(creatingAt url: URL) throws {
        self.url = url
        FileManager.default.createFile(
            atPath: url.path,
            contents: Self.header(dataByteCount: 0),
            attributes: [
                // Written continuously while the device is locked. Anything at
                // .complete makes every write after lock fail and silently
                // loses audio from the first lock onward.
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Appends Float32 samples in [-1, 1], converting to Int16.
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !isClosed else { return }
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            // clamp before scaling: an out-of-range sample would wrap and
            // produce a loud click rather than a clipped peak.
            let clamped = min(max(sample, -1.0), 1.0)
            let value = Int16(clamped * 32767.0)
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: bytes)
        frameCount += samples.count
    }

    /// Rewrites the two length fields and closes. Call on the clean path.
    ///
    /// Idempotent: several paths can reach it (user stop, an interruption,
    /// teardown), and a second call used to be an uncatchable crash.
    public func finalizeAndClose() throws {
        guard !isClosed else { return }
        isClosed = true
        let dataBytes = frameCount * 2
        try handle.seek(toOffset: UInt64(Self.riffSizeOffset))
        try handle.write(contentsOf: Self.uint32(UInt32(36 + dataBytes)))
        try handle.seek(toOffset: UInt64(Self.dataSizeOffset))
        try handle.write(contentsOf: Self.uint32(UInt32(dataBytes)))
        try handle.close()
    }

    public var durationSeconds: Double {
        Double(frameCount) / Double(Self.sampleRate)
    }

    // MARK: - Crash recovery

    /// Repairs a WAV whose header still carries placeholder sizes, by deriving
    /// the real data length from the file on disk.
    ///
    /// Call this at launch for every segment of any job not in `.ready` or
    /// `.shared`. It is idempotent: a correctly finalized file is rewritten
    /// with identical values.
    ///
    /// - Returns: the recovered duration in seconds, or nil if the file is too
    ///   short to contain a header (nothing was ever captured).
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Double? {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attrs[.size] as? NSNumber)?.intValue,
              fileSize > headerSize else { return nil }

        let dataBytes = fileSize - headerSize
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(riffSizeOffset))
        try handle.write(contentsOf: uint32(UInt32(36 + dataBytes)))
        try handle.seek(toOffset: UInt64(dataSizeOffset))
        try handle.write(contentsOf: uint32(UInt32(dataBytes)))

        return Double(dataBytes / 2) / Double(sampleRate)
    }

    // MARK: - Reading back for inference

    /// Reads a frame range back as Float32 for the model.
    ///
    /// Chunked inference asks for windows rather than whole files, so this
    /// takes a range instead of loading a 20-minute recording into memory.
    public static func readFloat32(
        from url: URL,
        frameOffset: Int,
        frameCount: Int
    ) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(headerSize + frameOffset * 2))
        guard let data = try handle.read(upToCount: frameCount * 2), !data.isEmpty else {
            return []
        }
        return data.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            return ints.map { Float(Int16(littleEndian: $0)) / 32767.0 }
        }
    }

    // MARK: - Header bytes

    private static func header(dataByteCount: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(uint32(UInt32(36 + dataByteCount)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(uint32(16))                       // PCM fmt chunk size
        d.append(uint16(1))                        // PCM
        d.append(uint16(UInt16(channels)))
        d.append(uint32(UInt32(sampleRate)))
        d.append(uint32(UInt32(byteRate)))
        d.append(uint16(UInt16(blockAlign)))
        d.append(uint16(UInt16(bitsPerSample)))
        d.append(contentsOf: Array("data".utf8))
        d.append(uint32(UInt32(dataByteCount)))
        return d
    }

    private static func uint32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private static func uint16(_ v: UInt16) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
