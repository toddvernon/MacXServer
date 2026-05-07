// QueryColors reply layout (X11 spec section 7.4):
//
//   1 byte:   marker (1)
//   1 byte:   unused
//   2 bytes:  sequence number
//   4 bytes:  additional length = 2 * n (each RGB entry is 8 bytes = 2 words)
//   2 bytes:  number of colors n
//  22 bytes:  unused
//   N bytes:  LISTofRGB (each 8 bytes: red 2, green 2, blue 2, unused 2)

public struct QueryColorsRGB: Equatable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16
    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public struct QueryColorsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var colors: [QueryColorsRGB]

    public init(sequenceNumber: UInt16, colors: [QueryColorsRGB]) {
        self.sequenceNumber = sequenceNumber
        self.colors = colors
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(2 * colors.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(colors.count))
        w.writePadding(22)
        for c in colors {
            w.writeUInt16(c.red)
            w.writeUInt16(c.green)
            w.writeUInt16(c.blue)
            w.writeUInt16(0)                 // unused
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryColorsReply {
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
        var colors: [QueryColorsRGB] = []
        colors.reserveCapacity(n)
        for _ in 0..<n {
            let red = try r.readUInt16()
            let green = try r.readUInt16()
            let blue = try r.readUInt16()
            _ = try r.readUInt16()
            colors.append(QueryColorsRGB(red: red, green: green, blue: blue))
        }
        return QueryColorsReply(sequenceNumber: seq, colors: colors)
    }
}
