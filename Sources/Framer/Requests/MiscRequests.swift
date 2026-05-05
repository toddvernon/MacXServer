// Smaller standalone request opcodes batched together.

public struct AllocNamedColor: Equatable, Sendable {
    public static let opcode: UInt8 = 85
    public var cmap: UInt32
    public var name: [UInt8]

    public init(cmap: UInt32, name: [UInt8]) {
        self.cmap = cmap
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocNamedColor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return AllocNamedColor(cmap: cmap, name: name)
    }
}

public struct Bell: Equatable, Sendable {
    public static let opcode: UInt8 = 104
    public var percent: Int8           // -100..100; 0 = default volume

    public init(percent: Int8) {
        self.percent = percent
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(UInt8(bitPattern: percent))
        w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> Bell {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let pct = Int8(bitPattern: try r.readUInt8())
        _ = try r.readUInt16()
        return Bell(percent: pct)
    }
}

public struct QueryExtension: Equatable, Sendable {
    public static let opcode: UInt8 = 98
    public var name: [UInt8]

    public init(name: [UInt8]) {
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryExtension {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return QueryExtension(name: name)
    }
}
