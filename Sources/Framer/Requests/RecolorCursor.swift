public struct RecolorCursor: Equatable, Sendable {
    public static let opcode: UInt8 = 96

    public var cursor: UInt32
    public var foreRed: UInt16
    public var foreGreen: UInt16
    public var foreBlue: UInt16
    public var backRed: UInt16
    public var backGreen: UInt16
    public var backBlue: UInt16

    public init(
        cursor: UInt32,
        foreRed: UInt16, foreGreen: UInt16, foreBlue: UInt16,
        backRed: UInt16, backGreen: UInt16, backBlue: UInt16
    ) {
        self.cursor = cursor
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
        w.writeUInt16(5)
        w.writeUInt32(cursor)
        w.writeUInt16(foreRed); w.writeUInt16(foreGreen); w.writeUInt16(foreBlue)
        w.writeUInt16(backRed); w.writeUInt16(backGreen); w.writeUInt16(backBlue)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RecolorCursor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cursor = try r.readUInt32()
        let fr = try r.readUInt16(); let fg = try r.readUInt16(); let fb = try r.readUInt16()
        let br = try r.readUInt16(); let bg = try r.readUInt16(); let bb = try r.readUInt16()
        return RecolorCursor(
            cursor: cursor,
            foreRed: fr, foreGreen: fg, foreBlue: fb,
            backRed: br, backGreen: bg, backBlue: bb
        )
    }
}
