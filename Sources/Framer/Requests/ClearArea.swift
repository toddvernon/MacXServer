public struct ClearArea: Equatable, Sendable {
    public static let opcode: UInt8 = 61

    public var exposures: Bool
    public var window: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16

    public init(exposures: Bool, window: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16) {
        self.exposures = exposures
        self.window = window
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(exposures ? 1 : 0)
        w.writeUInt16(4)
        w.writeUInt32(window)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width)
        w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ClearArea {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let exposures = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return ClearArea(exposures: exposures, window: window, x: x, y: y, width: width, height: height)
    }
}
