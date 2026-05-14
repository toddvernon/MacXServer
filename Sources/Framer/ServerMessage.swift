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

// The 17 core X11 error codes per the X11R6 protocol spec § "Errors". Extension
// errors get higher numbers via the extension's firstError. We only emit core
// errors today.
public enum XErrorCode: UInt8, Sendable, Equatable {
    case request        = 1   // BadRequest: major/minor opcode does not specify a valid request
    case value          = 2   // BadValue: an out-of-range numeric value
    case window         = 3   // BadWindow: window argument is not a valid window
    case pixmap         = 4   // BadPixmap: pixmap argument is not a valid pixmap
    case atom           = 5   // BadAtom: atom argument is not a valid atom
    case cursor         = 6   // BadCursor: cursor argument is not a valid cursor
    case font           = 7   // BadFont: font argument is not a valid font
    case match          = 8   // BadMatch: arguments are inappropriate (e.g. depth mismatch)
    case drawable       = 9   // BadDrawable: drawable argument is not a valid window or pixmap
    case access         = 10  // BadAccess: attempt at an access not permitted
    case alloc          = 11  // BadAlloc: server failed to allocate the requested resource
    case color          = 12  // BadColor: colormap argument is not a valid colormap
    case gc             = 13  // BadGC: GC argument is not a valid GC
    case idChoice       = 14  // BadIDChoice: client-allocated ID is already in use or not in this client's range
    case name           = 15  // BadName: font or color name not in the database
    case length         = 16  // BadLength: request length does not match
    case implementation = 17  // BadImplementation: server does not implement the operation
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

    /// Wire-format encoder for server-side error emission. Always 32 bytes.
    /// Layout per X11 spec: byte 0 = 0 (error marker), byte 1 = errorCode,
    /// bytes 2..3 = seq, bytes 4..7 = badResourceId (semantics vary by code:
    /// the bad ID for BadWindow/Pixmap/Atom/Cursor/Font/Drawable/Color/GC/
    /// IDChoice, the offending value for BadValue, 0 otherwise), bytes 8..9 =
    /// minor opcode (0 for core requests), byte 10 = major opcode of the
    /// failing request, bytes 11..31 = unused.
    public static func encode(
        code: XErrorCode,
        sequenceNumber: UInt16,
        badResourceId: UInt32 = 0,
        minorOpcode: UInt16 = 0,
        majorOpcode: UInt8,
        byteOrder: ByteOrder
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 32)
        b[0] = 0
        b[1] = code.rawValue
        writeUInt16(into: &b, offset: 2, value: sequenceNumber, byteOrder: byteOrder)
        writeUInt32(into: &b, offset: 4, value: badResourceId, byteOrder: byteOrder)
        writeUInt16(into: &b, offset: 8, value: minorOpcode, byteOrder: byteOrder)
        b[10] = majorOpcode
        return b
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

private func writeUInt16(into b: inout [UInt8], offset: Int, value: UInt16, byteOrder: ByteOrder) {
    switch byteOrder {
    case .lsbFirst:
        b[offset]     = UInt8(value & 0xFF)
        b[offset + 1] = UInt8((value >> 8) & 0xFF)
    case .msbFirst:
        b[offset]     = UInt8((value >> 8) & 0xFF)
        b[offset + 1] = UInt8(value & 0xFF)
    }
}

private func writeUInt32(into b: inout [UInt8], offset: Int, value: UInt32, byteOrder: ByteOrder) {
    switch byteOrder {
    case .lsbFirst:
        b[offset]     = UInt8(value & 0xFF)
        b[offset + 1] = UInt8((value >> 8) & 0xFF)
        b[offset + 2] = UInt8((value >> 16) & 0xFF)
        b[offset + 3] = UInt8((value >> 24) & 0xFF)
    case .msbFirst:
        b[offset]     = UInt8((value >> 24) & 0xFF)
        b[offset + 1] = UInt8((value >> 16) & 0xFF)
        b[offset + 2] = UInt8((value >> 8) & 0xFF)
        b[offset + 3] = UInt8(value & 0xFF)
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
