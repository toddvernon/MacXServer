// RENDER glyph-payload codec for CompositeGlyphs8/16/32 and AddGlyphs.
//
// Phase 3 RENDER Session 2 (2026-05-30). These two trailers are the
// highest-risk decoding pieces in the extension. CompositeGlyphs runs
// per-glyph-cluster — any Pango-heavy capture contains thousands of
// them, and a misaligned walker trashes every subsequent op in the
// batch.
//
// Wire layout verified against
//   reference/xproto/include/X11/extensions/renderproto.h
//   reference/xproto/renderproto.txt
//   reference/xquartz-xserver/render/render.c   (lines 1280-1360 —
//     the server-side decoder, used to confirm the 0xFF sentinel)

// MARK: - GLYPHITEM walker (CompositeGlyphs8/16/32 trailer)

/// One element in a CompositeGlyphs glyph stream.
///
/// On the wire each element is:
///   - 8-byte xGlyphElt header (len + 3 pad + deltax + deltay)
///   - Either `len == 0xFF`: 4 trailing bytes interpreted as a new
///     GlyphSet ID (the dy/dx fields are unused for switches but we
///     preserve them so a round-trip is byte-identical), OR
///   - `len` glyph IDs at the variant-specific size (1/2/4 bytes),
///     followed by padding to 4-byte alignment within the elt.
///
/// The dumper carries the raw deltax/deltay since they're applied to
/// the glyph origin regardless of whether the elt was a switch.
public enum RenderGlyphElt: Equatable, Sendable {
    /// Draw `glyphIDs.count` glyphs at the current origin, shifted by
    /// (deltax, deltay). Subsequent glyph IDs in this elt are the
    /// variant-specific size.
    case draw(deltax: Int16, deltay: Int16, glyphIDs: [UInt32])
    /// Switch the active glyphset to `glyphset` for subsequent elts.
    /// The deltax/deltay are usually 0 but we preserve whatever was
    /// on the wire.
    case glyphsetSwitch(deltax: Int16, deltay: Int16, glyphset: UInt32)
}

/// Discriminator for the three CompositeGlyphs variants. Each picks a
/// different glyph-ID size in the trailer.
public enum RenderGlyphIdSize: Equatable, Sendable {
    case bits8
    case bits16
    case bits32

    public var bytes: Int {
        switch self { case .bits8: return 1; case .bits16: return 2; case .bits32: return 4 }
    }
}

/// Codec for a list of GLYPHITEM records. Caller passes the trailer
/// bytes plus the variant; the codec walks until exhausted.
public enum RenderGlyphStream {

    public static func encode(_ elts: [RenderGlyphElt],
                              idSize: RenderGlyphIdSize,
                              byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        let size = idSize.bytes
        for elt in elts {
            switch elt {
            case .glyphsetSwitch(let dx, let dy, let gs):
                // 8-byte header with len=0xFF, then 4-byte glyphset.
                w.writeUInt8(0xFF); w.writePadding(3)
                w.writeUInt16(UInt16(bitPattern: dx)); w.writeUInt16(UInt16(bitPattern: dy))
                w.writeUInt32(gs)
            case .draw(let dx, let dy, let ids):
                let n = ids.count
                precondition(n < 0xFF, "len must be < 0xFF; use a separate glyphsetSwitch for 0xFF")
                w.writeUInt8(UInt8(n)); w.writePadding(3)
                w.writeUInt16(UInt16(bitPattern: dx)); w.writeUInt16(UInt16(bitPattern: dy))
                switch idSize {
                case .bits8:
                    for id in ids { w.writeUInt8(UInt8(truncatingIfNeeded: id)) }
                case .bits16:
                    for id in ids { w.writeUInt16(UInt16(truncatingIfNeeded: id)) }
                case .bits32:
                    for id in ids { w.writeUInt32(id) }
                }
                // Per-elt pad to 4-byte boundary. 32-bit IDs are
                // naturally aligned (always 0 pad); 8-bit pads up by
                // (4 - n%4) % 4; 16-bit pads by (4 - (n*2)%4) % 4.
                let dataBytes = n * size
                w.writePadding(xPad(dataBytes))
            }
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8],
                              idSize: RenderGlyphIdSize,
                              byteOrder: ByteOrder) throws -> [RenderGlyphElt] {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var elts: [RenderGlyphElt] = []
        let size = idSize.bytes
        // Walk until fewer than 8 bytes remain (one elt header is the
        // minimum). The server-side decoder uses the same heuristic:
        //   while (buffer + sizeof(xGlyphElt) < end) { ... }
        while r.remaining >= 8 {
            let len = try r.readUInt8()
            try r.skip(3)
            let dx = Int16(bitPattern: try r.readUInt16())
            let dy = Int16(bitPattern: try r.readUInt16())
            if len == 0xFF {
                guard r.remaining >= 4 else { return elts }
                let gs = try r.readUInt32()
                elts.append(.glyphsetSwitch(deltax: dx, deltay: dy, glyphset: gs))
            } else {
                let n = Int(len)
                let dataBytes = n * size
                guard r.remaining >= dataBytes else { return elts }
                var ids: [UInt32] = []
                ids.reserveCapacity(n)
                switch idSize {
                case .bits8:
                    for _ in 0..<n { ids.append(UInt32(try r.readUInt8())) }
                case .bits16:
                    for _ in 0..<n { ids.append(UInt32(try r.readUInt16())) }
                case .bits32:
                    for _ in 0..<n { ids.append(try r.readUInt32()) }
                }
                try r.skip(xPad(dataBytes))
                elts.append(.draw(deltax: dx, deltay: dy, glyphIDs: ids))
            }
        }
        return elts
    }
}

// MARK: - AddGlyphs trailer

/// One glyph's metrics — the xGlyphInfo struct on the wire (12 bytes).
public struct RenderGlyphInfo: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var x: Int16
    public var y: Int16
    public var xOff: Int16
    public var yOff: Int16

    public init(width: UInt16, height: UInt16,
                x: Int16, y: Int16, xOff: Int16, yOff: Int16) {
        self.width = width; self.height = height
        self.x = x; self.y = y
        self.xOff = xOff; self.yOff = yOff
    }
}

/// AddGlyphs trailer. Order on the wire:
///   1. `nglyphs` × CARD32 glyph IDs.
///   2. `nglyphs` × 12-byte xGlyphInfo records.
///   3. Bitmap data — all glyph images concatenated, each individually
///      padded to a 32-bit boundary. The total byte count of this
///      blob can be derived from the request length; the split into
///      per-glyph chunks needs each glyph's width/height/format depth.
///      We carry the blob raw; the dumper surfaces its byte count.
public struct RenderAddGlyphsPayload: Equatable, Sendable {
    public var glyphIDs: [UInt32]
    public var glyphInfos: [RenderGlyphInfo]
    public var bitmapData: [UInt8]

    public init(glyphIDs: [UInt32], glyphInfos: [RenderGlyphInfo],
                bitmapData: [UInt8]) {
        precondition(glyphIDs.count == glyphInfos.count,
                     "glyphIDs and glyphInfos must have the same count")
        precondition(bitmapData.count % 4 == 0,
                     "bitmapData must be 4-byte aligned")
        self.glyphIDs = glyphIDs
        self.glyphInfos = glyphInfos
        self.bitmapData = bitmapData
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        for id in glyphIDs { w.writeUInt32(id) }
        for info in glyphInfos {
            w.writeUInt16(info.width); w.writeUInt16(info.height)
            w.writeUInt16(UInt16(bitPattern: info.x)); w.writeUInt16(UInt16(bitPattern: info.y))
            w.writeUInt16(UInt16(bitPattern: info.xOff)); w.writeUInt16(UInt16(bitPattern: info.yOff))
        }
        w.writeBytes(bitmapData)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8],
                              nglyphs: Int,
                              byteOrder: ByteOrder) throws -> RenderAddGlyphsPayload {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        var ids: [UInt32] = []
        ids.reserveCapacity(nglyphs)
        for _ in 0..<nglyphs { ids.append(try r.readUInt32()) }
        var infos: [RenderGlyphInfo] = []
        infos.reserveCapacity(nglyphs)
        for _ in 0..<nglyphs {
            let width = try r.readUInt16(); let height = try r.readUInt16()
            let x = Int16(bitPattern: try r.readUInt16())
            let y = Int16(bitPattern: try r.readUInt16())
            let xOff = Int16(bitPattern: try r.readUInt16())
            let yOff = Int16(bitPattern: try r.readUInt16())
            infos.append(RenderGlyphInfo(
                width: width, height: height,
                x: x, y: y, xOff: xOff, yOff: yOff
            ))
        }
        let bitmapData = try r.readBytes(r.remaining)
        return RenderAddGlyphsPayload(
            glyphIDs: ids, glyphInfos: infos, bitmapData: bitmapData
        )
    }
}
