// GetPointerMapping reply layout (X11 spec section 9.5):
//
//   1 byte:   marker (1)
//   1 byte:   number of map entries (n)
//   2 bytes:  sequence number
//   4 bytes:  additional length = ceil(n / 4)
//  24 bytes:  unused
//   N bytes:  LISTofCARD8 (each 1 byte: button number assigned to that
//             physical position; 0 = disabled). Padded to a multiple of 4.

public struct GetPointerMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var map: [UInt8]                  // typical default: [1, 2, 3] (left, middle, right)

    public init(sequenceNumber: UInt16, map: [UInt8]) {
        self.sequenceNumber = sequenceNumber
        self.map = map
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let pad = xPad(map.count)
        let lenIn4 = UInt32((map.count + pad) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(UInt8(map.count))
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writePadding(24)
        w.writeBytes(map)
        w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetPointerMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let n = Int(try r.readUInt8())
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        try r.skip(24)
        let map = try r.readBytes(n)
        return GetPointerMappingReply(sequenceNumber: seq, map: map)
    }
}
