import Foundation

public struct CaptureFrame: Equatable, Sendable {
    public var direction: Direction
    public var timestamp: UInt64
    public var bytes: [UInt8]

    public init(direction: Direction, timestamp: UInt64, bytes: [UInt8]) {
        self.direction = direction
        self.timestamp = timestamp
        self.bytes = bytes
    }
}

public enum CaptureReadError: Error, Sendable, Equatable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case invalidDirection(UInt8)
}

public enum CaptureReader {
    public static func read(from path: String) throws -> [CaptureFrame] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(Array(data))
    }

    public static func parse(_ bytes: [UInt8]) throws -> [CaptureFrame] {
        guard bytes.count >= CaptureFile.headerSize else { throw CaptureReadError.truncated }
        guard Array(bytes.prefix(4)) == CaptureFile.magic else { throw CaptureReadError.badMagic }
        let version = bytes[4]
        guard version == CaptureFile.version else { throw CaptureReadError.unsupportedVersion(version) }

        var frames: [CaptureFrame] = []
        var offset = CaptureFile.headerSize
        while offset < bytes.count {
            guard offset + CaptureFile.frameHeaderSize <= bytes.count else {
                throw CaptureReadError.truncated
            }
            let dirRaw = bytes[offset]
            guard let direction = Direction(rawValue: dirRaw) else {
                throw CaptureReadError.invalidDirection(dirRaw)
            }
            let ts = readLE64(bytes, offset + 1)
            let len = Int(readLE32(bytes, offset + 9))
            let payloadStart = offset + CaptureFile.frameHeaderSize
            let payloadEnd = payloadStart + len
            guard payloadEnd <= bytes.count else { throw CaptureReadError.truncated }
            let payload = Array(bytes[payloadStart..<payloadEnd])
            frames.append(CaptureFrame(direction: direction, timestamp: ts, bytes: payload))
            offset = payloadEnd
        }
        return frames
    }
}

private func readLE64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[off + i]) << (i * 8) }
    return v
}

private func readLE32(_ b: [UInt8], _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(b[off + i]) << (i * 8) }
    return v
}
