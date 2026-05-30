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

// =============================================================================
// Session 3 (2026-05-30): Tier B + C bulk — polygons, gradients, cursor,
// FillRectangles, SetPictureFilter, ReferenceGlyphSet, Scale.
// =============================================================================
//
// All Fixed values are 16.16 (Int32 on the wire). xRenderColor is
// 8 bytes (4 × CARD16). Record sizes:
//   xPointFixed  = 8    xLineFixed = 16   xTriangle = 24
//   xTrapezoid   = 40   xSpanFix   = 12   xTrap     = 24
//   xAnimCursorElt = 8

// MARK: - Shared records

public struct RenderPointFixed: Equatable, Sendable {
    public var x: Int32   // 16.16
    public var y: Int32

    public init(x: Int32, y: Int32) { self.x = x; self.y = y }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt32(UInt32(bitPattern: x))
        w.writeUInt32(UInt32(bitPattern: y))
    }

    fileprivate static func read(from r: inout ByteReader) throws -> RenderPointFixed {
        let x = Int32(bitPattern: try r.readUInt32())
        let y = Int32(bitPattern: try r.readUInt32())
        return RenderPointFixed(x: x, y: y)
    }
}

public struct RenderLineFixed: Equatable, Sendable {
    public var p1: RenderPointFixed
    public var p2: RenderPointFixed

    public init(p1: RenderPointFixed, p2: RenderPointFixed) {
        self.p1 = p1; self.p2 = p2
    }

    fileprivate func write(into w: inout ByteWriter) {
        p1.write(into: &w); p2.write(into: &w)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> RenderLineFixed {
        let p1 = try RenderPointFixed.read(from: &r)
        let p2 = try RenderPointFixed.read(from: &r)
        return RenderLineFixed(p1: p1, p2: p2)
    }
}

public struct RenderTriangle: Equatable, Sendable {
    public var p1: RenderPointFixed
    public var p2: RenderPointFixed
    public var p3: RenderPointFixed

    public init(p1: RenderPointFixed, p2: RenderPointFixed, p3: RenderPointFixed) {
        self.p1 = p1; self.p2 = p2; self.p3 = p3
    }
}

public struct RenderTrapezoid: Equatable, Sendable {
    public var top: Int32
    public var bottom: Int32
    public var left: RenderLineFixed
    public var right: RenderLineFixed

    public init(top: Int32, bottom: Int32, left: RenderLineFixed, right: RenderLineFixed) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
}

public struct RenderSpanFix: Equatable, Sendable {
    public var l: Int32
    public var r: Int32
    public var y: Int32

    public init(l: Int32, r: Int32, y: Int32) {
        self.l = l; self.r = r; self.y = y
    }
}

public struct RenderTrap: Equatable, Sendable {
    public var top: RenderSpanFix
    public var bot: RenderSpanFix

    public init(top: RenderSpanFix, bot: RenderSpanFix) {
        self.top = top; self.bot = bot
    }
}

public struct RenderColor: Equatable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16
    public var alpha: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16, alpha: UInt16) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt16(red); w.writeUInt16(green)
        w.writeUInt16(blue); w.writeUInt16(alpha)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> RenderColor {
        let red = try r.readUInt16()
        let green = try r.readUInt16()
        let blue = try r.readUInt16()
        let alpha = try r.readUInt16()
        return RenderColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct RenderAnimCursorElt: Equatable, Sendable {
    public var cursor: UInt32
    public var delay: UInt32

    public init(cursor: UInt32, delay: UInt32) {
        self.cursor = cursor; self.delay = delay
    }
}

// MARK: - Shared 24-byte poly-op prelude

/// Trapezoids/Triangles/TriStrip/TriFan all share the same 24-byte
/// prelude. Caller passes the discriminator + record-encoder closure.
private func encodePolyHeader(majorOpcode: UInt8, minor: UInt8, trailerWords: Int,
                              op: UInt8, src: UInt32, dst: UInt32,
                              maskFormat: UInt32, xSrc: Int16, ySrc: Int16,
                              byteOrder: ByteOrder) -> ByteWriter {
    var w = ByteWriter(byteOrder: byteOrder)
    w.writeUInt8(majorOpcode); w.writeUInt8(minor); w.writeUInt16(UInt16(6 + trailerWords))
    w.writeUInt8(op); w.writePadding(3)
    w.writeUInt32(src); w.writeUInt32(dst)
    w.writeUInt32(maskFormat)
    w.writeUInt16(UInt16(bitPattern: xSrc)); w.writeUInt16(UInt16(bitPattern: ySrc))
    return w
}

private struct PolyHeader {
    let op: UInt8
    let src: UInt32
    let dst: UInt32
    let maskFormat: UInt32
    let xSrc: Int16
    let ySrc: Int16
    let trailerBytes: Int
}

private func decodePolyHeader(reader r: inout ByteReader) throws -> PolyHeader {
    _ = try r.readUInt8(); _ = try r.readUInt8()
    let lenIn4 = Int(try r.readUInt16())
    let op = try r.readUInt8(); try r.skip(3)
    let src = try r.readUInt32()
    let dst = try r.readUInt32()
    let maskFormat = try r.readUInt32()
    let xSrc = Int16(bitPattern: try r.readUInt16())
    let ySrc = Int16(bitPattern: try r.readUInt16())
    return PolyHeader(
        op: op, src: src, dst: dst, maskFormat: maskFormat,
        xSrc: xSrc, ySrc: ySrc,
        trailerBytes: (lenIn4 - 6) * 4
    )
}

// MARK: - RenderScale (minor 9)

public struct RenderScale: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.scale

    public var src: UInt32
    public var dst: UInt32
    public var colorScale: UInt32
    public var alphaScale: UInt32
    public var xSrc: Int16
    public var ySrc: Int16
    public var xDst: Int16
    public var yDst: Int16
    public var width: UInt16
    public var height: UInt16

    public init(src: UInt32, dst: UInt32,
                colorScale: UInt32, alphaScale: UInt32,
                xSrc: Int16, ySrc: Int16,
                xDst: Int16, yDst: Int16,
                width: UInt16, height: UInt16) {
        self.src = src; self.dst = dst
        self.colorScale = colorScale; self.alphaScale = alphaScale
        self.xSrc = xSrc; self.ySrc = ySrc
        self.xDst = xDst; self.yDst = yDst
        self.width = width; self.height = height
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(8)
        w.writeUInt32(src); w.writeUInt32(dst)
        w.writeUInt32(colorScale); w.writeUInt32(alphaScale)
        w.writeUInt16(UInt16(bitPattern: xSrc)); w.writeUInt16(UInt16(bitPattern: ySrc))
        w.writeUInt16(UInt16(bitPattern: xDst)); w.writeUInt16(UInt16(bitPattern: yDst))
        w.writeUInt16(width); w.writeUInt16(height)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderScale {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let src = try r.readUInt32()
        let dst = try r.readUInt32()
        let colorScale = try r.readUInt32()
        let alphaScale = try r.readUInt32()
        let xSrc = Int16(bitPattern: try r.readUInt16())
        let ySrc = Int16(bitPattern: try r.readUInt16())
        let xDst = Int16(bitPattern: try r.readUInt16())
        let yDst = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        return RenderScale(
            src: src, dst: dst,
            colorScale: colorScale, alphaScale: alphaScale,
            xSrc: xSrc, ySrc: ySrc,
            xDst: xDst, yDst: yDst,
            width: width, height: height
        )
    }
}

// MARK: - RenderTrapezoids (minor 10)

public struct RenderTrapezoids: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.trapezoids

    public var op: UInt8
    public var src: UInt32
    public var dst: UInt32
    public var maskFormat: UInt32
    public var xSrc: Int16
    public var ySrc: Int16
    public var trapezoids: [RenderTrapezoid]   // 40 bytes each = 10 words

    public init(op: UInt8, src: UInt32, dst: UInt32, maskFormat: UInt32,
                xSrc: Int16, ySrc: Int16, trapezoids: [RenderTrapezoid]) {
        self.op = op; self.src = src; self.dst = dst
        self.maskFormat = maskFormat
        self.xSrc = xSrc; self.ySrc = ySrc
        self.trapezoids = trapezoids
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = encodePolyHeader(
            majorOpcode: majorOpcode, minor: Self.minor,
            trailerWords: trapezoids.count * 10,
            op: op, src: src, dst: dst, maskFormat: maskFormat,
            xSrc: xSrc, ySrc: ySrc, byteOrder: byteOrder
        )
        for t in trapezoids {
            w.writeUInt32(UInt32(bitPattern: t.top))
            w.writeUInt32(UInt32(bitPattern: t.bottom))
            t.left.write(into: &w)
            t.right.write(into: &w)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderTrapezoids {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let h = try decodePolyHeader(reader: &r)
        let n = h.trailerBytes / 40
        var traps: [RenderTrapezoid] = []
        traps.reserveCapacity(n)
        for _ in 0..<n {
            let top = Int32(bitPattern: try r.readUInt32())
            let bottom = Int32(bitPattern: try r.readUInt32())
            let left = try RenderLineFixed.read(from: &r)
            let right = try RenderLineFixed.read(from: &r)
            traps.append(RenderTrapezoid(top: top, bottom: bottom, left: left, right: right))
        }
        return RenderTrapezoids(
            op: h.op, src: h.src, dst: h.dst, maskFormat: h.maskFormat,
            xSrc: h.xSrc, ySrc: h.ySrc, trapezoids: traps
        )
    }
}

// MARK: - RenderTriangles (minor 11)

public struct RenderTriangles: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.triangles

    public var op: UInt8
    public var src: UInt32
    public var dst: UInt32
    public var maskFormat: UInt32
    public var xSrc: Int16
    public var ySrc: Int16
    public var triangles: [RenderTriangle]   // 24 bytes each = 6 words

    public init(op: UInt8, src: UInt32, dst: UInt32, maskFormat: UInt32,
                xSrc: Int16, ySrc: Int16, triangles: [RenderTriangle]) {
        self.op = op; self.src = src; self.dst = dst
        self.maskFormat = maskFormat
        self.xSrc = xSrc; self.ySrc = ySrc
        self.triangles = triangles
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = encodePolyHeader(
            majorOpcode: majorOpcode, minor: Self.minor,
            trailerWords: triangles.count * 6,
            op: op, src: src, dst: dst, maskFormat: maskFormat,
            xSrc: xSrc, ySrc: ySrc, byteOrder: byteOrder
        )
        for t in triangles {
            t.p1.write(into: &w); t.p2.write(into: &w); t.p3.write(into: &w)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderTriangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let h = try decodePolyHeader(reader: &r)
        let n = h.trailerBytes / 24
        var tris: [RenderTriangle] = []
        tris.reserveCapacity(n)
        for _ in 0..<n {
            let p1 = try RenderPointFixed.read(from: &r)
            let p2 = try RenderPointFixed.read(from: &r)
            let p3 = try RenderPointFixed.read(from: &r)
            tris.append(RenderTriangle(p1: p1, p2: p2, p3: p3))
        }
        return RenderTriangles(
            op: h.op, src: h.src, dst: h.dst, maskFormat: h.maskFormat,
            xSrc: h.xSrc, ySrc: h.ySrc, triangles: tris
        )
    }
}

// MARK: - RenderTriStrip (minor 12) / RenderTriFan (minor 13)

private func decodeFixedPoints(_ bytes: Int, reader r: inout ByteReader) throws -> [RenderPointFixed] {
    let n = bytes / 8
    var points: [RenderPointFixed] = []
    points.reserveCapacity(n)
    for _ in 0..<n { points.append(try RenderPointFixed.read(from: &r)) }
    return points
}

public struct RenderTriStrip: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.triStrip

    public var op: UInt8
    public var src: UInt32
    public var dst: UInt32
    public var maskFormat: UInt32
    public var xSrc: Int16
    public var ySrc: Int16
    public var points: [RenderPointFixed]   // 8 bytes each = 2 words

    public init(op: UInt8, src: UInt32, dst: UInt32, maskFormat: UInt32,
                xSrc: Int16, ySrc: Int16, points: [RenderPointFixed]) {
        self.op = op; self.src = src; self.dst = dst
        self.maskFormat = maskFormat
        self.xSrc = xSrc; self.ySrc = ySrc
        self.points = points
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = encodePolyHeader(
            majorOpcode: majorOpcode, minor: Self.minor,
            trailerWords: points.count * 2,
            op: op, src: src, dst: dst, maskFormat: maskFormat,
            xSrc: xSrc, ySrc: ySrc, byteOrder: byteOrder
        )
        for p in points { p.write(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderTriStrip {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let h = try decodePolyHeader(reader: &r)
        let pts = try decodeFixedPoints(h.trailerBytes, reader: &r)
        return RenderTriStrip(
            op: h.op, src: h.src, dst: h.dst, maskFormat: h.maskFormat,
            xSrc: h.xSrc, ySrc: h.ySrc, points: pts
        )
    }
}

public struct RenderTriFan: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.triFan

    public var op: UInt8
    public var src: UInt32
    public var dst: UInt32
    public var maskFormat: UInt32
    public var xSrc: Int16
    public var ySrc: Int16
    public var points: [RenderPointFixed]

    public init(op: UInt8, src: UInt32, dst: UInt32, maskFormat: UInt32,
                xSrc: Int16, ySrc: Int16, points: [RenderPointFixed]) {
        self.op = op; self.src = src; self.dst = dst
        self.maskFormat = maskFormat
        self.xSrc = xSrc; self.ySrc = ySrc
        self.points = points
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = encodePolyHeader(
            majorOpcode: majorOpcode, minor: Self.minor,
            trailerWords: points.count * 2,
            op: op, src: src, dst: dst, maskFormat: maskFormat,
            xSrc: xSrc, ySrc: ySrc, byteOrder: byteOrder
        )
        for p in points { p.write(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderTriFan {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let h = try decodePolyHeader(reader: &r)
        let pts = try decodeFixedPoints(h.trailerBytes, reader: &r)
        return RenderTriFan(
            op: h.op, src: h.src, dst: h.dst, maskFormat: h.maskFormat,
            xSrc: h.xSrc, ySrc: h.ySrc, points: pts
        )
    }
}

// MARK: - RenderReferenceGlyphSet (minor 18)

public struct RenderReferenceGlyphSet: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.referenceGlyphSet
    public var gsid: UInt32
    public var existing: UInt32

    public init(gsid: UInt32, existing: UInt32) {
        self.gsid = gsid; self.existing = existing
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        // sz_xRenderReferenceGlyphSetReq is misdefined as 24 in
        // renderproto.h but the struct is actually 12 bytes
        // (header(4) + gsid(4) + existing(4)). Trust the struct.
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(3)
        w.writeUInt32(gsid); w.writeUInt32(existing)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderReferenceGlyphSet {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let gsid = try r.readUInt32()
        let existing = try r.readUInt32()
        return RenderReferenceGlyphSet(gsid: gsid, existing: existing)
    }
}

// MARK: - RenderFillRectangles (minor 26)

public struct RenderFillRectangles: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.fillRectangles

    public var op: UInt8
    public var dst: UInt32
    public var color: RenderColor
    public var rectangles: [Rectangle]   // 8 bytes each = 2 words

    public init(op: UInt8, dst: UInt32, color: RenderColor, rectangles: [Rectangle]) {
        self.op = op; self.dst = dst
        self.color = color; self.rectangles = rectangles
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(5 + rectangles.count * 2)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt8(op); w.writePadding(3)
        w.writeUInt32(dst)
        color.write(into: &w)
        for rect in rectangles {
            w.writeUInt16(UInt16(bitPattern: rect.x))
            w.writeUInt16(UInt16(bitPattern: rect.y))
            w.writeUInt16(rect.width)
            w.writeUInt16(rect.height)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderFillRectangles {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let op = try r.readUInt8(); try r.skip(3)
        let dst = try r.readUInt32()
        let color = try RenderColor.read(from: &r)
        let nRects = (lenIn4 - 5) / 2
        var rects: [Rectangle] = []
        rects.reserveCapacity(nRects)
        for _ in 0..<nRects {
            let x = Int16(bitPattern: try r.readUInt16())
            let y = Int16(bitPattern: try r.readUInt16())
            let w = try r.readUInt16()
            let h = try r.readUInt16()
            rects.append(Rectangle(x: x, y: y, width: w, height: h))
        }
        return RenderFillRectangles(
            op: op, dst: dst, color: color, rectangles: rects
        )
    }
}

// MARK: - RenderCreateCursor (minor 27)

public struct RenderCreateCursor: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createCursor

    public var cid: UInt32
    public var src: UInt32
    public var x: UInt16
    public var y: UInt16

    public init(cid: UInt32, src: UInt32, x: UInt16, y: UInt16) {
        self.cid = cid; self.src = src; self.x = x; self.y = y
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(cid); w.writeUInt32(src)
        w.writeUInt16(x); w.writeUInt16(y)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateCursor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let cid = try r.readUInt32()
        let src = try r.readUInt32()
        let x = try r.readUInt16()
        let y = try r.readUInt16()
        return RenderCreateCursor(cid: cid, src: src, x: x, y: y)
    }
}

// MARK: - RenderSetPictureFilter (minor 30)

/// 12-byte header (picture + nbytes + pad) + name STRING bytes
/// (padded to 4) + LISTofFIXED params (CARD32 each).
public struct RenderSetPictureFilter: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.setPictureFilter

    public var picture: UInt32
    public var name: String
    public var values: [Int32]   // 16.16 Fixed

    public init(picture: UInt32, name: String, values: [Int32]) {
        self.picture = picture; self.name = name; self.values = values
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let np = xPad(nameBytes.count)
        // Name trailer = name + pad. Params = 4 bytes each.
        let lenIn4 = UInt16(3 + (nameBytes.count + np) / 4 + values.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(picture)
        w.writeUInt16(UInt16(nameBytes.count)); w.writePadding(2)
        w.writeBytes(nameBytes)
        w.writePadding(np)
        for v in values { w.writeUInt32(UInt32(bitPattern: v)) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderSetPictureFilter {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let picture = try r.readUInt32()
        let nbytes = Int(try r.readUInt16()); try r.skip(2)
        let raw = try r.readBytes(nbytes)
        try r.skip(xPad(nbytes))
        let nameTrailerWords = (nbytes + xPad(nbytes)) / 4
        let paramWords = lenIn4 - 3 - nameTrailerWords
        var values: [Int32] = []
        values.reserveCapacity(paramWords)
        for _ in 0..<paramWords {
            values.append(Int32(bitPattern: try r.readUInt32()))
        }
        return RenderSetPictureFilter(
            picture: picture,
            name: String(decoding: raw, as: UTF8.self),
            values: values
        )
    }
}

// MARK: - RenderCreateAnimCursor (minor 31)

public struct RenderCreateAnimCursor: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createAnimCursor

    public var cid: UInt32
    public var elts: [RenderAnimCursorElt]   // 8 bytes each = 2 words

    public init(cid: UInt32, elts: [RenderAnimCursorElt]) {
        self.cid = cid; self.elts = elts
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(2 + elts.count * 2)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(cid)
        for e in elts {
            w.writeUInt32(e.cursor); w.writeUInt32(e.delay)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateAnimCursor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let cid = try r.readUInt32()
        let n = (lenIn4 - 2) / 2
        var elts: [RenderAnimCursorElt] = []
        elts.reserveCapacity(n)
        for _ in 0..<n {
            let cursor = try r.readUInt32()
            let delay = try r.readUInt32()
            elts.append(RenderAnimCursorElt(cursor: cursor, delay: delay))
        }
        return RenderCreateAnimCursor(cid: cid, elts: elts)
    }
}

// MARK: - RenderAddTraps (minor 32)

public struct RenderAddTraps: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.addTraps

    public var picture: UInt32
    public var xOff: Int16
    public var yOff: Int16
    public var traps: [RenderTrap]   // 24 bytes each = 6 words

    public init(picture: UInt32, xOff: Int16, yOff: Int16, traps: [RenderTrap]) {
        self.picture = picture
        self.xOff = xOff; self.yOff = yOff
        self.traps = traps
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + traps.count * 6)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(picture)
        w.writeUInt16(UInt16(bitPattern: xOff)); w.writeUInt16(UInt16(bitPattern: yOff))
        for t in traps {
            for span in [t.top, t.bot] {
                w.writeUInt32(UInt32(bitPattern: span.l))
                w.writeUInt32(UInt32(bitPattern: span.r))
                w.writeUInt32(UInt32(bitPattern: span.y))
            }
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderAddTraps {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let picture = try r.readUInt32()
        let xOff = Int16(bitPattern: try r.readUInt16())
        let yOff = Int16(bitPattern: try r.readUInt16())
        let n = (lenIn4 - 3) / 6
        var traps: [RenderTrap] = []
        traps.reserveCapacity(n)
        for _ in 0..<n {
            let topL = Int32(bitPattern: try r.readUInt32())
            let topR = Int32(bitPattern: try r.readUInt32())
            let topY = Int32(bitPattern: try r.readUInt32())
            let botL = Int32(bitPattern: try r.readUInt32())
            let botR = Int32(bitPattern: try r.readUInt32())
            let botY = Int32(bitPattern: try r.readUInt32())
            traps.append(RenderTrap(
                top: RenderSpanFix(l: topL, r: topR, y: topY),
                bot: RenderSpanFix(l: botL, r: botR, y: botY)
            ))
        }
        return RenderAddTraps(
            picture: picture, xOff: xOff, yOff: yOff, traps: traps
        )
    }
}

// MARK: - RenderCreateSolidFill (minor 33)

public struct RenderCreateSolidFill: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createSolidFill

    public var pid: UInt32
    public var color: RenderColor

    public init(pid: UInt32, color: RenderColor) {
        self.pid = pid; self.color = color
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(pid)
        color.write(into: &w)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateSolidFill {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let color = try RenderColor.read(from: &r)
        return RenderCreateSolidFill(pid: pid, color: color)
    }
}

// MARK: - Gradient trailer codec (shared by linear/radial/conical)

/// Trailing payload of any gradient create: `nStops × Fixed stops`
/// followed by `nStops × xRenderColor`. (Stops are positions in [0,1]
/// expressed as 16.16 fixed; colors are the gradient ramp.)
private func encodeGradientStops(stops: [Int32], colors: [RenderColor], into w: inout ByteWriter) {
    precondition(stops.count == colors.count, "stops and colors must have equal length")
    for s in stops { w.writeUInt32(UInt32(bitPattern: s)) }
    for c in colors { c.write(into: &w) }
}

private func decodeGradientStops(nStops: Int, from r: inout ByteReader) throws -> ([Int32], [RenderColor]) {
    var stops: [Int32] = []; stops.reserveCapacity(nStops)
    for _ in 0..<nStops { stops.append(Int32(bitPattern: try r.readUInt32())) }
    var colors: [RenderColor] = []; colors.reserveCapacity(nStops)
    for _ in 0..<nStops { colors.append(try RenderColor.read(from: &r)) }
    return (stops, colors)
}

// MARK: - RenderCreateLinearGradient (minor 34)

public struct RenderCreateLinearGradient: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createLinearGradient

    public var pid: UInt32
    public var p1: RenderPointFixed
    public var p2: RenderPointFixed
    public var stops: [Int32]
    public var colors: [RenderColor]

    public init(pid: UInt32, p1: RenderPointFixed, p2: RenderPointFixed,
                stops: [Int32], colors: [RenderColor]) {
        precondition(stops.count == colors.count, "stops and colors must have equal length")
        self.pid = pid; self.p1 = p1; self.p2 = p2
        self.stops = stops; self.colors = colors
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        // Header(4) + pid(4) + p1(8) + p2(8) + nStops(4) = 28 bytes = 7 words
        // Trailer = nStops × (4 + 8) bytes = nStops × 3 words
        let lenIn4 = UInt16(7 + stops.count * 3)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(pid)
        p1.write(into: &w); p2.write(into: &w)
        w.writeUInt32(UInt32(stops.count))
        encodeGradientStops(stops: stops, colors: colors, into: &w)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateLinearGradient {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let p1 = try RenderPointFixed.read(from: &r)
        let p2 = try RenderPointFixed.read(from: &r)
        let n = Int(try r.readUInt32())
        let (stops, colors) = try decodeGradientStops(nStops: n, from: &r)
        return RenderCreateLinearGradient(pid: pid, p1: p1, p2: p2, stops: stops, colors: colors)
    }
}

// MARK: - RenderCreateRadialGradient (minor 35)

public struct RenderCreateRadialGradient: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createRadialGradient

    public var pid: UInt32
    public var inner: RenderPointFixed
    public var outer: RenderPointFixed
    public var innerRadius: Int32   // Fixed
    public var outerRadius: Int32
    public var stops: [Int32]
    public var colors: [RenderColor]

    public init(pid: UInt32, inner: RenderPointFixed, outer: RenderPointFixed,
                innerRadius: Int32, outerRadius: Int32,
                stops: [Int32], colors: [RenderColor]) {
        precondition(stops.count == colors.count, "stops and colors must have equal length")
        self.pid = pid; self.inner = inner; self.outer = outer
        self.innerRadius = innerRadius; self.outerRadius = outerRadius
        self.stops = stops; self.colors = colors
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        // Header(4) + pid(4) + inner(8) + outer(8) + innerR(4) + outerR(4) + nStops(4) = 36 bytes = 9 words
        let lenIn4 = UInt16(9 + stops.count * 3)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(pid)
        inner.write(into: &w); outer.write(into: &w)
        w.writeUInt32(UInt32(bitPattern: innerRadius))
        w.writeUInt32(UInt32(bitPattern: outerRadius))
        w.writeUInt32(UInt32(stops.count))
        encodeGradientStops(stops: stops, colors: colors, into: &w)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateRadialGradient {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let inner = try RenderPointFixed.read(from: &r)
        let outer = try RenderPointFixed.read(from: &r)
        let innerR = Int32(bitPattern: try r.readUInt32())
        let outerR = Int32(bitPattern: try r.readUInt32())
        let n = Int(try r.readUInt32())
        let (stops, colors) = try decodeGradientStops(nStops: n, from: &r)
        return RenderCreateRadialGradient(
            pid: pid, inner: inner, outer: outer,
            innerRadius: innerR, outerRadius: outerR,
            stops: stops, colors: colors
        )
    }
}

// MARK: - RenderCreateConicalGradient (minor 36)

public struct RenderCreateConicalGradient: Equatable, Sendable {
    public static let minor: UInt8 = RenderMinor.createConicalGradient

    public var pid: UInt32
    public var center: RenderPointFixed
    public var angle: Int32   // Fixed, in degrees
    public var stops: [Int32]
    public var colors: [RenderColor]

    public init(pid: UInt32, center: RenderPointFixed, angle: Int32,
                stops: [Int32], colors: [RenderColor]) {
        precondition(stops.count == colors.count, "stops and colors must have equal length")
        self.pid = pid; self.center = center; self.angle = angle
        self.stops = stops; self.colors = colors
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        // Header(4) + pid(4) + center(8) + angle(4) + nStops(4) = 24 bytes = 6 words
        let lenIn4 = UInt16(6 + stops.count * 3)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(lenIn4)
        w.writeUInt32(pid)
        center.write(into: &w)
        w.writeUInt32(UInt32(bitPattern: angle))
        w.writeUInt32(UInt32(stops.count))
        encodeGradientStops(stops: stops, colors: colors, into: &w)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderCreateConicalGradient {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let center = try RenderPointFixed.read(from: &r)
        let angle = Int32(bitPattern: try r.readUInt32())
        let n = Int(try r.readUInt32())
        let (stops, colors) = try decodeGradientStops(nStops: n, from: &r)
        return RenderCreateConicalGradient(
            pid: pid, center: center, angle: angle,
            stops: stops, colors: colors
        )
    }
}
