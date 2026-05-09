// QueryBestSize reply (X11 spec section 6).
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: additional length = 0
//   2 bytes: width
//   2 bytes: height
//  20 bytes: unused

public struct QueryBestSizeReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var width: UInt16
    public var height: UInt16

    public init(sequenceNumber: UInt16, width: UInt16, height: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.width = width
        self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(width)
        w.writeUInt16(height)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryBestSizeReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return QueryBestSizeReply(sequenceNumber: seq, width: width, height: height)
    }
}
