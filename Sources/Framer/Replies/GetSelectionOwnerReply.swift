// GetSelectionOwner reply layout (X11 spec section 9.4):
//
//   1 byte:   marker (1)
//   1 byte:   unused
//   2 bytes:  sequence number
//   4 bytes:  additional length = 0
//   4 bytes:  owner window (None = 0 if no owner)
//  20 bytes:  unused

public struct GetSelectionOwnerReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var owner: UInt32                 // 0 = None

    public init(sequenceNumber: UInt16, owner: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.owner = owner
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(owner)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetSelectionOwnerReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let owner = try r.readUInt32()
        return GetSelectionOwnerReply(sequenceNumber: seq, owner: owner)
    }
}
