import Foundation

public enum RecorderError: Error, Sendable, Equatable {
    case cannotOpenFile(String)
    case writeFailed
}

public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outputPath: String
    private let listenDescription: String
    private let forwardDescription: String
    private let toolVersion: String
    private var startTime: UInt64?
    private var lastTime: UInt64?
    private var totalBytesC2S: Int = 0
    private var totalBytesS2C: Int = 0

    /// In-memory frame buffer. record() appends here under the lock; the
    /// disk write happens once at finalize(). Pre-2026-05-09 the disk
    /// write happened on every record() call WHILE HOLDING THE LOCK,
    /// which serialized the proxy's two pump directions on file I/O —
    /// SS2's old TCP stack reacted to the resulting jitter by
    /// retransmitting reply bytes, libxlib processed them duplicated,
    /// and Motif segfaulted. Buffering keeps the wire path off-disk.
    private var buffer: [UInt8] = []

    public init(
        outputPath: String,
        listen: String,
        forward: String,
        toolVersion: String = "0.1.0"
    ) throws {
        // Make sure the output directory exists; we don't open the file yet.
        let parent = (outputPath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
        }
        self.outputPath = outputPath
        self.listenDescription = listen
        self.forwardDescription = forward
        self.toolVersion = toolVersion

        // Reserve a generous initial capacity so typical sessions don't
        // re-allocate the backing array. xterm sessions in our corpus
        // run ~200KB; quickplot init alone is ~30KB.
        buffer.reserveCapacity(512 * 1024)

        // File header lives at the start of the buffer.
        buffer.append(contentsOf: CaptureFile.magic)
        buffer.append(CaptureFile.version)
        buffer.append(0)
        buffer.append(0)
        buffer.append(0)
    }

    public func record(direction: Direction, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        if startTime == nil { startTime = now }
        lastTime = now
        let timestamp = now - (startTime ?? now)

        // Append frame header + bytes directly to the in-memory buffer.
        // This is a few memcpys — orders of magnitude faster than file I/O,
        // and crucially doesn't block the proxy's pump on disk.
        buffer.append(direction.rawValue)
        appendLE(&buffer, timestamp)
        appendLE(&buffer, UInt32(bytes.count))
        buffer.append(contentsOf: bytes)

        switch direction {
        case .clientToServer: totalBytesC2S += bytes.count
        case .serverToClient: totalBytesS2C += bytes.count
        }
    }

    public func finalize() throws {
        lock.lock()
        defer { lock.unlock() }

        // Single disk write at end of session. If the proxy crashed or
        // SIGKILL'd, the buffer is lost — acceptable trade-off for the
        // wire-path latency improvement. (Normal exit-on-disconnect always
        // reaches here.)
        FileManager.default.createFile(atPath: outputPath, contents: Data(buffer))

        let durationNs: UInt64 = {
            guard let start = startTime, let last = lastTime else { return 0 }
            return last - start
        }()

        let metadata = Metadata(
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            toolVersion: toolVersion,
            listen: listenDescription,
            forward: forwardDescription,
            durationNs: durationNs,
            totalBytesC2S: totalBytesC2S,
            totalBytesS2C: totalBytesS2C
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(metadata)
        let jsonPath = outputPath + ".json"
        try json.write(to: URL(fileURLWithPath: jsonPath))
    }
}

public struct Metadata: Codable, Equatable, Sendable {
    public let recordedAt: String
    public let toolVersion: String
    public let listen: String
    public let forward: String
    public let durationNs: UInt64
    public let totalBytesC2S: Int
    public let totalBytesS2C: Int

    enum CodingKeys: String, CodingKey {
        case recordedAt = "recorded_at"
        case toolVersion = "tool_version"
        case listen
        case forward
        case durationNs = "duration_ns"
        case totalBytesC2S = "total_bytes_c2s"
        case totalBytesS2C = "total_bytes_s2c"
    }
}

private func appendLE(_ buf: inout [UInt8], _ v: UInt64) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
}

private func appendLE(_ buf: inout [UInt8], _ v: UInt32) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
}
