public struct ImageText8: Equatable, Sendable {
    public static let opcode: UInt8 = 76

    public var drawable: UInt32
    public var gc: UInt32
    public var x: Int16
    public var y: Int16
    public var string: [UInt8]

    public init(drawable: UInt32, gc: UInt32, x: Int16, y: Int16, string: [UInt8]) {
        precondition(string.count <= 255, "ImageText8 string exceeds CARD8 max")
        self.drawable = drawable
        self.gc = gc
        self.x = x
        self.y = y
        self.string = string
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = string.count
        let p = xPad(n)
        let lenIn4 = UInt16(4 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(UInt8(n))
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeBytes(string)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ImageText8 {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        let n = Int(try r.readUInt8())
        _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let string = try r.readBytes(n)
        try r.skip(xPad(n))
        return ImageText8(drawable: drawable, gc: gc, x: x, y: y, string: string)
    }
}
