public enum SetupReply: Equatable, Sendable {
    case refused(SetupRefused)
    case accepted(SetupAccepted)
    case authenticate(SetupAuthenticate)

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        switch self {
        case .refused(let r):       return r.encode(byteOrder: byteOrder)
        case .accepted(let a):      return a.encode(byteOrder: byteOrder)
        case .authenticate(let a):  return a.encode(byteOrder: byteOrder)
        }
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetupReply {
        guard let status = bytes.first else {
            throw FramerError.truncated(needed: 1, available: 0)
        }
        switch status {
        case 0: return .refused(try SetupRefused.decode(from: bytes, byteOrder: byteOrder))
        case 1: return .accepted(try SetupAccepted.decode(from: bytes, byteOrder: byteOrder))
        case 2: return .authenticate(try SetupAuthenticate.decode(from: bytes, byteOrder: byteOrder))
        default: throw FramerError.invalidStatus(status)
        }
    }
}

public struct SetupRefused: Equatable, Sendable {
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var reason: [UInt8]

    public init(protocolMajor: UInt16, protocolMinor: UInt16, reason: [UInt8]) {
        precondition(reason.count <= 255, "refused reason exceeds CARD8 max")
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.reason = reason
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        let n = reason.count
        let p = xPad(n)
        w.writeUInt8(0)
        w.writeUInt8(UInt8(n))
        w.writeUInt16(protocolMajor)
        w.writeUInt16(protocolMinor)
        w.writeUInt16(UInt16((n + p) / 4))
        w.writeBytes(reason)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetupRefused {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let n = Int(try r.readUInt8())
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        _ = try r.readUInt16()
        let reason = try r.readBytes(n)
        try r.skip(xPad(n))
        return SetupRefused(protocolMajor: major, protocolMinor: minor, reason: reason)
    }
}

// The X11 spec gives only (n+p)/4 for the additional-data length, with no separate
// length-of-reason field. There is no way to recover n exactly from the wire, so
// decode returns the full additional-data area (reason + padding). Round-trip is
// byte-identical because the trailing zeros become part of the reason on the second
// encode and get re-emitted in the same positions.
public struct SetupAuthenticate: Equatable, Sendable {
    public var reason: [UInt8]

    public init(reason: [UInt8]) {
        self.reason = reason
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        let n = reason.count
        let p = xPad(n)
        w.writeUInt8(2)
        w.writePadding(5)
        w.writeUInt16(UInt16((n + p) / 4))
        w.writeBytes(reason)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetupAuthenticate {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        try r.skip(5)
        let lenIn4 = Int(try r.readUInt16())
        let reason = try r.readBytes(lenIn4 * 4)
        return SetupAuthenticate(reason: reason)
    }
}
