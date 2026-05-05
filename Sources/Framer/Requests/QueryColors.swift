public struct QueryColors: Equatable, Sendable {
    public static let opcode: UInt8 = 91

    public var cmap: UInt32
    public var pixels: [UInt32]

    public init(cmap: UInt32, pixels: [UInt32]) {
        self.cmap = cmap
        self.pixels = pixels
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + pixels.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(lenIn4)
        w.writeUInt32(cmap)
        for p in pixels { w.writeUInt32(p) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryColors {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let cmap = try r.readUInt32()
        var pixels: [UInt32] = []
        let n = lenIn4 - 2
        pixels.reserveCapacity(n)
        for _ in 0..<n {
            pixels.append(try r.readUInt32())
        }
        return QueryColors(cmap: cmap, pixels: pixels)
    }
}
