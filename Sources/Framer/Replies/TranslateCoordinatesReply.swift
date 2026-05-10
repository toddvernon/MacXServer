// TranslateCoordinates reply layout (X11 spec section 12; Xproto.h
// xTranslateCoordsReply):
//
//   1 byte:  marker (1)
//   1 byte:  same-screen (BOOL)
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= 0)
//   4 bytes: child (None = 0, or window id of the child of dst-window
//            that contains the destination point)
//   2 bytes: dst-x (signed, in dst-window's coordinate system)
//   2 bytes: dst-y (signed)
//  16 bytes: unused

public struct TranslateCoordinatesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var sameScreen: Bool
    public var child: UInt32
    public var dstX: Int16
    public var dstY: Int16

    public init(
        sequenceNumber: UInt16, sameScreen: Bool,
        child: UInt32, dstX: Int16, dstY: Int16
    ) {
        self.sequenceNumber = sequenceNumber
        self.sameScreen = sameScreen
        self.child = child
        self.dstX = dstX
        self.dstY = dstY
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(sameScreen ? 1 : 0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(child)
        w.writeUInt16(UInt16(bitPattern: dstX))
        w.writeUInt16(UInt16(bitPattern: dstY))
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> TranslateCoordinatesReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let sameScreen = (try r.readUInt8()) != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let child = try r.readUInt32()
        let dx = Int16(bitPattern: try r.readUInt16())
        let dy = Int16(bitPattern: try r.readUInt16())
        return TranslateCoordinatesReply(
            sequenceNumber: seq, sameScreen: sameScreen,
            child: child, dstX: dx, dstY: dy
        )
    }
}
