// RENDER extension Tier-A request wire types.
//
// Phase 3 RENDER Session 1 (2026-05-30). Tier A — the requests every
// Cairo/Pango client emits during startup or per-frame, except for
// CompositeGlyphs* and AddGlyphs which need their own walkers and
// land in Session 2.
//
// RENDER post-dates X11R6; the wire format here is from xorgproto's
// renderproto.h (version 0.11). No R6/modern carve-out.
//
// Opcode 16 (X_RenderTransform) is reserved / unused per render.h —
// don't emit minor=16. Opcodes 3, 14, 15, 21 are spec'd but never
// shipped; the dumper treats them as "(reserved/unimplemented)".

public enum RenderMinor {
    public static let queryVersion: UInt8 = 0
    public static let queryPictFormats: UInt8 = 1
    public static let queryPictIndexValues: UInt8 = 2     // Tier B
    public static let queryDithers: UInt8 = 3             // reserved
    public static let createPicture: UInt8 = 4
    public static let changePicture: UInt8 = 5
    public static let setPictureClipRectangles: UInt8 = 6
    public static let freePicture: UInt8 = 7
    public static let composite: UInt8 = 8
    public static let scale: UInt8 = 9                    // Tier C / legacy
    public static let trapezoids: UInt8 = 10              // Tier B
    public static let triangles: UInt8 = 11
    public static let triStrip: UInt8 = 12
    public static let triFan: UInt8 = 13
    public static let colorTrapezoids: UInt8 = 14         // reserved
    public static let colorTriangles: UInt8 = 15          // reserved
    public static let _reservedTransform: UInt8 = 16      // hole
    public static let createGlyphSet: UInt8 = 17
    public static let referenceGlyphSet: UInt8 = 18
    public static let freeGlyphSet: UInt8 = 19
    public static let addGlyphs: UInt8 = 20               // Tier A — Session 2
    public static let addGlyphsFromPicture: UInt8 = 21    // reserved
    public static let freeGlyphs: UInt8 = 22
    public static let compositeGlyphs8: UInt8 = 23        // Tier A — Session 2
    public static let compositeGlyphs16: UInt8 = 24       // Tier A — Session 2
    public static let compositeGlyphs32: UInt8 = 25       // Tier A — Session 2
    public static let fillRectangles: UInt8 = 26          // Tier B
    public static let createCursor: UInt8 = 27            // Tier C
    public static let setPictureTransform: UInt8 = 28
    public static let queryFilters: UInt8 = 29            // Tier B
    public static let setPictureFilter: UInt8 = 30        // Tier B
    public static let createAnimCursor: UInt8 = 31        // Tier C
    public static let addTraps: UInt8 = 32                // Tier B
    public static let createSolidFill: UInt8 = 33         // Tier B
    public static let createLinearGradient: UInt8 = 34    // Tier C
    public static let createRadialGradient: UInt8 = 35    // Tier C
    public static let createConicalGradient: UInt8 = 36   // Tier C
}

// MARK: - RenderQueryVersion (minor 0)

public struct RenderQueryVersion: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.queryVersion

    public var majorVersion: UInt32
    public var minorVersion: UInt32

    public init(majorVersion: UInt32, minorVersion: UInt32) {
        self.majorVersion = majorVersion; self.minorVersion = minorVersion
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(majorVersion); w.writeUInt32(minorVersion)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryVersion {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let major = try r.readUInt32()
        let minor = try r.readUInt32()
        return RenderQueryVersion(majorVersion: major, minorVersion: minor)
    }
}

// MARK: - RenderQueryPictIndexValues (minor 2) — Session 2

public struct RenderQueryPictIndexValues: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.queryPictIndexValues

    public var format: UInt32

    public init(format: UInt32) { self.format = format }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(format)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryPictIndexValues {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let format = try r.readUInt32()
        return RenderQueryPictIndexValues(format: format)
    }
}

// MARK: - RenderQueryFilters (minor 29) — Session 2

public struct RenderQueryFilters: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.queryFilters

    public var drawable: UInt32

    public init(drawable: UInt32) { self.drawable = drawable }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(drawable)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryFilters {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        return RenderQueryFilters(drawable: drawable)
    }
}

// MARK: - RenderQueryPictFormats (minor 1)

public struct RenderQueryPictFormats: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.queryPictFormats

    public init() {}

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryPictFormats {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        return RenderQueryPictFormats()
    }
}

// MARK: - RenderCreatePicture (minor 4)

/// 20-byte fixed header + value-list trailer gated by `valueMask` (the
/// CP* bits in render.h). Same shape as ChangeGC.
public struct RenderCreatePicture: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createPicture

    public var pid: UInt32         // Picture
    public var drawable: UInt32
    public var format: UInt32      // PictFormat
    public var valueMask: UInt32
    /// One 4-byte slot per set bit in `valueMask`, in ascending bit order.
    public var valueList: [UInt8]

    public init(pid: UInt32, drawable: UInt32, format: UInt32,
                valueMask: UInt32, valueList: [UInt8] = []) {
        precondition(valueList.count % 4 == 0, "valueList must be 4-byte aligned")
        precondition(valueList.count / 4 == valueMask.nonzeroBitCount,
                     "valueList size must match valueMask popcount")
        self.pid = pid; self.drawable = drawable; self.format = format
        self.valueMask = valueMask; self.valueList = valueList
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + valueList.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(pid); w.writeUInt32(drawable)
        w.writeUInt32(format)
        w.writeUInt32(valueMask)
        w.writeBytes(valueList)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreatePicture {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let pid = try r.readUInt32()
        let drawable = try r.readUInt32()
        let format = try r.readUInt32()
        let valueMask = try r.readUInt32()
        let valueList = try r.readBytes((lenIn4 - 5) * 4)
        return RenderCreatePicture(
            pid: pid, drawable: drawable, format: format,
            valueMask: valueMask, valueList: valueList
        )
    }
}

// MARK: - RenderChangePicture (minor 5)

public struct RenderChangePicture: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.changePicture

    public var picture: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]

    public init(picture: UInt32, valueMask: UInt32, valueList: [UInt8] = []) {
        precondition(valueList.count % 4 == 0, "valueList must be 4-byte aligned")
        precondition(valueList.count / 4 == valueMask.nonzeroBitCount,
                     "valueList size must match valueMask popcount")
        self.picture = picture
        self.valueMask = valueMask
        self.valueList = valueList
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + valueList.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(picture)
        w.writeUInt32(valueMask)
        w.writeBytes(valueList)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderChangePicture {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let picture = try r.readUInt32()
        let valueMask = try r.readUInt32()
        let valueList = try r.readBytes((lenIn4 - 3) * 4)
        return RenderChangePicture(
            picture: picture, valueMask: valueMask, valueList: valueList
        )
    }
}

// MARK: - RenderSetPictureClipRectangles (minor 6)

public struct RenderSetPictureClipRectangles: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.setPictureClipRectangles

    public var picture: UInt32
    public var xOrigin: Int16
    public var yOrigin: Int16
    public var rectangles: [Rectangle]

    public init(picture: UInt32, xOrigin: Int16, yOrigin: Int16,
                rectangles: [Rectangle]) {
        self.picture = picture
        self.xOrigin = xOrigin; self.yOrigin = yOrigin
        self.rectangles = rectangles
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + rectangles.count * 2)   // 8 bytes per Rectangle
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(picture)
        w.writeUInt16(UInt16(bitPattern: xOrigin))
        w.writeUInt16(UInt16(bitPattern: yOrigin))
        for rect in rectangles {
            w.writeUInt16(UInt16(bitPattern: rect.x))
            w.writeUInt16(UInt16(bitPattern: rect.y))
            w.writeUInt16(rect.width)
            w.writeUInt16(rect.height)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderSetPictureClipRectangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let picture = try r.readUInt32()
        let xOrigin = Int16(bitPattern: try r.readUInt16())
        let yOrigin = Int16(bitPattern: try r.readUInt16())
        let nRects = (lenIn4 - 3) / 2
        var rects: [Rectangle] = []
        rects.reserveCapacity(nRects)
        for _ in 0..<nRects {
            let x = Int16(bitPattern: try r.readUInt16())
            let y = Int16(bitPattern: try r.readUInt16())
            let w = try r.readUInt16()
            let h = try r.readUInt16()
            rects.append(Rectangle(x: x, y: y, width: w, height: h))
        }
        return RenderSetPictureClipRectangles(
            picture: picture, xOrigin: xOrigin, yOrigin: yOrigin,
            rectangles: rects
        )
    }
}

// MARK: - RenderFreePicture (minor 7)

public struct RenderFreePicture: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.freePicture

    public var picture: UInt32

    public init(picture: UInt32) { self.picture = picture }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(picture)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderFreePicture {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let picture = try r.readUInt32()
        return RenderFreePicture(picture: picture)
    }
}

// MARK: - RenderComposite (minor 8) — the per-frame hot path

public struct RenderComposite: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.composite

    public var op: UInt8            // PictOp* — Clear=0, Src=1, Over=3, ... see render.h
    public var src: UInt32          // Picture
    public var mask: UInt32         // Picture; 0 = None
    public var dst: UInt32          // Picture
    public var xSrc: Int16
    public var ySrc: Int16
    public var xMask: Int16
    public var yMask: Int16
    public var xDst: Int16
    public var yDst: Int16
    public var width: UInt16
    public var height: UInt16

    public init(op: UInt8, src: UInt32, mask: UInt32, dst: UInt32,
                xSrc: Int16, ySrc: Int16,
                xMask: Int16, yMask: Int16,
                xDst: Int16, yDst: Int16,
                width: UInt16, height: UInt16) {
        self.op = op
        self.src = src; self.mask = mask; self.dst = dst
        self.xSrc = xSrc; self.ySrc = ySrc
        self.xMask = xMask; self.yMask = yMask
        self.xDst = xDst; self.yDst = yDst
        self.width = width; self.height = height
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(9)
        w.writeUInt8(op); w.writePadding(3)
        w.writeUInt32(src); w.writeUInt32(mask); w.writeUInt32(dst)
        w.writeUInt16(UInt16(bitPattern: xSrc)); w.writeUInt16(UInt16(bitPattern: ySrc))
        w.writeUInt16(UInt16(bitPattern: xMask)); w.writeUInt16(UInt16(bitPattern: yMask))
        w.writeUInt16(UInt16(bitPattern: xDst)); w.writeUInt16(UInt16(bitPattern: yDst))
        w.writeUInt16(width); w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderComposite {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let op = try r.readUInt8(); try r.skip(3)
        let src = try r.readUInt32()
        let mask = try r.readUInt32()
        let dst = try r.readUInt32()
        let xSrc = Int16(bitPattern: try r.readUInt16())
        let ySrc = Int16(bitPattern: try r.readUInt16())
        let xMask = Int16(bitPattern: try r.readUInt16())
        let yMask = Int16(bitPattern: try r.readUInt16())
        let xDst = Int16(bitPattern: try r.readUInt16())
        let yDst = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return RenderComposite(
            op: op, src: src, mask: mask, dst: dst,
            xSrc: xSrc, ySrc: ySrc,
            xMask: xMask, yMask: yMask,
            xDst: xDst, yDst: yDst,
            width: width, height: height
        )
    }
}

// MARK: - RenderCreateGlyphSet (minor 17)

public struct RenderCreateGlyphSet: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createGlyphSet
    public var gsid: UInt32   // Glyphset
    public var format: UInt32 // PictFormat

    public init(gsid: UInt32, format: UInt32) {
        self.gsid = gsid; self.format = format
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(gsid); w.writeUInt32(format)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateGlyphSet {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let gsid = try r.readUInt32()
        let format = try r.readUInt32()
        return RenderCreateGlyphSet(gsid: gsid, format: format)
    }
}

// MARK: - RenderFreeGlyphSet (minor 19)

public struct RenderFreeGlyphSet: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.freeGlyphSet
    public var glyphset: UInt32

    public init(glyphset: UInt32) { self.glyphset = glyphset }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(glyphset)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderFreeGlyphSet {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let glyphset = try r.readUInt32()
        return RenderFreeGlyphSet(glyphset: glyphset)
    }
}

// MARK: - RenderFreeGlyphs (minor 22)

public struct RenderFreeGlyphs: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.freeGlyphs
    public var glyphset: UInt32
    public var glyphIDs: [UInt32]

    public init(glyphset: UInt32, glyphIDs: [UInt32]) {
        self.glyphset = glyphset; self.glyphIDs = glyphIDs
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + glyphIDs.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(glyphset)
        for g in glyphIDs { w.writeUInt32(g) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderFreeGlyphs {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let glyphset = try r.readUInt32()
        let n = lenIn4 - 2
        var ids: [UInt32] = []
        ids.reserveCapacity(n)
        for _ in 0..<n { ids.append(try r.readUInt32()) }
        return RenderFreeGlyphs(glyphset: glyphset, glyphIDs: ids)
    }
}

// MARK: - RenderAddGlyphs (minor 20) — Session 2

/// 12-byte header (glyphset + nglyphs) + the three-part trailer
/// handled by RenderAddGlyphsPayload (glyph IDs, GlyphInfo records,
/// concatenated bitmap blob).
public struct RenderAddGlyphs: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.addGlyphs

    public var glyphset: UInt32
    public var payload: RenderAddGlyphsPayload

    public init(glyphset: UInt32, payload: RenderAddGlyphsPayload) {
        self.glyphset = glyphset; self.payload = payload
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let trailer = payload.encode(byteOrder: byteOrder)
        let lenIn4 = UInt16(3 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(glyphset)
        w.writeUInt32(UInt32(payload.glyphIDs.count))
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderAddGlyphs {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let glyphset = try r.readUInt32()
        let nglyphs = Int(try r.readUInt32())
        let trailerBytes = (lenIn4 - 3) * 4
        let trailer = try r.readBytes(trailerBytes)
        let payload = try RenderAddGlyphsPayload.decode(
            from: trailer, nglyphs: nglyphs, byteOrder: byteOrder
        )
        return RenderAddGlyphs(glyphset: glyphset, payload: payload)
    }
}

// MARK: - RenderCompositeGlyphs8/16/32 (minors 23/24/25) — Session 2

/// Shared struct for all three CompositeGlyphs variants. `idSize`
/// discriminates the glyph-ID width in the trailer; the on-wire minor
/// opcode is derived from it.
///
/// The trailer is a stream of GLYPHITEM records — see
/// RenderGlyphStream. Each elt is either a draw (deltax/deltay plus
/// some glyph IDs) or a glyphset switch (len=0xFF + 4-byte glyphset).
public struct RenderCompositeGlyphs: Equatable, Sendable {
    public var idSize: RenderGlyphIdSize
    public var op: UInt8           // PictOp*
    public var src: UInt32         // Picture
    public var dst: UInt32         // Picture
    public var maskFormat: UInt32  // PictFormat or 0 (None)
    public var glyphset: UInt32    // Glyphset
    public var xSrc: Int16
    public var ySrc: Int16
    public var elts: [RenderGlyphElt]

    public init(idSize: RenderGlyphIdSize,
                op: UInt8, src: UInt32, dst: UInt32,
                maskFormat: UInt32, glyphset: UInt32,
                xSrc: Int16, ySrc: Int16,
                elts: [RenderGlyphElt]) {
        self.idSize = idSize
        self.op = op
        self.src = src; self.dst = dst
        self.maskFormat = maskFormat; self.glyphset = glyphset
        self.xSrc = xSrc; self.ySrc = ySrc
        self.elts = elts
    }

    public var minorOpcode: UInt8 {
        switch idSize {
        case .bits8:  return RenderMinor.compositeGlyphs8
        case .bits16: return RenderMinor.compositeGlyphs16
        case .bits32: return RenderMinor.compositeGlyphs32
        }
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let trailer = RenderGlyphStream.encode(elts, idSize: idSize, byteOrder: byteOrder)
        // 28 bytes header = 7 4-byte words.
        let lenIn4 = UInt16(7 + trailer.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(minorOpcode); w.writeUInt16(lenIn4)
        w.writeUInt8(op); w.writePadding(3)
        w.writeUInt32(src); w.writeUInt32(dst)
        w.writeUInt32(maskFormat); w.writeUInt32(glyphset)
        w.writeUInt16(UInt16(bitPattern: xSrc)); w.writeUInt16(UInt16(bitPattern: ySrc))
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCompositeGlyphs {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let minor = try r.readUInt8()
        let idSize: RenderGlyphIdSize
        switch minor {
        case RenderMinor.compositeGlyphs8:  idSize = .bits8
        case RenderMinor.compositeGlyphs16: idSize = .bits16
        case RenderMinor.compositeGlyphs32: idSize = .bits32
        default:
            throw FramerError.invalidOpcode(expected: RenderMinor.compositeGlyphs8, got: minor)
        }
        let lenIn4 = Int(try r.readUInt16())
        let op = try r.readUInt8(); try r.skip(3)
        let src = try r.readUInt32()
        let dst = try r.readUInt32()
        let maskFormat = try r.readUInt32()
        let glyphset = try r.readUInt32()
        let xSrc = Int16(bitPattern: try r.readUInt16())
        let ySrc = Int16(bitPattern: try r.readUInt16())
        let trailerBytes = (lenIn4 - 7) * 4
        let trailer = try r.readBytes(trailerBytes)
        let elts = try RenderGlyphStream.decode(
            from: trailer, idSize: idSize, byteOrder: byteOrder
        )
        return RenderCompositeGlyphs(
            idSize: idSize,
            op: op, src: src, dst: dst,
            maskFormat: maskFormat, glyphset: glyphset,
            xSrc: xSrc, ySrc: ySrc,
            elts: elts
        )
    }
}

// MARK: - RenderSetPictureTransform (minor 28)

/// 9 Fixed-point (16.16) entries for a 3×3 transformation matrix.
public struct RenderSetPictureTransform: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.setPictureTransform
    public var picture: UInt32
    /// Row-major 3×3 matrix. Each entry is a 32-bit fixed-point value
    /// (signed, 16.16 — i.e. raw value × 65536 = real-world units).
    public var matrix: [Int32]  // length 9

    public init(picture: UInt32, matrix: [Int32]) {
        precondition(matrix.count == 9, "matrix must have 9 entries (3x3)")
        self.picture = picture
        self.matrix = matrix
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(11)
        w.writeUInt32(picture)
        for m in matrix { w.writeUInt32(UInt32(bitPattern: m)) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderSetPictureTransform {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let picture = try r.readUInt32()
        var m: [Int32] = []; m.reserveCapacity(9)
        for _ in 0..<9 { m.append(Int32(bitPattern: try r.readUInt32())) }
        return RenderSetPictureTransform(picture: picture, matrix: m)
    }
}
