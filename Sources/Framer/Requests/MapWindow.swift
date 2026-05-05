public struct MapWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 8

    public var window: UInt32

    public init(window: UInt32) {
        self.window = window
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> MapWindow {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        return MapWindow(window: window)
    }
}
