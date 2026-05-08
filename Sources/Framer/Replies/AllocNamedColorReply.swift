// AllocNamedColor reply layout (X11 spec section 9; Xproto.h xAllocNamedColorReply):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= 0)
//   4 bytes: pixel
//   2 bytes: exact-red
//   2 bytes: exact-green
//   2 bytes: exact-blue
//   2 bytes: visual-red   (what hardware will actually display, may differ on PseudoColor)
//   2 bytes: visual-green
//   2 bytes: visual-blue
//   8 bytes: unused

public struct AllocNamedColorReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var pixel: UInt32
    public var exactRed: UInt16
    public var exactGreen: UInt16
    public var exactBlue: UInt16
    public var visualRed: UInt16
    public var visualGreen: UInt16
    public var visualBlue: UInt16

    public init(sequenceNumber: UInt16, pixel: UInt32,
                exactRed: UInt16, exactGreen: UInt16, exactBlue: UInt16,
                visualRed: UInt16, visualGreen: UInt16, visualBlue: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.pixel = pixel
        self.exactRed = exactRed
        self.exactGreen = exactGreen
        self.exactBlue = exactBlue
        self.visualRed = visualRed
        self.visualGreen = visualGreen
        self.visualBlue = visualBlue
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(pixel)
        w.writeUInt16(exactRed)
        w.writeUInt16(exactGreen)
        w.writeUInt16(exactBlue)
        w.writeUInt16(visualRed)
        w.writeUInt16(visualGreen)
        w.writeUInt16(visualBlue)
        w.writePadding(8)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocNamedColorReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let pixel = try r.readUInt32()
        let er = try r.readUInt16()
        let eg = try r.readUInt16()
        let eb = try r.readUInt16()
        let vr = try r.readUInt16()
        let vg = try r.readUInt16()
        let vb = try r.readUInt16()
        return AllocNamedColorReply(
            sequenceNumber: seq, pixel: pixel,
            exactRed: er, exactGreen: eg, exactBlue: eb,
            visualRed: vr, visualGreen: vg, visualBlue: vb
        )
    }
}
