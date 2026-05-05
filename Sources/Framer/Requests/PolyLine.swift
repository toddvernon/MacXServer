public enum CoordinateMode: UInt8, Sendable {
    case origin = 0
    case previous = 1
}

public struct PolyLine: Equatable, Sendable {
    public static let opcode: UInt8 = 65

    public var coordinateMode: CoordinateMode
    public var drawable: UInt32
    public var gc: UInt32
    public var points: [Point]

    public init(coordinateMode: CoordinateMode, drawable: UInt32, gc: UInt32, points: [Point]) {
        self.coordinateMode = coordinateMode
        self.drawable = drawable
        self.gc = gc
        self.points = points
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + points.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(coordinateMode.rawValue)
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        for p in points { p.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyLine {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = CoordinateMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "CoordinateMode", value: UInt32(modeRaw))
        }
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let nPoints = lenIn4 - 3
        var points: [Point] = []
        points.reserveCapacity(nPoints)
        for _ in 0..<nPoints {
            points.append(try Point.decode(from: &r))
        }
        return PolyLine(coordinateMode: mode, drawable: drawable, gc: gc, points: points)
    }
}
