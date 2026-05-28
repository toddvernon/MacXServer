// SHAPE extension reply types.
//
// Wire layout transcribed from reference/X11R6/xc/include/extensions/shapestr.h.
// All replies are 32 bytes plus, for GetRectangles, a trailing xRectangle array.

// MARK: - ShapeQueryVersion reply

public struct ShapeQueryVersionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var majorVersion: UInt16
    public var minorVersion: UInt16

    public init(sequenceNumber: UInt16, majorVersion: UInt16, minorVersion: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)                      // length = 0
        w.writeUInt16(majorVersion)
        w.writeUInt16(minorVersion)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeQueryVersionReply {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        return ShapeQueryVersionReply(sequenceNumber: seq, majorVersion: major, minorVersion: minor)
    }
}

// MARK: - ShapeQueryExtents reply

public struct ShapeQueryExtentsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var boundingShaped: Bool
    public var clipShaped: Bool
    public var xBounding: Int16
    public var yBounding: Int16
    public var widthBounding: UInt16
    public var heightBounding: UInt16
    public var xClip: Int16
    public var yClip: Int16
    public var widthClip: UInt16
    public var heightClip: UInt16

    public init(sequenceNumber: UInt16,
                boundingShaped: Bool, clipShaped: Bool,
                xBounding: Int16, yBounding: Int16, widthBounding: UInt16, heightBounding: UInt16,
                xClip: Int16, yClip: Int16, widthClip: UInt16, heightClip: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.boundingShaped = boundingShaped; self.clipShaped = clipShaped
        self.xBounding = xBounding; self.yBounding = yBounding
        self.widthBounding = widthBounding; self.heightBounding = heightBounding
        self.xClip = xClip; self.yClip = yClip
        self.widthClip = widthClip; self.heightClip = heightClip
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)                      // length = 0
        w.writeUInt8(boundingShaped ? 1 : 0)
        w.writeUInt8(clipShaped ? 1 : 0)
        w.writeUInt16(0)                      // unused1
        w.writeUInt16(UInt16(bitPattern: xBounding)); w.writeUInt16(UInt16(bitPattern: yBounding))
        w.writeUInt16(widthBounding); w.writeUInt16(heightBounding)
        w.writeUInt16(UInt16(bitPattern: xClip)); w.writeUInt16(UInt16(bitPattern: yClip))
        w.writeUInt16(widthClip); w.writeUInt16(heightClip)
        w.writeUInt32(0)                      // pad1
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeQueryExtentsReply {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let bShaped = (try r.readUInt8()) != 0
        let cShaped = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let xb = Int16(bitPattern: try r.readUInt16()); let yb = Int16(bitPattern: try r.readUInt16())
        let wb = try r.readUInt16(); let hb = try r.readUInt16()
        let xc = Int16(bitPattern: try r.readUInt16()); let yc = Int16(bitPattern: try r.readUInt16())
        let wc = try r.readUInt16(); let hc = try r.readUInt16()
        return ShapeQueryExtentsReply(
            sequenceNumber: seq, boundingShaped: bShaped, clipShaped: cShaped,
            xBounding: xb, yBounding: yb, widthBounding: wb, heightBounding: hb,
            xClip: xc, yClip: yc, widthClip: wc, heightClip: hc)
    }
}

// MARK: - ShapeInputSelected reply

public struct ShapeInputSelectedReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var enabled: Bool

    public init(sequenceNumber: UInt16, enabled: Bool) {
        self.sequenceNumber = sequenceNumber
        self.enabled = enabled
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(enabled ? 1 : 0)   // `enabled` rides in the unused byte
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)                      // length = 0
        w.writePadding(24)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeInputSelectedReply {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let enabled = (try r.readUInt8()) != 0
        let seq = try r.readUInt16()
        return ShapeInputSelectedReply(sequenceNumber: seq, enabled: enabled)
    }
}

// MARK: - ShapeGetRectangles reply

public struct ShapeGetRectanglesReply: Equatable, Sendable {
    /// Rectangle ordering: Unsorted=0, YSorted=1, YXSorted=2, YXBanded=3.
    public var sequenceNumber: UInt16
    public var ordering: UInt8
    public var rectangles: [Rectangle]

    public init(sequenceNumber: UInt16, ordering: UInt8, rectangles: [Rectangle]) {
        self.sequenceNumber = sequenceNumber
        self.ordering = ordering
        self.rectangles = rectangles
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = rectangles.count
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(ordering)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(UInt32(n * 2))          // length in 4-byte units = nrects*8/4
        w.writeUInt32(UInt32(n))              // nrects
        w.writePadding(20)
        for r in rectangles { r.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeGetRectanglesReply {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let ordering = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()                // length
        let n = Int(try r.readUInt32())
        try r.skip(20)
        var rects: [Rectangle] = []
        rects.reserveCapacity(n)
        for _ in 0..<n { rects.append(try Rectangle.decode(from: &r)) }
        return ShapeGetRectanglesReply(sequenceNumber: seq, ordering: ordering, rectangles: rects)
    }
}
