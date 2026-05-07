// ListFonts reply layout (X11 spec section 7.5):
//
//   1 byte:   marker (1)
//   1 byte:   unused
//   2 bytes:  sequence number
//   4 bytes:  additional length in 4-byte units
//   2 bytes:  number of names
//  22 bytes:  unused
//   N bytes:  LISTofSTR8 (each STR8 = 1 byte length + that many name bytes)
//             padded to a multiple of 4

public struct ListFontsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var names: [[UInt8]]      // each name byte-array; STR8 max 255

    public init(sequenceNumber: UInt16, names: [[UInt8]]) {
        for n in names {
            precondition(n.count <= 255, "STR8 must be <= 255 bytes")
        }
        self.sequenceNumber = sequenceNumber
        self.names = names
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var nameBytes: [UInt8] = []
        for n in names {
            nameBytes.append(UInt8(n.count))
            nameBytes.append(contentsOf: n)
        }
        let pad = xPad(nameBytes.count)
        let lenIn4 = UInt32((nameBytes.count + pad) / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)                      // marker
        w.writeUInt8(0)                      // unused
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(names.count))
        w.writePadding(22)
        w.writeBytes(nameBytes)
        w.writePadding(pad)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListFontsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = Int(try r.readUInt16())
        try r.skip(22)
        var names: [[UInt8]] = []
        names.reserveCapacity(n)
        for _ in 0..<n {
            let len = Int(try r.readUInt8())
            names.append(try r.readBytes(len))
        }
        return ListFontsReply(sequenceNumber: seq, names: names)
    }
}
