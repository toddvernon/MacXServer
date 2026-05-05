public struct PolyFillRectangle: Equatable, Sendable {
    public static let opcode: UInt8 = 70

    public var drawable: UInt32
    public var gc: UInt32
    public var rectangles: [Rectangle]

    public init(drawable: UInt32, gc: UInt32, rectangles: [Rectangle]) {
        self.drawable = drawable
        self.gc = gc
        self.rectangles = rectangles
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 2 * rectangles.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        for rect in rectangles { rect.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyFillRectangle {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let nRects = (lenIn4 - 3) / 2
        var rects: [Rectangle] = []
        rects.reserveCapacity(nRects)
        for _ in 0..<nRects {
            rects.append(try Rectangle.decode(from: &r))
        }
        return PolyFillRectangle(drawable: drawable, gc: gc, rectangles: rects)
    }
}
