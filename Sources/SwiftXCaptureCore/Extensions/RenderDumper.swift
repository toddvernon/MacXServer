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
}
