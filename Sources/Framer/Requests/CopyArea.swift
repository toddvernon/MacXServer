public struct CopyArea: Equatable, Sendable {
    public static let opcode: UInt8 = 62

    public var srcDrawable: UInt32
    public var dstDrawable: UInt32
    public var gc: UInt32
    public var srcX: Int16
    public var srcY: Int16
    public var dstX: Int16
    public var dstY: Int16
    public var width: UInt16
    public var height: UInt16

    public init(
        srcDrawable: UInt32, dstDrawable: UInt32, gc: UInt32,
        srcX: Int16, srcY: Int16, dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16
    ) {
        self.srcDrawable = srcDrawable
        self.dstDrawable = dstDrawable
        self.gc = gc
        self.srcX = srcX
        self.srcY = srcY
        self.dstX = dstX
        self.dstY = dstY
        self.width = width
        self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(7)
        w.writeUInt32(srcDrawable)
        w.writeUInt32(dstDrawable)
        w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: srcX))
        w.writeUInt16(UInt16(bitPattern: srcY))
        w.writeUInt16(UInt16(bitPattern: dstX))
        w.writeUInt16(UInt16(bitPattern: dstY))
        w.writeUInt16(width)
        w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CopyArea {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let src = try r.readUInt32()
        let dst = try r.readUInt32()
        let gc = try r.readUInt32()
        let sx = Int16(bitPattern: try r.readUInt16())
        let sy = Int16(bitPattern: try r.readUInt16())
        let dx = Int16(bitPattern: try r.readUInt16())
        let dy = Int16(bitPattern: try r.readUInt16())
        let w = try r.readUInt16()
        let h = try r.readUInt16()
        return CopyArea(srcDrawable: src, dstDrawable: dst, gc: gc, srcX: sx, srcY: sy, dstX: dx, dstY: dy, width: w, height: h)
    }
}
