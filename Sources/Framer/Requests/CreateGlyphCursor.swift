public struct CreateGlyphCursor: Equatable, Sendable {
    public static let opcode: UInt8 = 94

    public var cid: UInt32
    public var sourceFont: UInt32
    public var maskFont: UInt32           // 0 = None
    public var sourceChar: UInt16
    public var maskChar: UInt16
    public var foreRed: UInt16
    public var foreGreen: UInt16
    public var foreBlue: UInt16
    public var backRed: UInt16
    public var backGreen: UInt16
    public var backBlue: UInt16

    public init(
        cid: UInt32, sourceFont: UInt32, maskFont: UInt32 = 0,
        sourceChar: UInt16, maskChar: UInt16,
        foreRed: UInt16, foreGreen: UInt16, foreBlue: UInt16,
        backRed: UInt16, backGreen: UInt16, backBlue: UInt16
    ) {
        self.cid = cid
        self.sourceFont = sourceFont
        self.maskFont = maskFont
        self.sourceChar = sourceChar
        self.maskChar = maskChar
        self.foreRed = foreRed
        self.foreGreen = foreGreen
        self.foreBlue = foreBlue
        self.backRed = backRed
        self.backGreen = backGreen
        self.backBlue = backBlue
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(8)
        w.writeUInt32(cid)
        w.writeUInt32(sourceFont)
        w.writeUInt32(maskFont)
        w.writeUInt16(sourceChar)
        w.writeUInt16(maskChar)
        w.writeUInt16(foreRed); w.writeUInt16(foreGreen); w.writeUInt16(foreBlue)
        w.writeUInt16(backRed); w.writeUInt16(backGreen); w.writeUInt16(backBlue)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreateGlyphCursor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cid = try r.readUInt32()
        let src = try r.readUInt32()
        let mask = try r.readUInt32()
        let sc = try r.readUInt16()
        let mc = try r.readUInt16()
        let fr = try r.readUInt16(); let fg = try r.readUInt16(); let fb = try r.readUInt16()
        let br = try r.readUInt16(); let bg = try r.readUInt16(); let bb = try r.readUInt16()
        return CreateGlyphCursor(
            cid: cid, sourceFont: src, maskFont: mask,
            sourceChar: sc, maskChar: mc,
            foreRed: fr, foreGreen: fg, foreBlue: fb,
            backRed: br, backGreen: bg, backBlue: bb
        )
    }
}
