public enum RevertTo: UInt8, Sendable {
    case none = 0
    case pointerRoot = 1
    case parent = 2
}

public struct SetInputFocus: Equatable, Sendable {
    public static let opcode: UInt8 = 42

    public var revertTo: RevertTo
    public var focus: UInt32             // 0 = None, 1 = PointerRoot
    public var time: UInt32              // 0 = CurrentTime

    public init(revertTo: RevertTo, focus: UInt32, time: UInt32 = 0) {
        self.revertTo = revertTo
        self.focus = focus
        self.time = time
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(revertTo.rawValue)
        w.writeUInt16(3)
        w.writeUInt32(focus)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetInputFocus {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let revRaw = try r.readUInt8()
        guard let rev = RevertTo(rawValue: revRaw) else {
            throw FramerError.invalidEnum(name: "RevertTo", value: UInt32(revRaw))
        }
        _ = try r.readUInt16()
        let focus = try r.readUInt32()
        let time = try r.readUInt32()
        return SetInputFocus(revertTo: rev, focus: focus, time: time)
    }
}
