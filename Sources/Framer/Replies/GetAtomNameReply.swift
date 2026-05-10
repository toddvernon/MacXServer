// GetAtomName reply layout (X11 spec section 9; Xproto.h xGetAtomNameReply):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: reply length = ceil(nameLength / 4)
//   2 bytes: nameLength
//   22 bytes: unused
//   nameLength bytes: name (LATIN-1)
//   pad bytes: zero pad to multiple of 4

public struct GetAtomNameReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var name: [UInt8]

    public init(sequenceNumber: UInt16, name: [UInt8]) {
        self.sequenceNumber = sequenceNumber
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        let pad = (4 - name.count % 4) % 4
        let lengthWords = UInt32((name.count + pad) / 4)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lengthWords)
        w.writeUInt16(UInt16(name.count))
        w.writePadding(22)
        w.writeBytes(name)
        w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetAtomNameReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let length = try r.readUInt32()
        let nameLen = try r.readUInt16()
        try r.skip(22)
        let total = 32 + Int(length) * 4
        guard bytes.count >= total else {
            throw FramerError.truncated(needed: total, available: bytes.count)
        }
        let name = try r.readBytes(Int(nameLen))
        return GetAtomNameReply(sequenceNumber: seq, name: name)
    }
}
