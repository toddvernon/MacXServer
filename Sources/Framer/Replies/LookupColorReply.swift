// LookupColor reply layout (X11 spec section 9; Xproto.h xLookupColorReply):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= 0)
//   2 bytes: exact-red
//   2 bytes: exact-green
//   2 bytes: exact-blue
//   2 bytes: visual-red    (closest the screen can actually display)
//   2 bytes: visual-green
//   2 bytes: visual-blue
//  12 bytes: unused
//
// Same shape as AllocNamedColorReply minus the pixel field. Used by clients
// that want to know an X color name's RGB without claiming a colormap cell —
// xterm calls this for `-fg <name>` when it intends to use AllocColor on the
// resolved RGB rather than AllocNamedColor.

public struct LookupColorReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var exactRed: UInt16
    public var exactGreen: UInt16
    public var exactBlue: UInt16
    public var visualRed: UInt16
    public var visualGreen: UInt16
    public var visualBlue: UInt16

    public init(sequenceNumber: UInt16,
                exactRed: UInt16, exactGreen: UInt16, exactBlue: UInt16,
                visualRed: UInt16, visualGreen: UInt16, visualBlue: UInt16) {
        self.sequenceNumber = sequenceNumber
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
        w.writeUInt16(exactRed)
        w.writeUInt16(exactGreen)
        w.writeUInt16(exactBlue)
        w.writeUInt16(visualRed)
        w.writeUInt16(visualGreen)
        w.writeUInt16(visualBlue)
        w.writePadding(12)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> LookupColorReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let er = try r.readUInt16()
        let eg = try r.readUInt16()
        let eb = try r.readUInt16()
        let vr = try r.readUInt16()
        let vg = try r.readUInt16()
        let vb = try r.readUInt16()
        return LookupColorReply(
            sequenceNumber: seq,
            exactRed: er, exactGreen: eg, exactBlue: eb,
            visualRed: vr, visualGreen: vg, visualBlue: vb
        )
    }
}
