public struct CreatePixmap: Equatable, Sendable {
    public static let opcode: UInt8 = 53

    public var depth: UInt8
    public var pid: UInt32
    public var drawable: UInt32
    public var width: UInt16
    public var height: UInt16

    public init(depth: UInt8, pid: UInt32, drawable: UInt32, width: UInt16, height: UInt16) {
        self.depth = depth
        self.pid = pid
        self.drawable = drawable
        self.width = width
        self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(depth)
        w.writeUInt16(4)
        w.writeUInt32(pid)
        w.writeUInt32(drawable)
        w.writeUInt16(width)
        w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreatePixmap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let depth = try r.readUInt8()
        _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let drawable = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return CreatePixmap(depth: depth, pid: pid, drawable: drawable, width: width, height: height)
    }
}
