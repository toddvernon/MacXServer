public struct GetProperty: Equatable, Sendable {
    public static let opcode: UInt8 = 20

    public var delete: Bool
    public var window: UInt32
    public var property: UInt32
    public var type: UInt32
    public var longOffset: UInt32
    public var longLength: UInt32

    public init(
        delete: Bool,
        window: UInt32,
        property: UInt32,
        type: UInt32 = 0,
        longOffset: UInt32,
        longLength: UInt32
    ) {
        self.delete = delete
        self.window = window
        self.property = property
        self.type = type
        self.longOffset = longOffset
        self.longLength = longLength
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(delete ? 1 : 0)
        w.writeUInt16(6)
        w.writeUInt32(window)
        w.writeUInt32(property)
        w.writeUInt32(type)
        w.writeUInt32(longOffset)
        w.writeUInt32(longLength)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetProperty {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        let delete = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        let property = try r.readUInt32()
        let type = try r.readUInt32()
        let longOffset = try r.readUInt32()
        let longLength = try r.readUInt32()
        return GetProperty(
            delete: delete,
            window: window,
            property: property,
            type: type,
            longOffset: longOffset,
            longLength: longLength
        )
    }
}
