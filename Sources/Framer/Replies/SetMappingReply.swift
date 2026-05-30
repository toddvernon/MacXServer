// Reply to SetPointerMapping (opcode 116) AND SetModifierMapping (opcode 118).
// Same wire format in both: xSetMappingReply with a status byte where
// the second header byte normally lives.
//
// SetPointerMapping status: 0=Success, 1=Busy
// SetModifierMapping status: 0=Success, 1=Busy, 2=Failed
//
// Per X11R6 Xproto.h: type(1=1) + status(1) + seq(2) + length(4=0) +
// 24 bytes pad. 32 bytes total.
public struct SetMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var status: UInt8

    public init(sequenceNumber: UInt16, status: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.status = status
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(status); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writePadding(24)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let status = try r.readUInt8()
        let seq = try r.readUInt16()
        return SetMappingReply(sequenceNumber: seq, status: status)
    }
}
