public struct GetKeyboardMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 101

    public var firstKeycode: UInt8
    public var count: UInt8

    public init(firstKeycode: UInt8, count: UInt8) {
        self.firstKeycode = firstKeycode
        self.count = count
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(2)
        w.writeUInt8(firstKeycode)
        w.writeUInt8(count)
        w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetKeyboardMapping {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let first = try r.readUInt8()
        let count = try r.readUInt8()
        _ = try r.readUInt16()
        return GetKeyboardMapping(firstKeycode: first, count: count)
    }
}
