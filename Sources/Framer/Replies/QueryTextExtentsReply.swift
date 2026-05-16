// QueryTextExtents reply (X11 spec / xQueryTextExtentsReply, sz=32):
//
//   1 byte:   marker (1)
//   1 byte:   drawDirection (0 LeftToRight, 1 RightToLeft)
//   2 bytes:  sequence number
//   4 bytes:  additional length in 4-byte units (= 0)
//   2 bytes:  fontAscent  (INT16)
//   2 bytes:  fontDescent (INT16)
//   2 bytes:  overallAscent  (INT16) — max ink ascent across the string
//   2 bytes:  overallDescent (INT16) — max ink descent
//   4 bytes:  overallWidth  (INT32) — sum of glyph advances
//   4 bytes:  overallLeft   (INT32) — left bearing of first glyph
//   4 bytes:  overallRight  (INT32) — overallWidth + right bearing of last glyph
//   4 bytes:  unused

public struct QueryTextExtentsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var drawDirection: UInt8           // 0=LeftToRight, 1=RightToLeft
    public var fontAscent: Int16
    public var fontDescent: Int16
    public var overallAscent: Int16
    public var overallDescent: Int16
    public var overallWidth: Int32
    public var overallLeft: Int32
    public var overallRight: Int32

    public init(
        sequenceNumber: UInt16,
        drawDirection: UInt8 = 0,
        fontAscent: Int16, fontDescent: Int16,
        overallAscent: Int16, overallDescent: Int16,
        overallWidth: Int32, overallLeft: Int32, overallRight: Int32
    ) {
        self.sequenceNumber = sequenceNumber
        self.drawDirection = drawDirection
        self.fontAscent = fontAscent
        self.fontDescent = fontDescent
        self.overallAscent = overallAscent
        self.overallDescent = overallDescent
        self.overallWidth = overallWidth
        self.overallLeft = overallLeft
        self.overallRight = overallRight
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(drawDirection)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(UInt16(bitPattern: fontAscent))
        w.writeUInt16(UInt16(bitPattern: fontDescent))
        w.writeUInt16(UInt16(bitPattern: overallAscent))
        w.writeUInt16(UInt16(bitPattern: overallDescent))
        w.writeUInt32(UInt32(bitPattern: overallWidth))
        w.writeUInt32(UInt32(bitPattern: overallLeft))
        w.writeUInt32(UInt32(bitPattern: overallRight))
        w.writePadding(4)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryTextExtentsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let dir = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let fa = Int16(bitPattern: try r.readUInt16())
        let fd = Int16(bitPattern: try r.readUInt16())
        let oa = Int16(bitPattern: try r.readUInt16())
        let od = Int16(bitPattern: try r.readUInt16())
        let ow = Int32(bitPattern: try r.readUInt32())
        let ol = Int32(bitPattern: try r.readUInt32())
        let or = Int32(bitPattern: try r.readUInt32())
        return QueryTextExtentsReply(
            sequenceNumber: seq, drawDirection: dir,
            fontAscent: fa, fontDescent: fd,
            overallAscent: oa, overallDescent: od,
            overallWidth: ow, overallLeft: ol, overallRight: or
        )
    }
}
