public enum AllowEventsMode: UInt8, Sendable {
    case asyncPointer = 0
    case syncPointer = 1
    case replayPointer = 2
    case asyncKeyboard = 3
    case syncKeyboard = 4
    case replayKeyboard = 5
    case asyncBoth = 6
    case syncBoth = 7
}

public struct AllowEvents: Equatable, Sendable {
    public static let opcode: UInt8 = 35

    public var mode: AllowEventsMode
    public var time: UInt32              // 0 = CurrentTime

    public init(mode: AllowEventsMode, time: UInt32 = 0) {
        self.mode = mode
        self.time = time
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(mode.rawValue)
        w.writeUInt16(2)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllowEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = AllowEventsMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "AllowEventsMode", value: UInt32(modeRaw))
        }
        _ = try r.readUInt16()
        let time = try r.readUInt32()
        return AllowEvents(mode: mode, time: time)
    }
}
