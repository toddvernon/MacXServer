public struct CreateCursor: Equatable, Sendable {
    public static let opcode: UInt8 = 93

    public var cid: UInt32
    public var source: UInt32           // PIXMAP (depth=1)
    public var mask: UInt32             // PIXMAP (depth=1) or 0 = None
    public var foreRed: UInt16
    public var foreGreen: UInt16
    public var foreBlue: UInt16
    public var backRed: UInt16
    public var backGreen: UInt16
    public var backBlue: UInt16
    public var x: UInt16                // hotspot
    public var y: UInt16

    public init(
        cid: UInt32, source: UInt32, mask: UInt32 = 0,
        foreRed: UInt16, foreGreen: UInt16, foreBlue: UInt16,
        backRed: UInt16, backGreen: UInt16, backBlue: UInt16,
        x: UInt16, y: UInt16
    ) {
        self.cid = cid
        self.source = source
        self.mask = mask
        self.foreRed = foreRed
        self.foreGreen = foreGreen
        self.foreBlue = foreBlue
        self.backRed = backRed
        self.backGreen = backGreen
        self.backBlue = backBlue
        self.x = x
        self.y = y
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(8)
        w.writeUInt32(cid)
        w.writeUInt32(source)
        w.writeUInt32(mask)
        w.writeUInt16(foreRed); w.writeUInt16(foreGreen); w.writeUInt16(foreBlue)
        w.writeUInt16(backRed); w.writeUInt16(backGreen); w.writeUInt16(backBlue)
        w.writeUInt16(x); w.writeUInt16(y)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreateCursor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cid = try r.readUInt32()
        let src = try r.readUInt32()
        let mask = try r.readUInt32()
        let fr = try r.readUInt16(); let fg = try r.readUInt16(); let fb = try r.readUInt16()
        let br = try r.readUInt16(); let bg = try r.readUInt16(); let bb = try r.readUInt16()
        let hx = try r.readUInt16(); let hy = try r.readUInt16()
        return CreateCursor(
            cid: cid, source: src, mask: mask,
            foreRed: fr, foreGreen: fg, foreBlue: fb,
            backRed: br, backGreen: bg, backBlue: bb,
            x: hx, y: hy
        )
    }
}
