import Framer

// RENDER extension dumper.
//
// Phase 3 RENDER Session 1 (2026-05-30): Tier A backbone + the
// QueryPictFormats reply walker. Session 2 adds CompositeGlyphs and
// AddGlyphs (the two most-emitted ops on Pango-heavy captures, with
// the trickiest trailers). Session 3 adds Tier B/C — trapezoids,
// gradients, cursor, etc.
//
// RENDER has no events. eventCount = 0.

public enum RenderDumper: ExtensionDumper {
    public static let extensionName = "RENDER"
    public static let eventCount = 0

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {

        case RenderMinor.queryVersion:
            if let r = try? RenderQueryVersion.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderQueryVersion       wanted=\(r.majorVersion).\(r.minorVersion)"
            }

        case RenderMinor.queryPictFormats:
            return "RenderQueryPictFormats"

        case RenderMinor.createPicture:
            if let r = try? RenderCreatePicture.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreatePicture      pid=\(hx(r.pid)) drawable=\(hx(r.drawable)) format=\(hx(r.format)) mask=\(hx(r.valueMask)) values=\(r.valueList.count / 4)"
            }

        case RenderMinor.changePicture:
            if let r = try? RenderChangePicture.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderChangePicture      picture=\(hx(r.picture)) mask=\(hx(r.valueMask)) values=\(r.valueList.count / 4)"
            }

        case RenderMinor.setPictureClipRectangles:
            if let r = try? RenderSetPictureClipRectangles.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderSetPictureClipRectangles picture=\(hx(r.picture)) origin=(\(r.xOrigin),\(r.yOrigin)) rects=\(r.rectangles.count)"
            }

        case RenderMinor.freePicture:
            if let r = try? RenderFreePicture.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderFreePicture        picture=\(hx(r.picture))"
            }

        case RenderMinor.composite:
            if let r = try? RenderComposite.decode(from: bytes, byteOrder: byteOrder) {
                let opName = pictOpName(r.op)
                let maskStr = r.mask == 0 ? "None" : hx(r.mask)
                return "RenderComposite          op=\(opName) src=\(hx(r.src)) mask=\(maskStr) dst=\(hx(r.dst)) src=(\(r.xSrc),\(r.ySrc)) maskOff=(\(r.xMask),\(r.yMask)) dst=(\(r.xDst),\(r.yDst)) \(r.width)x\(r.height)"
            }

        case RenderMinor.createGlyphSet:
            if let r = try? RenderCreateGlyphSet.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateGlyphSet     gsid=\(hx(r.gsid)) format=\(hx(r.format))"
            }

        case RenderMinor.freeGlyphSet:
            if let r = try? RenderFreeGlyphSet.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderFreeGlyphSet       glyphset=\(hx(r.glyphset))"
            }

        case RenderMinor.freeGlyphs:
            if let r = try? RenderFreeGlyphs.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderFreeGlyphs         glyphset=\(hx(r.glyphset)) ids=\(r.glyphIDs.count)"
            }

        case RenderMinor.setPictureTransform:
            if let r = try? RenderSetPictureTransform.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderSetPictureTransform picture=\(hx(r.picture)) matrix=[..3x3 16.16 fixed..]"
            }

        // Session 2 — glyph stack + filter/index queries
        case RenderMinor.queryPictIndexValues:
            if let r = try? RenderQueryPictIndexValues.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderQueryPictIndexValues format=\(hx(r.format))"
            }
        case RenderMinor.queryFilters:
            if let r = try? RenderQueryFilters.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderQueryFilters       drawable=\(hx(r.drawable))"
            }
        case RenderMinor.addGlyphs:
            if let r = try? RenderAddGlyphs.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderAddGlyphs          glyphset=\(hx(r.glyphset)) nglyphs=\(r.payload.glyphIDs.count) bitmapData=\(r.payload.bitmapData.count)b"
            }
        case RenderMinor.compositeGlyphs8,
             RenderMinor.compositeGlyphs16,
             RenderMinor.compositeGlyphs32:
            if let r = try? RenderCompositeGlyphs.decode(from: bytes, byteOrder: byteOrder) {
                let (totalGlyphs, switches) = glyphElementStats(r.elts)
                let maskStr = r.maskFormat == 0 ? "None" : hx(r.maskFormat)
                let size = idSizeBits(r.idSize)
                return "RenderCompositeGlyphs\(size)  op=\(pictOpName(r.op)) src=\(hx(r.src)) dst=\(hx(r.dst)) mask=\(maskStr) glyphset=\(hx(r.glyphset)) origin=(\(r.xSrc),\(r.ySrc)) elts=\(r.elts.count) glyphs=\(totalGlyphs) switches=\(switches)"
            }

        // Session 3 — poly ops, gradients, cursor, etc.
        case RenderMinor.scale:
            if let r = try? RenderScale.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderScale              src=\(hx(r.src)) dst=\(hx(r.dst)) colorScale=\(hx(r.colorScale)) alphaScale=\(hx(r.alphaScale)) src=(\(r.xSrc),\(r.ySrc)) dst=(\(r.xDst),\(r.yDst)) \(r.width)x\(r.height)"
            }
        case RenderMinor.trapezoids:
            if let r = try? RenderTrapezoids.decode(from: bytes, byteOrder: byteOrder) {
                let maskStr = r.maskFormat == 0 ? "None" : hx(r.maskFormat)
                return "RenderTrapezoids         op=\(pictOpName(r.op)) src=\(hx(r.src)) dst=\(hx(r.dst)) mask=\(maskStr) src=(\(r.xSrc),\(r.ySrc)) trapezoids=\(r.trapezoids.count)"
            }
        case RenderMinor.triangles:
            if let r = try? RenderTriangles.decode(from: bytes, byteOrder: byteOrder) {
                let maskStr = r.maskFormat == 0 ? "None" : hx(r.maskFormat)
                return "RenderTriangles          op=\(pictOpName(r.op)) src=\(hx(r.src)) dst=\(hx(r.dst)) mask=\(maskStr) src=(\(r.xSrc),\(r.ySrc)) triangles=\(r.triangles.count)"
            }
        case RenderMinor.triStrip:
            if let r = try? RenderTriStrip.decode(from: bytes, byteOrder: byteOrder) {
                let maskStr = r.maskFormat == 0 ? "None" : hx(r.maskFormat)
                return "RenderTriStrip           op=\(pictOpName(r.op)) src=\(hx(r.src)) dst=\(hx(r.dst)) mask=\(maskStr) src=(\(r.xSrc),\(r.ySrc)) points=\(r.points.count)"
            }
        case RenderMinor.triFan:
            if let r = try? RenderTriFan.decode(from: bytes, byteOrder: byteOrder) {
                let maskStr = r.maskFormat == 0 ? "None" : hx(r.maskFormat)
                return "RenderTriFan             op=\(pictOpName(r.op)) src=\(hx(r.src)) dst=\(hx(r.dst)) mask=\(maskStr) src=(\(r.xSrc),\(r.ySrc)) points=\(r.points.count)"
            }
        case RenderMinor.referenceGlyphSet:
            if let r = try? RenderReferenceGlyphSet.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderReferenceGlyphSet  gsid=\(hx(r.gsid)) existing=\(hx(r.existing))"
            }
        case RenderMinor.fillRectangles:
            if let r = try? RenderFillRectangles.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderFillRectangles     op=\(pictOpName(r.op)) dst=\(hx(r.dst)) color=(\(r.color.red),\(r.color.green),\(r.color.blue),\(r.color.alpha)) rects=\(r.rectangles.count)"
            }
        case RenderMinor.createCursor:
            if let r = try? RenderCreateCursor.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateCursor       cid=\(hx(r.cid)) src=\(hx(r.src)) hotspot=(\(r.x),\(r.y))"
            }
        case RenderMinor.setPictureFilter:
            if let r = try? RenderSetPictureFilter.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderSetPictureFilter   picture=\(hx(r.picture)) name=\"\(r.name)\" values=\(r.values.count)"
            }
        case RenderMinor.createAnimCursor:
            if let r = try? RenderCreateAnimCursor.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateAnimCursor   cid=\(hx(r.cid)) elts=\(r.elts.count)"
            }
        case RenderMinor.addTraps:
            if let r = try? RenderAddTraps.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderAddTraps           picture=\(hx(r.picture)) offset=(\(r.xOff),\(r.yOff)) traps=\(r.traps.count)"
            }
        case RenderMinor.createSolidFill:
            if let r = try? RenderCreateSolidFill.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateSolidFill    pid=\(hx(r.pid)) color=(\(r.color.red),\(r.color.green),\(r.color.blue),\(r.color.alpha))"
            }
        case RenderMinor.createLinearGradient:
            if let r = try? RenderCreateLinearGradient.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateLinearGradient pid=\(hx(r.pid)) p1=\(fixedPoint(r.p1)) p2=\(fixedPoint(r.p2)) stops=\(r.stops.count)"
            }
        case RenderMinor.createRadialGradient:
            if let r = try? RenderCreateRadialGradient.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateRadialGradient pid=\(hx(r.pid)) inner=\(fixedPoint(r.inner)) outer=\(fixedPoint(r.outer)) innerR=\(r.innerRadius) outerR=\(r.outerRadius) stops=\(r.stops.count)"
            }
        case RenderMinor.createConicalGradient:
            if let r = try? RenderCreateConicalGradient.decode(from: bytes, byteOrder: byteOrder) {
                return "RenderCreateConicalGradient pid=\(hx(r.pid)) center=\(fixedPoint(r.center)) angle=\(r.angle) stops=\(r.stops.count)"
            }

        // Reserved holes: opcodes 3, 14, 15, 16, 21 — render.h spec'd
        // these but they were either never shipped (3, 14, 15, 21) or
        // explicitly commented out (16 = Transform).
        case RenderMinor.queryDithers,
             RenderMinor.colorTrapezoids,
             RenderMinor.colorTriangles,
             RenderMinor._reservedTransform,
             RenderMinor.addGlyphsFromPicture:
            return "RENDER                   opcode=\(bytes[0]) minor=\(bytes[1]) (reserved/unimplemented)"

        default:
            break
        }
        return nil
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        nil   // no events
    }

    // MARK: - PictOp names

    /// PictOp constant → human-readable name. Subset of the common ones
    /// from render.h; uncommon ops (e.g. PictOpHSLHue) fall through to
    /// hex.
    private static func pictOpName(_ op: UInt8) -> String {
        switch op {
        case 0:  return "Clear"
        case 1:  return "Src"
        case 2:  return "Dst"
        case 3:  return "Over"
        case 4:  return "OverReverse"
        case 5:  return "In"
        case 6:  return "InReverse"
        case 7:  return "Out"
        case 8:  return "OutReverse"
        case 9:  return "Atop"
        case 10: return "AtopReverse"
        case 11: return "Xor"
        case 12: return "Add"
        case 13: return "Saturate"
        case 16: return "DisjointClear"
        case 32: return "ConjointClear"
        default: return "op=\(op)"
        }
    }

    private static func hx(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }

    /// Walk the elements once to count total draw glyphs and switches.
    /// Useful for the dumper summary line — capturing just `elts.count`
    /// understates Pango's per-call glyph throughput (one elt can hold
    /// up to 254 glyphs).
    private static func glyphElementStats(_ elts: [RenderGlyphElt]) -> (totalGlyphs: Int, switches: Int) {
        var glyphs = 0
        var switches = 0
        for elt in elts {
            switch elt {
            case .draw(_, _, let ids): glyphs += ids.count
            case .glyphsetSwitch:      switches += 1
            }
        }
        return (glyphs, switches)
    }

    private static func idSizeBits(_ size: RenderGlyphIdSize) -> String {
        switch size {
        case .bits8:  return "8 "
        case .bits16: return "16"
        case .bits32: return "32"
        }
    }

    /// Format a 16.16 fixed-point point as a (xInt, yInt) pair. Shows
    /// just the integer part — enough for a dump-line scan.
    private static func fixedPoint(_ p: RenderPointFixed) -> String {
        "(\(p.x >> 16),\(p.y >> 16))"
    }
}
