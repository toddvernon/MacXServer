// Server-to-client traffic dispatch.
//
// The X protocol multiplexes three message kinds on the s2c stream:
//   - Errors (32 bytes, marker byte = 0)
//   - Replies (32 bytes + lengthIn4 * 4 additional, marker byte = 1)
//   - Events (32 bytes, marker byte >= 2; high bit set = synthesized via SendEvent)
//
// All three are wire-aligned and the boundary scanner can find the next message
// without knowing the meaning of the body — replies carry an explicit length
// field, events and errors are always 32 bytes.

public enum ServerMessage: Equatable, Sendable {
    case reply(Reply)
    case event(Event)
    case xError(XError)

    public var bytes: [UInt8] {
        switch self {
        case .reply(let r):    return r.bytes
        case .event(let e):    return e.bytes
        case .xError(let err): return err.bytes
        }
    }

    public static func decodeOne(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ServerMessage {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        switch bytes[0] {
        case 0:
            return .xError(XError(bytes: Array(bytes[0..<32])))
        case 1:
            var r = ByteReader(bytes: bytes, byteOrder: byteOrder, offset: 4)
            let lenIn4 = try r.readUInt32()
            let totalSize = 32 + Int(lenIn4) * 4
            guard bytes.count >= totalSize else {
                throw FramerError.truncated(needed: totalSize, available: bytes.count)
            }
            return .reply(Reply(bytes: Array(bytes[0..<totalSize])))
        default:
            return .event(Event(bytes: Array(bytes[0..<32])))
        }
    }
}

public struct Reply: Equatable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count >= 32, "Reply must be at least 32 bytes")
        self.bytes = bytes
    }

    public var dataByte: UInt8 { bytes[1] }

    public func sequenceNumber(byteOrder: ByteOrder) -> UInt16 {
        readUInt16(bytes, offset: 2, byteOrder: byteOrder)
    }

    public func additionalLengthIn4(byteOrder: ByteOrder) -> UInt32 {
        readUInt32(bytes, offset: 4, byteOrder: byteOrder)
    }
}

public struct Event: Equatable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "Event must be 32 bytes")
        self.bytes = bytes
    }

    public var code: UInt8 { bytes[0] & 0x7F }
    public var sentEvent: Bool { (bytes[0] & 0x80) != 0 }
    public var detail: UInt8 { bytes[1] }

    public func sequenceNumber(byteOrder: ByteOrder) -> UInt16 {
        readUInt16(bytes, offset: 2, byteOrder: byteOrder)
    }
}

public struct XError: Equatable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "XError must be 32 bytes")
        self.bytes = bytes
    }

    public var errorCode: UInt8 { bytes[1] }
    public var majorOpcode: UInt8 { bytes[10] }

    public func sequenceNumber(byteOrder: ByteOrder) -> UInt16 {
        readUInt16(bytes, offset: 2, byteOrder: byteOrder)
    }

    public func badResourceId(byteOrder: ByteOrder) -> UInt32 {
        readUInt32(bytes, offset: 4, byteOrder: byteOrder)
    }

    public func minorOpcode(byteOrder: ByteOrder) -> UInt16 {
        readUInt16(bytes, offset: 8, byteOrder: byteOrder)
    }
}

private func readUInt16(_ b: [UInt8], offset: Int, byteOrder: ByteOrder) -> UInt16 {
    let a = UInt16(b[offset])
    let c = UInt16(b[offset + 1])
    switch byteOrder {
    case .lsbFirst: return (c << 8) | a
    case .msbFirst: return (a << 8) | c
    }
}

private func readUInt32(_ b: [UInt8], offset: Int, byteOrder: ByteOrder) -> UInt32 {
    let a = UInt32(b[offset])
    let c = UInt32(b[offset + 1])
    let d = UInt32(b[offset + 2])
    let e = UInt32(b[offset + 3])
    switch byteOrder {
    case .lsbFirst: return (e << 24) | (d << 16) | (c << 8) | a
    case .msbFirst: return (a << 24) | (c << 16) | (d << 8) | e
    }
}
