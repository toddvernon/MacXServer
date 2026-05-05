import Foundation

public enum RecorderError: Error, Sendable, Equatable {
    case cannotOpenFile(String)
    case writeFailed
}

public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outputHandle: FileHandle
    private let outputPath: String
    private let listenDescription: String
    private let forwardDescription: String
    private let toolVersion: String
    private var startTime: UInt64?
    private var lastTime: UInt64?
    private var totalBytesC2S: Int = 0
    private var totalBytesS2C: Int = 0

    public init(
        outputPath: String,
        listen: String,
        forward: String,
        toolVersion: String = "0.1.0"
    ) throws {
        let parent = (outputPath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            throw RecorderError.cannotOpenFile(outputPath)
        }
        self.outputHandle = handle
        self.outputPath = outputPath
        self.listenDescription = listen
        self.forwardDescription = forward
        self.toolVersion = toolVersion

        var header: [UInt8] = []
        header.append(contentsOf: CaptureFile.magic)
        header.append(CaptureFile.version)
        header.append(0)
        header.append(0)
        header.append(0)
        try outputHandle.write(contentsOf: header)
    }

    public func record(direction: Direction, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        if startTime == nil { startTime = now }
        lastTime = now
        let timestamp = now - (startTime ?? now)

        var frame: [UInt8] = []
        frame.reserveCapacity(CaptureFile.frameHeaderSize + bytes.count)
        frame.append(direction.rawValue)
        appendLE(&frame, timestamp)
        appendLE(&frame, UInt32(bytes.count))
        frame.append(contentsOf: bytes)

        do {
            try outputHandle.write(contentsOf: frame)
        } catch {
            // Recording failures are logged but don't stop the proxy. The pump's
            // job is faithful forwarding; recording is observation.
            FileHandle.standardError.write(Data("recorder write failed: \(error)\n".utf8))
        }

        switch direction {
        case .clientToServer: totalBytesC2S += bytes.count
        case .serverToClient: totalBytesS2C += bytes.count
        }
    }

    public func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        try outputHandle.close()

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
