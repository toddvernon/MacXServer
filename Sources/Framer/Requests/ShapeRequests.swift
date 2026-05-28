// SHAPE extension wire types (request side).
//
// SHAPE is X11R6's non-rectangular-window extension. Unlike core requests,
// the major opcode is assigned dynamically at QueryExtension time, so these
// don't live in the `Request` enum's static opcode switch — the server
// decodes them out of `Request.unknown(opcode, bytes)` once it knows which
// major opcode it handed out for "SHAPE". The minor opcode (the request's
// second byte) is what selects the specific request below.
//
// Wire layout transcribed from reference/X11R6/xc/include/extensions/shapestr.h.
// Field decode is mechanical and never rejects on semantic grounds (bad op /
// kind / ordering): the server validates those and emits BadValue with the
// offending value as errorValue, per Xext/shape.c.

/// SHAPE minor opcodes (the request's second byte). $X_Shape*$ in shape.h.
public enum ShapeMinor {
    public static let queryVersion: UInt8 = 0
    public static let rectangles: UInt8 = 1
    public static let mask: UInt8 = 2
    public static let combine: UInt8 = 3
    public static let offset: UInt8 = 4
    public static let queryExtents: UInt8 = 5
    public static let selectInput: UInt8 = 6
    public static let inputSelected: UInt8 = 7
    public static let getRectangles: UInt8 = 8
}

/// SHAPE combine operations (the `op` field). ShapeSet..ShapeInvert in shape.h.
public enum ShapeOp {
    public static let set: UInt8 = 0
    public static let union: UInt8 = 1
    public static let intersect: UInt8 = 2
    public static let subtract: UInt8 = 3
    public static let invert: UInt8 = 4
}

/// SHAPE shape kinds (the `destKind` / `srcKind` field). ShapeBounding / ShapeClip.
public enum ShapeKind {
    public static let bounding: UInt8 = 0
    public static let clip: UInt8 = 1
}

// MARK: - X_ShapeQueryVersion (minor 0)

public struct ShapeQueryVersion: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.queryVersion
    public init() {}

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeQueryVersion {
        return ShapeQueryVersion()
    }
}

// MARK: - X_ShapeRectangles (minor 1)

public struct ShapeRectangles: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.rectangles
    public var op: UInt8
    public var destKind: UInt8
    public var ordering: UInt8
    public var dest: UInt32
    public var xOff: Int16
    public var yOff: Int16
    public var rectangles: [Rectangle]

    public init(op: UInt8, destKind: UInt8, ordering: UInt8, dest: UInt32,
                xOff: Int16, yOff: Int16, rectangles: [Rectangle]) {
        self.op = op; self.destKind = destKind; self.ordering = ordering
        self.dest = dest; self.xOff = xOff; self.yOff = yOff
        self.rectangles = rectangles
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(4 + rectangles.count * 2)   // 16-byte header + 8 per rect
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(op); w.writeUInt8(destKind); w.writeUInt8(ordering); w.writeUInt8(0)
        w.writeUInt32(dest)
        w.writeUInt16(UInt16(bitPattern: xOff)); w.writeUInt16(UInt16(bitPattern: yOff))
        for r in rectangles { r.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeRectangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()                 // major (dynamic; not validated here)
        _ = try r.readUInt8()                 // minor
        let lenIn4 = try r.readUInt16()
        let op = try r.readUInt8()
        let destKind = try r.readUInt8()
        let ordering = try r.readUInt8()
        _ = try r.readUInt8()                 // pad0
        let dest = try r.readUInt32()
        let xOff = Int16(bitPattern: try r.readUInt16())
        let yOff = Int16(bitPattern: try r.readUInt16())
        // Rect bytes = total - 16-byte header. Each xRectangle is 8 bytes.
        let total = Int(lenIn4) * 4
        let rectBytes = max(0, total - 16)
        let count = rectBytes / 8
        var rects: [Rectangle] = []
        rects.reserveCapacity(count)
        for _ in 0..<count { rects.append(try Rectangle.decode(from: &r)) }
        return ShapeRectangles(op: op, destKind: destKind, ordering: ordering,
                               dest: dest, xOff: xOff, yOff: yOff, rectangles: rects)
    }
}

// MARK: - X_ShapeMask (minor 2)

public struct ShapeMask: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.mask
    public var op: UInt8
    public var destKind: UInt8
    public var dest: UInt32
    public var xOff: Int16
    public var yOff: Int16
    public var src: UInt32                    // depth-1 pixmap, or None (0)

    public init(op: UInt8, destKind: UInt8, dest: UInt32, xOff: Int16, yOff: Int16, src: UInt32) {
        self.op = op; self.destKind = destKind; self.dest = dest
        self.xOff = xOff; self.yOff = yOff; self.src = src
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(5)
        w.writeUInt8(op); w.writeUInt8(destKind); w.writeUInt16(0)
        w.writeUInt32(dest)
        w.writeUInt16(UInt16(bitPattern: xOff)); w.writeUInt16(UInt16(bitPattern: yOff))
        w.writeUInt32(src)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeMask {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let op = try r.readUInt8()
        let destKind = try r.readUInt8()
        _ = try r.readUInt16()                // junk
        let dest = try r.readUInt32()
        let xOff = Int16(bitPattern: try r.readUInt16())
        let yOff = Int16(bitPattern: try r.readUInt16())
        let src = try r.readUInt32()
        return ShapeMask(op: op, destKind: destKind, dest: dest, xOff: xOff, yOff: yOff, src: src)
    }
}

// MARK: - X_ShapeCombine (minor 3)

public struct ShapeCombine: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.combine
    public var op: UInt8
    public var destKind: UInt8
    public var srcKind: UInt8
    public var dest: UInt32
    public var xOff: Int16
    public var yOff: Int16
    public var src: UInt32                    // source window

    public init(op: UInt8, destKind: UInt8, srcKind: UInt8, dest: UInt32,
                xOff: Int16, yOff: Int16, src: UInt32) {
        self.op = op; self.destKind = destKind; self.srcKind = srcKind
        self.dest = dest; self.xOff = xOff; self.yOff = yOff; self.src = src
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(5)
        w.writeUInt8(op); w.writeUInt8(destKind); w.writeUInt8(srcKind); w.writeUInt8(0)
        w.writeUInt32(dest)
        w.writeUInt16(UInt16(bitPattern: xOff)); w.writeUInt16(UInt16(bitPattern: yOff))
        w.writeUInt32(src)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeCombine {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let op = try r.readUInt8()
        let destKind = try r.readUInt8()
        let srcKind = try r.readUInt8()
        _ = try r.readUInt8()                 // junk
        let dest = try r.readUInt32()
        let xOff = Int16(bitPattern: try r.readUInt16())
        let yOff = Int16(bitPattern: try r.readUInt16())
        let src = try r.readUInt32()
        return ShapeCombine(op: op, destKind: destKind, srcKind: srcKind,
                            dest: dest, xOff: xOff, yOff: yOff, src: src)
    }
}

// MARK: - X_ShapeOffset (minor 4)

public struct ShapeOffset: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.offset
    public var destKind: UInt8
    public var dest: UInt32
    public var xOff: Int16
    public var yOff: Int16

    public init(destKind: UInt8, dest: UInt32, xOff: Int16, yOff: Int16) {
        self.destKind = destKind; self.dest = dest; self.xOff = xOff; self.yOff = yOff
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt8(destKind); w.writeUInt8(0); w.writeUInt16(0)
        w.writeUInt32(dest)
        w.writeUInt16(UInt16(bitPattern: xOff)); w.writeUInt16(UInt16(bitPattern: yOff))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeOffset {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let destKind = try r.readUInt8()
        _ = try r.readUInt8()                 // junk1
        _ = try r.readUInt16()                // junk2
        let dest = try r.readUInt32()
        let xOff = Int16(bitPattern: try r.readUInt16())
        let yOff = Int16(bitPattern: try r.readUInt16())
        return ShapeOffset(destKind: destKind, dest: dest, xOff: xOff, yOff: yOff)
    }
}

// MARK: - X_ShapeQueryExtents (minor 5)

public struct ShapeQueryExtents: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.queryExtents
    public var window: UInt32
    public init(window: UInt32) { self.window = window }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeQueryExtents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        return ShapeQueryExtents(window: window)
    }
}

// MARK: - X_ShapeSelectInput (minor 6)

public struct ShapeSelectInput: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.selectInput
    public var window: UInt32
    public var enable: UInt8                  // xTrue (1) -> send events

    public init(window: UInt32, enable: UInt8) { self.window = window; self.enable = enable }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(window)
        w.writeUInt8(enable); w.writeUInt8(0); w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeSelectInput {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        let enable = try r.readUInt8()
        return ShapeSelectInput(window: window, enable: enable)
    }
}

// MARK: - X_ShapeInputSelected (minor 7)

public struct ShapeInputSelected: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.inputSelected
    public var window: UInt32
    public init(window: UInt32) { self.window = window }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeInputSelected {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        return ShapeInputSelected(window: window)
    }
}

// MARK: - X_ShapeGetRectangles (minor 8)

public struct ShapeGetRectangles: Equatable, Sendable {
    public static let minor: UInt8 = ShapeMinor.getRectangles
    public var window: UInt32
    public var kind: UInt8

    public init(window: UInt32, kind: UInt8) { self.window = window; self.kind = kind }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(window)
        w.writeUInt8(kind); w.writeUInt8(0); w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeGetRectangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let window = try r.readUInt32()
        let kind = try r.readUInt8()
        return ShapeGetRectangles(window: window, kind: kind)
    }
}
