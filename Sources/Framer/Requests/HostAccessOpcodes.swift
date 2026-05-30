// Host access control. Three opcodes that govern which network hosts
// the server accepts connections from.

public enum HostAccessMode: UInt8, Sendable {
    case insert = 0  // ChangeHosts: add to list; SetAccessControl: disable
    case delete = 1  // ChangeHosts: remove from list; SetAccessControl: enable
}

public enum HostFamily: UInt8, Sendable {
    case internet = 0
    case decnet = 1
    case chaos = 2
    case serverInterpreted = 5
    case internetV6 = 6
}

// MARK: - ChangeHosts (opcode 109)

/// xChangeHostsReq: opcode(1) + mode(1) + length(2) +
/// hostFamily(1) + pad(1) + hostLength(2). Then n address bytes + pad-to-4.
public struct ChangeHosts: Equatable, Sendable {
    public static let opcode: UInt8 = 109

    public var mode: HostAccessMode
    public var family: HostFamily
    /// Variable-length address bytes. Format depends on `family` (4 bytes
    /// for IPv4, 16 for IPv6, etc.).
    public var address: [UInt8]

    public init(mode: HostAccessMode, family: HostFamily, address: [UInt8]) {
        self.mode = mode
        self.family = family
        self.address = address
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = address.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(mode.rawValue); w.writeUInt16(lenIn4)
        w.writeUInt8(family.rawValue); w.writePadding(1); w.writeUInt16(UInt16(n))
        w.writeBytes(address)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeHosts {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = HostAccessMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "HostAccessMode", value: UInt32(modeRaw))
        }
        _ = try r.readUInt16()
        let famRaw = try r.readUInt8()
        guard let family = HostFamily(rawValue: famRaw) else {
            throw FramerError.invalidEnum(name: "HostFamily", value: UInt32(famRaw))
        }
        try r.skip(1)
        let n = Int(try r.readUInt16())
        let address = try r.readBytes(n)
        return ChangeHosts(mode: mode, family: family, address: address)
    }
}

// MARK: - ListHosts (opcode 110)

public struct ListHosts: Equatable, Sendable {
    public static let opcode: UInt8 = 110
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListHosts {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return ListHosts()
    }
}

// MARK: - SetAccessControl (opcode 111)

/// xChangeModeReq: opcode(1) + mode(1) + length(2=1). Mode is one byte:
/// 0 = Disable (allow all hosts), 1 = Enable (only listed hosts).
/// Note this is the opposite polarity of HostAccessMode — Disable/Enable
/// vs. Insert/Delete — but the underlying CARD8 mode byte is the same
/// type, so we reuse a thin local enum.
public struct SetAccessControl: Equatable, Sendable {
    public static let opcode: UInt8 = 111

    public enum Mode: UInt8, Sendable {
        case disable = 0
        case enable = 1
    }

    public var mode: Mode

    public init(mode: Mode) { self.mode = mode }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(mode.rawValue); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetAccessControl {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = Mode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "SetAccessControl.Mode", value: UInt32(modeRaw))
        }
        _ = try r.readUInt16()
        return SetAccessControl(mode: mode)
    }
}
