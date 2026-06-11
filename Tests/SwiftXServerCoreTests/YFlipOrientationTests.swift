import XCTest
import CoreGraphics
import Framer
@testable import SwiftXServerCore

// Lock in the X11 y-down convention end-to-end across image-based draw
// paths. See GRAPHICS_Y_FLIP.md for the architectural background.
//
// These tests use asymmetric sources (top-row vs bottom-row distinct)
// because that's the only kind of source that can detect a y-orientation
// regression. Symmetric color blocks — the shape used by the older
// CopyAreaPixmapTests — would pass even if rows were stacked upside-down
// in memory, which is exactly why the 2026-05-26 drawPutImage gap sat
// undetected by the unit suite.
//
// If any of these tests fail, the most likely cause is that someone
// added an `ctx.draw(image, in:)` call (or other image-source draw)
// against a y-flipped backing without going through
// `CGContext.drawImageRespectingYFlip`. Read GRAPHICS_Y_FLIP.md before
// "fixing" any of these tests.

final class YFlipOrientationTests: XCTestCase {

    /// drawPutImage with a bitmap whose row 0 is all-1 (foreground) and
    /// remaining rows are all-0 (background) must land foreground in the
    /// pixmap's first memory row. Asymmetric source so an upside-down
    /// write would be immediately visible.
    func testDrawPutImageWritesRowZeroAsTopOfSource() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }

        let pixmapId: UInt32 = 0x300
        let w = 16
        let h = 8
        pixmaps.allocate(id: pixmapId, drawable: 0x28, depth: 24,
                         width: UInt16(w), height: UInt16(h))

        // 16x8 bitmap, scanline-pad=32 → 4 bytes per row. Row 0 all-1,
        // rows 1..7 all-0. Foreground = red, background = blue so we can
        // tell from the pixel which row of the source landed where.
        var data = [UInt8](repeating: 0, count: 4 * h)
        data[0] = 0xFF; data[1] = 0xFF   // row 0 all-1; bytes 2,3 = pad

        bridge.drawPutImage(
            target: .pixmap(id: pixmapId, depth: 24),
            sourceData: data,
            sourceWidth: UInt16(w), sourceHeight: UInt16(h),
            dstX: 0, dstY: 0,
            leftPad: 0,
            foreground: RGB16(red: 0xFFFF, green: 0, blue: 0),       // red
            background: RGB16(red: 0, green: 0, blue: 0xFFFF),       // blue
            clipRectangles: nil
        )

        let buf = try XCTUnwrap(pixmaps.buffer(for: pixmapId))
        let pixels = readARGBPixels(from: buf)

        // Row 0 (top of source = top of memory) must be red-dominant.
        for col in 0..<w {
            let px = pixels[col]
            XCTAssertGreaterThan(px.r, px.b,
                "pixmap row 0 col \(col) should be red (top of source)")
        }
        // Last row (bottom of source = bottom of memory) must be blue-dominant.
        for col in 0..<w {
            let px = pixels[(h - 1) * w + col]
            XCTAssertGreaterThan(px.b, px.r,
                "pixmap last row col \(col) should be blue (bottom of source)")
        }
    }

    /// CopyArea pixmap → pixmap with an asymmetric source must preserve
    /// row order. Source built with FillRectangle (no orientation), so
    /// this isolates blitCroppedImage's behaviour from drawPutImage's.
    func testCopyAreaPixmapToPixmapPreservesRowOrder() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }

        // Source: 8×8 pixmap. Top half (rows 0-3) red, bottom half (rows
        // 4-7) blue. Built via direct FillRect on the CGBitmapContext,
        // which paints top-down in memory through the y-flip CTM.
        let srcId: UInt32 = 0x310
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24, width: 8, height: 8)
        let srcBuf = try XCTUnwrap(pixmaps.buffer(for: srcId))
        srcBuf.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))   // top half red
        srcBuf.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 4, width: 8, height: 4))   // bottom half blue

        // Sanity: verify the source actually wrote top-down (we depend
        // on this; if FillRect ever flips, this fails first with a
        // pointing-finger error).
        let srcPixels = readARGBPixels(from: srcBuf)
        XCTAssertGreaterThan(srcPixels[0].r, srcPixels[0].b,
            "FillRect baseline: src row 0 should be red")
        XCTAssertGreaterThan(srcPixels[7 * 8].b, srcPixels[7 * 8].r,
            "FillRect baseline: src row 7 should be blue")

        // Blit the full 8×8 from src to dst.
        let dstId: UInt32 = 0x311
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24, width: 8, height: 8)
        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 0, srcY: 0, dstX: 0, dstY: 0,
            width: 8, height: 8,
            clipRectangles: nil
        )

        // Dst's top half must be red, bottom half blue — same as src.
        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        let dstPixels = readARGBPixels(from: dstBuf)
        for row in 0..<4 {
            for col in 0..<8 {
                let px = dstPixels[row * 8 + col]
                XCTAssertGreaterThan(px.r, px.b,
                    "dst row \(row) col \(col) should be red (top half of src)")
            }
        }
        for row in 4..<8 {
            for col in 0..<8 {
                let px = dstPixels[row * 8 + col]
                XCTAssertGreaterThan(px.b, px.r,
                    "dst row \(row) col \(col) should be blue (bottom half of src)")
            }
        }
    }

    /// drawPutImage → CopyArea composition. The full chain that broke in
    /// the 2026-05-26 → 2026-05-27 saga: a PutImage-built pixmap blitted
    /// to another pixmap must preserve orientation through both image
    /// draws (two flips compose, net effect must equal identity).
    func testPutImageThenCopyAreaPreservesOrientation() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }

        // Source pixmap populated by PutImage with the same asymmetric
        // bitmap as the first test.
        let srcId: UInt32 = 0x320
        let w = 16, h = 8
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24,
                         width: UInt16(w), height: UInt16(h))
        var data = [UInt8](repeating: 0, count: 4 * h)
        data[0] = 0xFF; data[1] = 0xFF   // row 0 all-1
        bridge.drawPutImage(
            target: .pixmap(id: srcId, depth: 24),
            sourceData: data,
            sourceWidth: UInt16(w), sourceHeight: UInt16(h),
            dstX: 0, dstY: 0, leftPad: 0,
            foreground: RGB16(red: 0xFFFF, green: 0, blue: 0),
            background: RGB16(red: 0, green: 0, blue: 0xFFFF),
            clipRectangles: nil
        )

        // Blit to a dst pixmap.
        let dstId: UInt32 = 0x321
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24,
                         width: UInt16(w), height: UInt16(h))
        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 0, srcY: 0, dstX: 0, dstY: 0,
            width: UInt16(w), height: UInt16(h),
            clipRectangles: nil
        )

        // Dst row 0 must still be red (fg from PutImage's row 0).
        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        let dstPixels = readARGBPixels(from: dstBuf)
        for col in 0..<w {
            let px = dstPixels[col]
            XCTAssertGreaterThan(px.r, px.b,
                "after PutImage+CopyArea, dst row 0 col \(col) should be red")
        }
        for col in 0..<w {
            let px = dstPixels[(h - 1) * w + col]
            XCTAssertGreaterThan(px.b, px.r,
                "after PutImage+CopyArea, dst last row col \(col) should be blue")
        }
    }

    /// CopyArea honoring a GC pixmap clip-mask (dtfile transparent icons).
    /// Asymmetric source (top red / bottom blue) AND asymmetric mask (top
    /// half opaque / bottom half transparent). Verifies three things at once:
    /// polarity (mask bit 1 = drawn), the masked-out region is left UNTOUCHED
    /// (not painted with anything), and orientation (mask row 0 aligns with
    /// source row 0 — a flipped mask would punch the wrong half).
    func testCopyAreaClipMaskPolarityAndOrientation() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }
        let w = 8, h = 8

        // Source: top half red, bottom half blue (top-down via FillRect).
        let srcId: UInt32 = 0x330
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24, width: UInt16(w), height: UInt16(h))
        let srcBuf = try XCTUnwrap(pixmaps.buffer(for: srcId))
        srcBuf.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: 4))
        srcBuf.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 4, width: w, height: 4))

        // Mask: depth-1, top half opaque (black = value 1 = set per
        // StippleBitGrid), bottom half transparent (white = value 0).
        let maskId: UInt32 = 0x331
        pixmaps.allocate(id: maskId, drawable: 0x28, depth: 1, width: UInt16(w), height: UInt16(h))
        let maskBuf = try XCTUnwrap(pixmaps.buffer(for: maskId))
        maskBuf.context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        maskBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: h))          // all transparent
        maskBuf.context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        maskBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: 4))          // top half opaque

        // Dst pre-filled solid green so untouched pixels are detectable.
        let dstId: UInt32 = 0x332
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24, width: UInt16(w), height: UInt16(h))
        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        dstBuf.context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        dstBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 0, srcY: 0, dstX: 0, dstY: 0,
            width: UInt16(w), height: UInt16(h),
            clipRectangles: nil,
            clipMaskPixmap: maskId, clipMaskOriginX: 0, clipMaskOriginY: 0
        )

        let px = readARGBPixels(from: dstBuf)
        // Top half: mask opaque → source row 0 (red) drawn here. Red beats
        // both blue (would mean flipped/wrong source row) and green (= the
        // dst bg, would mean the mask clipped this away).
        for col in 0..<w {
            XCTAssertGreaterThan(px[col].r, px[col].b, "top row should be source red")
            XCTAssertGreaterThan(px[col].r, px[col].g, "top row should be drawn, not untouched green")
        }
        // Bottom half: mask transparent → dst left untouched = green. (If the
        // mask were flipped, this would be blue from the source instead.)
        for row in 4..<h {
            for col in 0..<w {
                let p = px[row * w + col]
                XCTAssertGreaterThan(p.g, p.r, "bottom row \(row) should stay green (masked out)")
                XCTAssertGreaterThan(p.g, p.b, "bottom row \(row) should stay green (masked out)")
            }
        }
    }

    /// Clip-mask with a non-zero clip origin and a mask SMALLER than the copy.
    /// The X spec clips destination pixels outside the mask's set region, so
    /// only the 4×4 mask area (placed at origin (2,2)) gets the source; the
    /// rest of the destination stays untouched.
    func testCopyAreaClipMaskOriginAndOutOfBounds() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }
        let w = 8, h = 8

        let srcId: UInt32 = 0x340
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24, width: UInt16(w), height: UInt16(h))
        let srcBuf = try XCTUnwrap(pixmaps.buffer(for: srcId))
        srcBuf.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: h))           // all red

        // 4×4 fully-opaque mask.
        let maskId: UInt32 = 0x341
        pixmaps.allocate(id: maskId, drawable: 0x28, depth: 1, width: 4, height: 4)
        let maskBuf = try XCTUnwrap(pixmaps.buffer(for: maskId))
        maskBuf.context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        maskBuf.context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))          // all opaque

        let dstId: UInt32 = 0x342
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24, width: UInt16(w), height: UInt16(h))
        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        dstBuf.context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        dstBuf.context.fill(CGRect(x: 0, y: 0, width: w, height: h))           // all green

        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 0, srcY: 0, dstX: 0, dstY: 0,
            width: UInt16(w), height: UInt16(h),
            clipRectangles: nil,
            clipMaskPixmap: maskId, clipMaskOriginX: 2, clipMaskOriginY: 2
        )

        let px = readARGBPixels(from: dstBuf)
        for row in 0..<h {
            for col in 0..<w {
                let p = px[row * w + col]
                let inMask = (2..<6).contains(row) && (2..<6).contains(col)
                if inMask {
                    XCTAssertGreaterThan(p.r, p.g, "(\(col),\(row)) inside mask should be source red")
                } else {
                    XCTAssertGreaterThan(p.g, p.r, "(\(col),\(row)) outside mask should stay green")
                }
            }
        }
    }

    // MARK: - Helpers

    private struct ARGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    /// Read pixmap bytes back as ARGB. Memory layout is byteOrder32Little
    /// + premultipliedFirst, so bytes-in-memory are B, G, R, A per pixel.
    private func readARGBPixels(from buf: PixelBuffer) -> [ARGB] {
        let data = buf.context.data!
        let count = buf.width * buf.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var out: [ARGB] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let off = i * 4
            out.append(ARGB(r: bytes[off + 2],
                            g: bytes[off + 1],
                            b: bytes[off],
                            a: bytes[off + 3]))
        }
        return out
    }
}
