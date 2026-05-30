// RENDER extension Tier-A reply wire types.
//
// Phase 3 RENDER Session 1 (2026-05-30). Lands QueryVersion reply
// (trivial) and QueryPictFormats reply (the biggest reply walker in
// the extension). Other replies (QueryPictIndexValues, QueryFilters)
// land in later sessions alongside their requests.
//
// Wire layouts from
// reference/xproto/include/X11/extensions/renderproto.h.

// MARK: - QueryVersion reply

public struct RenderQueryVersionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var majorVersion: UInt32
    public var minorVersion: UInt32

    public init(sequenceNumber: UInt16, majorVersion: UInt32, minorVersion: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(majorVersion)
        w.writeUInt32(minorVersion)
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryVersionReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let major = try r.readUInt32()
        let minor = try r.readUInt32()
        return RenderQueryVersionReply(
            sequenceNumber: seq, majorVersion: major, minorVersion: minor
        )
    }
}

// MARK: - QueryPictFormats reply types

/// PictFormat "direct" sub-record. Each color channel has a shift + mask
/// describing where the channel sits within a depth N pixel.
public struct RenderDirectFormat: Equatable, Sendable {
    public var red: UInt16
    public var redMask: UInt16
    public var green: UInt16
    public var greenMask: UInt16
    public var blue: UInt16
    public var blueMask: UInt16
    public var alpha: UInt16
    public var alphaMask: UInt16

    public init(red: UInt16, redMask: UInt16,
                green: UInt16, greenMask: UInt16,
                blue: UInt16, blueMask: UInt16,
                alpha: UInt16, alphaMask: UInt16) {
        self.red = red; self.redMask = redMask
        self.green = green; self.greenMask = greenMask
        self.blue = blue; self.blueMask = blueMask
        self.alpha = alpha; self.alphaMask = alphaMask
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt16(red); w.writeUInt16(redMask)
        w.writeUInt16(green); w.writeUInt16(greenMask)
        w.writeUInt16(blue); w.writeUInt16(blueMask)
        w.writeUInt16(alpha); w.writeUInt16(alphaMask)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> RenderDirectFormat {
        let red = try r.readUInt16(); let redMask = try r.readUInt16()
        let green = try r.readUInt16(); let greenMask = try r.readUInt16()
        let blue = try r.readUInt16(); let blueMask = try r.readUInt16()
        let alpha = try r.readUInt16(); let alphaMask = try r.readUInt16()
        return RenderDirectFormat(
            red: red, redMask: redMask,
            green: green, greenMask: greenMask,
            blue: blue, blueMask: blueMask,
            alpha: alpha, alphaMask: alphaMask
        )
    }
}

/// xPictFormInfo: id + type (PictTypeIndexed=0 or PictTypeDirect=1) +
/// depth + direct format + colormap. 28 bytes on the wire.
public struct RenderPictFormatInfo: Equatable, Sendable {
    public var id: UInt32         // PictFormat
    public var type: UInt8        // 0=Indexed, 1=Direct
    public var depth: UInt8
    public var direct: RenderDirectFormat
    public var colormap: UInt32

    public init(id: UInt32, type: UInt8, depth: UInt8,
                direct: RenderDirectFormat, colormap: UInt32) {
        self.id = id; self.type = type; self.depth = depth
        self.direct = direct; self.colormap = colormap
    }

    fileprivate func write(into w: inout ByteWriter) {
        w.writeUInt32(id)
        w.writeUInt8(type); w.writeUInt8(depth); w.writePadding(2)
        direct.write(into: &w)
        w.writeUInt32(colormap)
    }

    fileprivate static func read(from r: inout ByteReader) throws -> RenderPictFormatInfo {
        let id = try r.readUInt32()
        let type = try r.readUInt8()
        let depth = try r.readUInt8()
        try r.skip(2)
        let direct = try RenderDirectFormat.read(from: &r)
        let colormap = try r.readUInt32()
        return RenderPictFormatInfo(
            id: id, type: type, depth: depth,
            direct: direct, colormap: colormap
        )
    }
}

/// One (VisualID, PictFormat) pair within a depth. 8 bytes.
public struct RenderPictVisual: Equatable, Sendable {
    public var visual: UInt32
    public var format: UInt32

    public init(visual: UInt32, format: UInt32) {
        self.visual = visual; self.format = format
    }
}

/// One depth's worth of visual→PictFormat mappings.
/// 8-byte header (depth + pad + nPictVisuals + pad) + nPictVisuals × 8.
public struct RenderPictDepth: Equatable, Sendable {
    public var depth: UInt8
    public var visuals: [RenderPictVisual]   // nPictVisuals = visuals.count

    public init(depth: UInt8, visuals: [RenderPictVisual]) {
        self.depth = depth; self.visuals = visuals
    }
}

/// One screen's worth of depths.
/// 8-byte header (nDepths + fallback PictFormat) + nDepths × variable-
/// length xPictDepth records. nDepths is per-screen even though
/// QueryPictFormatsReply.numDepths is the total across all screens.
public struct RenderPictScreen: Equatable, Sendable {
    public var depths: [RenderPictDepth]
    public var fallback: UInt32   // PictFormat — server's pick when client doesn't specify

    public init(depths: [RenderPictDepth], fallback: UInt32) {
        self.depths = depths; self.fallback = fallback
    }
}

// MARK: - QueryPictFormats reply

/// 32-byte header + the nested formats/screens/subpixel trailer.
public struct RenderQueryPictFormatsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var formats: [RenderPictFormatInfo]
    public var screens: [RenderPictScreen]
    /// One per-screen subpixel-order CARD32 — server fills with values
    /// like SubPixelHorizontalRGB(1) / Unknown(0). The reply-level
    /// `numSubpixel` was added in RENDER 0.6; older servers omit it.
    /// We always emit it.
    public var subpixels: [UInt32]

    public init(sequenceNumber: UInt16,
                formats: [RenderPictFormatInfo],
                screens: [RenderPictScreen],
                subpixels: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.formats = formats
        self.screens = screens
        self.subpixels = subpixels
    }

    /// Total xPictDepth records across every screen. Used in the header
    /// `numDepths` field. (Per-screen `nDepths` lives inside each
    /// xPictScreen — the header value is the sum.)
    private var totalDepths: UInt32 {
        UInt32(screens.reduce(0) { $0 + $1.depths.count })
    }

    /// Total xPictVisual records across every depth across every screen.
    private var totalVisuals: UInt32 {
        UInt32(screens.reduce(0) { acc, scr in
            acc + scr.depths.reduce(0) { acc2, d in acc2 + d.visuals.count }
        })
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        // Build trailer first so we know lengths.
        var t = ByteWriter(byteOrder: byteOrder)
        // 1) Formats
        for f in formats { f.write(into: &t) }
        // 2) Screens (variable per record)
        for scr in screens {
            t.writeUInt32(UInt32(scr.depths.count))
            t.writeUInt32(scr.fallback)
            for d in scr.depths {
                t.writeUInt8(d.depth); t.writePadding(1)
                t.writeUInt16(UInt16(d.visuals.count))
                t.writePadding(4)
                for v in d.visuals {
                    t.writeUInt32(v.visual); t.writeUInt32(v.format)
                }
            }
        }
        // 3) Subpixels (4 bytes each)
        for s in subpixels { t.writeUInt32(s) }

        let trailer = t.bytes
        let lenIn4 = UInt32(trailer.count / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(UInt32(formats.count))
        w.writeUInt32(UInt32(screens.count))
        w.writeUInt32(totalDepths)
        w.writeUInt32(totalVisuals)
        w.writeUInt32(UInt32(subpixels.count))
        w.writeUInt32(0)   // pad5
        w.writeBytes(trailer)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryPictFormatsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let numFormats = Int(try r.readUInt32())
        let numScreens = Int(try r.readUInt32())
        _ = try r.readUInt32()   // numDepths (total; we recompute from screens)
        _ = try r.readUInt32()   // numVisuals (total; we recompute from screens)
        let numSubpixel = Int(try r.readUInt32())
        _ = try r.readUInt32()   // pad5

        // 1) Formats
        var formats: [RenderPictFormatInfo] = []
        formats.reserveCapacity(numFormats)
        for _ in 0..<numFormats {
            formats.append(try RenderPictFormatInfo.read(from: &r))
        }

        // 2) Screens — each carries its own nDepths
        var screens: [RenderPictScreen] = []
        screens.reserveCapacity(numScreens)
        for _ in 0..<numScreens {
            let nDepths = Int(try r.readUInt32())
            let fallback = try r.readUInt32()
            var depths: [RenderPictDepth] = []
            depths.reserveCapacity(nDepths)
            for _ in 0..<nDepths {
                let depth = try r.readUInt8()
                try r.skip(1)
                let nVisuals = Int(try r.readUInt16())
                try r.skip(4)
                var visuals: [RenderPictVisual] = []
                visuals.reserveCapacity(nVisuals)
                for _ in 0..<nVisuals {
                    let v = try r.readUInt32()
                    let f = try r.readUInt32()
                    visuals.append(RenderPictVisual(visual: v, format: f))
                }
                depths.append(RenderPictDepth(depth: depth, visuals: visuals))
            }
            screens.append(RenderPictScreen(depths: depths, fallback: fallback))
        }

        // 3) Subpixels
        var subpixels: [UInt32] = []
        subpixels.reserveCapacity(numSubpixel)
        for _ in 0..<numSubpixel { subpixels.append(try r.readUInt32()) }

        return RenderQueryPictFormatsReply(
            sequenceNumber: seq,
            formats: formats, screens: screens, subpixels: subpixels
        )
    }
}

// =============================================================================
// Session 2 (2026-05-30): QueryPictIndexValues + QueryFilters replies.
// =============================================================================

// MARK: - QueryPictIndexValues reply

/// 32-byte header + numIndexValues × xIndexValue (12 bytes each).
public struct RenderIndexValue: Equatable, Sendable {
    public var pixel: UInt32
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16
    public var alpha: UInt16

    public init(pixel: UInt32, red: UInt16, green: UInt16, blue: UInt16, alpha: UInt16) {
        self.pixel = pixel
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public struct RenderQueryPictIndexValuesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var values: [RenderIndexValue]

    public init(sequenceNumber: UInt16, values: [RenderIndexValue]) {
        self.sequenceNumber = sequenceNumber; self.values = values
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let trailerBytes = values.count * 12
        // 4-byte alignment is guaranteed (12 is divisible by 4).
        let lenIn4 = UInt32(trailerBytes / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(UInt32(values.count))
        w.writePadding(20)
        for v in values {
            w.writeUInt32(v.pixel)
            w.writeUInt16(v.red); w.writeUInt16(v.green)
            w.writeUInt16(v.blue); w.writeUInt16(v.alpha)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryPictIndexValuesReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = Int(try r.readUInt32())
        try r.skip(20)
        var values: [RenderIndexValue] = []
        values.reserveCapacity(n)
        for _ in 0..<n {
            let pixel = try r.readUInt32()
            let red = try r.readUInt16()
            let green = try r.readUInt16()
            let blue = try r.readUInt16()
            let alpha = try r.readUInt16()
            values.append(RenderIndexValue(
                pixel: pixel, red: red, green: green, blue: blue, alpha: alpha
            ))
        }
        return RenderQueryPictIndexValuesReply(sequenceNumber: seq, values: values)
    }
}

// MARK: - QueryFilters reply

/// 32-byte header + numAliases × CARD16 (padded to 4) +
/// numFilters × STRING8 (length-prefixed bytes, packed without per-
/// string padding; tail padded to 4).
public struct RenderQueryFiltersReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var aliases: [UInt16]
    public var filters: [String]

    public init(sequenceNumber: UInt16, aliases: [UInt16], filters: [String]) {
        self.sequenceNumber = sequenceNumber
        self.aliases = aliases
        self.filters = filters
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        // Compute trailer length.
        var trailer = ByteWriter(byteOrder: byteOrder)
        for a in aliases { trailer.writeUInt16(a) }
        trailer.writePadding(xPad(aliases.count * 2))
        var nameBytes = 0
        for s in filters {
            let bytes = Array(s.utf8)
            precondition(bytes.count <= 255, "filter name must fit in one length byte")
            trailer.writeUInt8(UInt8(bytes.count))
            trailer.writeBytes(bytes)
            nameBytes += 1 + bytes.count
        }
        trailer.writePadding(xPad(nameBytes))

        let trailerBytes = trailer.bytes
        let lenIn4 = UInt32(trailerBytes.count / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt32(UInt32(aliases.count))
        w.writeUInt32(UInt32(filters.count))
        w.writePadding(16)
        w.writeBytes(trailerBytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> RenderQueryFiltersReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let numAliases = Int(try r.readUInt32())
        let numFilters = Int(try r.readUInt32())
        try r.skip(16)
        var aliases: [UInt16] = []
        aliases.reserveCapacity(numAliases)
        for _ in 0..<numAliases { aliases.append(try r.readUInt16()) }
        try r.skip(xPad(numAliases * 2))
        var filters: [String] = []
        filters.reserveCapacity(numFilters)
        for _ in 0..<numFilters {
            let len = Int(try r.readUInt8())
            let raw = try r.readBytes(len)
            filters.append(String(decoding: raw, as: UTF8.self))
        }
        return RenderQueryFiltersReply(
            sequenceNumber: seq, aliases: aliases, filters: filters
        )
    }
}
