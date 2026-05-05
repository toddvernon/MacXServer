public struct TranslateCoordinates: Equatable, Sendable {
    public static let opcode: UInt8 = 40

    public var srcWindow: UInt32
    public var dstWindow: UInt32
    public var srcX: Int16
    public var srcY: Int16

    public init(srcWindow: UInt32, dstWindow: UInt32, srcX: Int16, srcY: Int16) {
        self.srcWindow = srcWindow
        self.dstWindow = dstWindow
        self.srcX = srcX
        self.srcY = srcY
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)
        w.writeUInt32(srcWindow)
        w.writeUInt32(dstWindow)
        w.writeUInt16(UInt16(bitPattern: srcX))
        w.writeUInt16(UInt16(bitPattern: srcY))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> TranslateCoordinates {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let src = try r.readUInt32()
        let dst = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        return TranslateCoordinates(srcWindow: src, dstWindow: dst, srcX: x, srcY: y)
    }
}
