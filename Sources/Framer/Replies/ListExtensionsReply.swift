// ListExtensions reply layout (X11 spec section 9; Xproto.h
// xListExtensionsReply):
//
//   1 byte:  marker (1)
//   1 byte:  nExtensions
//   2 bytes: sequence number
//   4 bytes: reply length = ceil(total / 4) where total is sum of
//            (1 byte name-len + name bytes) across every extension
//   24 bytes: unused
//   followed by sequence of (1 byte length, N bytes name) per extension
//   pad bytes: zero pad to multiple of 4

public struct ListExtensionsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var names: [[UInt8]]

    public init(sequenceNumber: UInt16, names: [[UInt8]]) {
        self.sequenceNumber = sequenceNumber
        self.names = names
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        var totalNameBytes = 0
        for name in names { totalNameBytes += 1 + name.count }
        let pad = (4 - totalNameBytes % 4) % 4
        let lengthWords = UInt32((totalNameBytes + pad) / 4)
        w.writeUInt8(1)
        w.writeUInt8(UInt8(names.count))
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lengthWords)
        w.writePadding(24)
        for name in names {
            w.writeUInt8(UInt8(name.count))
            w.writeBytes(name)
        }
        w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListExtensionsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let n = try r.readUInt8()
        let seq = try r.readUInt16()
        let length = try r.readUInt32()
        try r.skip(24)
        let total = 32 + Int(length) * 4
        guard bytes.count >= total else {
            throw FramerError.truncated(needed: total, available: bytes.count)
        }
        var names: [[UInt8]] = []
        for _ in 0..<Int(n) {
            let nameLen = try r.readUInt8()
            names.append(try r.readBytes(Int(nameLen)))
        }
        return ListExtensionsReply(sequenceNumber: seq, names: names)
    }
}
