public struct OpenFont: Equatable, Sendable {
    public static let opcode: UInt8 = 45

    public var fid: UInt32
    public var name: [UInt8]

    public init(fid: UInt32, name: [UInt8]) {
        self.fid = fid
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(lenIn4)
        w.writeUInt32(fid)
        w.writeUInt16(UInt16(n))
        w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> OpenFont {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let fid = try r.readUInt32()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return OpenFont(fid: fid, name: name)
    }
}
