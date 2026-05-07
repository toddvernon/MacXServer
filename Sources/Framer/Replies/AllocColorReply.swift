// AllocColor reply layout (X11 spec section 7.4):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: additional length in 4-byte units (= 0)
//   2 bytes: red (the actually-allocated color, may differ from requested)
//   2 bytes: green
//   2 bytes: blue
//   2 bytes: unused
//   4 bytes: pixel
//  12 bytes: unused

public struct AllocColorReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16
    public var pixel: UInt32

    public init(sequenceNumber: UInt16, red: UInt16, green: UInt16, blue: UInt16, pixel: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.red = red
        self.green = green
        self.blue = blue
        self.pixel = pixel
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(red)
        w.writeUInt16(green)
        w.writeUInt16(blue)
        w.writeUInt16(0)
        w.writeUInt32(pixel)
        w.writePadding(12)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocColorReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let red = try r.readUInt16()
        let green = try r.readUInt16()
        let blue = try r.readUInt16()
        _ = try r.readUInt16()
        let pixel = try r.readUInt32()
        return AllocColorReply(
            sequenceNumber: seq,
            red: red, green: green, blue: blue,
            pixel: pixel
        )
    }
}
