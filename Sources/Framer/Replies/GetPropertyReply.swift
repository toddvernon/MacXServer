// GetProperty reply layout (X11 spec section 5.3.4):
//
//   1 byte:  marker (1)
//   1 byte:  format (0 if no value, otherwise 8/16/32)
//   2 bytes: sequence number
//   4 bytes: additional length in 4-byte units (= ceil(valueByteCount / 4))
//   4 bytes: type atom (0 = None when there's no value)
//   4 bytes: bytes-after (how many bytes of the property remain unread; 0 if we
//            returned the whole thing)
//   4 bytes: length of value (in `format`-bit units; 0 for the empty reply)
//  12 bytes: unused
//   N bytes: value, padded to a multiple of 4

public struct GetPropertyReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var format: UInt8                // 0 = no value
    public var type: UInt32                 // ATOM, 0 = None
    public var bytesAfter: UInt32
    public var value: [UInt8]               // raw bytes; caller already encoded for format

    public init(
        sequenceNumber: UInt16,
        format: UInt8,
        type: UInt32,
        bytesAfter: UInt32,
        value: [UInt8]
    ) {
        self.sequenceNumber = sequenceNumber
        self.format = format
        self.type = type
        self.bytesAfter = bytesAfter
        self.value = value
    }

    /// The empty reply xclock and others receive for unknown properties:
    /// format=0, type=None, no value.
    public static func empty(sequenceNumber: UInt16) -> GetPropertyReply {
        GetPropertyReply(
            sequenceNumber: sequenceNumber,
            format: 0,
            type: 0,
            bytesAfter: 0,
            value: []
        )
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let valueLenInFormatUnits: UInt32
        switch format {
        case 0:  valueLenInFormatUnits = 0
        case 8:  valueLenInFormatUnits = UInt32(value.count)
        case 16: valueLenInFormatUnits = UInt32(value.count / 2)
        case 32: valueLenInFormatUnits = UInt32(value.count / 4)
        default: valueLenInFormatUnits = 0
        }
        let pad = xPad(value.count)
        let lenIn4 = UInt32((value.count + pad) / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(format)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(type)
        w.writeUInt32(bytesAfter)
        w.writeUInt32(valueLenInFormatUnits)
        w.writePadding(12)
        w.writeBytes(value)
        w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetPropertyReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let format = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        let type = try r.readUInt32()
        let bytesAfter = try r.readUInt32()
        let valueLenInUnits = Int(try r.readUInt32())
        try r.skip(12)

        let valueByteCount: Int
        switch format {
        case 8:  valueByteCount = valueLenInUnits
        case 16: valueByteCount = valueLenInUnits * 2
        case 32: valueByteCount = valueLenInUnits * 4
        default: valueByteCount = 0
        }
        let totalBytes = lenIn4 * 4
        guard valueByteCount <= totalBytes else {
            throw FramerError.invalidEnum(name: "GetPropertyReply.value", value: UInt32(valueByteCount))
        }
        let value = try r.readBytes(valueByteCount)
        return GetPropertyReply(
            sequenceNumber: seq,
            format: format,
            type: type,
            bytesAfter: bytesAfter,
            value: value
        )
    }
}
