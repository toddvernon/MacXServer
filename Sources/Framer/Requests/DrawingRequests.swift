// Drawing requests that share a (drawable + gc + LIST) shape.

public struct PolySegment: Equatable, Sendable {
    public static let opcode: UInt8 = 66
    public var drawable: UInt32
    public var gc: UInt32
    public var segments: [Segment]

    public init(drawable: UInt32, gc: UInt32, segments: [Segment]) {
        self.drawable = drawable
        self.gc = gc
        self.segments = segments
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 2 * segments.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        for s in segments { s.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolySegment {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let n = (lenIn4 - 3) / 2
        var segs: [Segment] = []
        segs.reserveCapacity(n)
        for _ in 0..<n {
            segs.append(try Segment.decode(from: &r))
        }
        return PolySegment(drawable: drawable, gc: gc, segments: segs)
    }
}

public enum PolyShape: UInt8, Sendable {
    case complex = 0
    case nonconvex = 1
    case convex = 2
}

public struct FillPoly: Equatable, Sendable {
    public static let opcode: UInt8 = 69
    public var drawable: UInt32
    public var gc: UInt32
    public var shape: PolyShape
    public var coordinateMode: CoordinateMode
    public var points: [Point]

    public init(drawable: UInt32, gc: UInt32, shape: PolyShape, coordinateMode: CoordinateMode, points: [Point]) {
        self.drawable = drawable
        self.gc = gc
        self.shape = shape
        self.coordinateMode = coordinateMode
        self.points = points
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(4 + points.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        w.writeUInt8(shape.rawValue)
        w.writeUInt8(coordinateMode.rawValue)
        w.writeUInt16(0)
        for p in points { p.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FillPoly {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let shapeRaw = try r.readUInt8()
        guard let shape = PolyShape(rawValue: shapeRaw) else {
            throw FramerError.invalidEnum(name: "PolyShape", value: UInt32(shapeRaw))
        }
        let cmRaw = try r.readUInt8()
        guard let cm = CoordinateMode(rawValue: cmRaw) else {
            throw FramerError.invalidEnum(name: "CoordinateMode", value: UInt32(cmRaw))
        }
        _ = try r.readUInt16()
        let n = lenIn4 - 4
        var points: [Point] = []
        points.reserveCapacity(n)
        for _ in 0..<n {
            points.append(try Point.decode(from: &r))
        }
        return FillPoly(drawable: drawable, gc: gc, shape: shape, coordinateMode: cm, points: points)
    }
}

public struct PolyArc: Equatable, Sendable {
    public static let opcode: UInt8 = 68
    public var drawable: UInt32
    public var gc: UInt32
    public var arcs: [Arc]

    public init(drawable: UInt32, gc: UInt32, arcs: [Arc]) {
        self.drawable = drawable
        self.gc = gc
        self.arcs = arcs
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 3 * arcs.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        for a in arcs { a.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyArc {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let n = (lenIn4 - 3) / 3
        var arcs: [Arc] = []
        arcs.reserveCapacity(n)
        for _ in 0..<n {
            arcs.append(try Arc.decode(from: &r))
        }
        return PolyArc(drawable: drawable, gc: gc, arcs: arcs)
    }
}

public struct PolyFillArc: Equatable, Sendable {
    public static let opcode: UInt8 = 71
    public var drawable: UInt32
    public var gc: UInt32
    public var arcs: [Arc]

    public init(drawable: UInt32, gc: UInt32, arcs: [Arc]) {
        self.drawable = drawable
        self.gc = gc
        self.arcs = arcs
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + 3 * arcs.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        for a in arcs { a.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyFillArc {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let n = (lenIn4 - 3) / 3
        var arcs: [Arc] = []
        arcs.reserveCapacity(n)
        for _ in 0..<n {
            arcs.append(try Arc.decode(from: &r))
        }
        return PolyFillArc(drawable: drawable, gc: gc, arcs: arcs)
    }
}

// PolyText8 carries a list of TEXTITEM8 entries that mix font-shifts and
// text-elements. Decoding the items themselves is non-trivial, so the framer
// stores the raw items bytes verbatim; consumers can peek at the first byte
// of each item to dispatch (255 = font shift, otherwise text-element).
public struct PolyText8: Equatable, Sendable {
    public static let opcode: UInt8 = 74
    public var drawable: UInt32
    public var gc: UInt32
    public var x: Int16
    public var y: Int16
    public var items: [UInt8]         // raw items bytes (includes any trailing pad)

    public init(drawable: UInt32, gc: UInt32, x: Int16, y: Int16, items: [UInt8]) {
        self.drawable = drawable
        self.gc = gc
        self.x = x
        self.y = y
        self.items = items
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = items.count
        let p = xPad(n)
        let lenIn4 = UInt16(4 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeBytes(items)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyText8 {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let totalItemsBytes = (lenIn4 - 4) * 4
        let items = try r.readBytes(totalItemsBytes)
        return PolyText8(drawable: drawable, gc: gc, x: x, y: y, items: items)
    }
}
