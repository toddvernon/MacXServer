public struct AllocColor: Equatable, Sendable {
    public static let opcode: UInt8 = 84

    public var cmap: UInt32
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(cmap: UInt32, red: UInt16, green: UInt16, blue: UInt16) {
        self.cmap = cmap
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)
        w.writeUInt32(cmap)
        w.writeUInt16(red)
        w.writeUInt16(green)
        w.writeUInt16(blue)
        w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocColor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let red = try r.readUInt16()
        let green = try r.readUInt16()
        let blue = try r.readUInt16()
        _ = try r.readUInt16()
        return AllocColor(cmap: cmap, red: red, green: green, blue: blue)
    }
}
