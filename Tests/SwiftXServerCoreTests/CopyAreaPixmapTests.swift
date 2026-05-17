import XCTest
import CoreGraphics
import Framer
@testable import SwiftXServerCore

// Pixmap↔pixmap CopyArea is the cleanest path to test end-to-end without
// AppKit: both src and dst live in CGBitmapContext via PixmapTable, no
// NSWindow involved, no main-thread dispatch. Verifies that:
//  - Stage 2's bridge.copyArea(src:.pixmap, dst:.pixmap, …) actually writes
//    pixels into the dst pixmap's CGBitmapContext via the CGImage path.
//  - The pixel data we read back from dst.context is what we wrote into
//    src.context cropped to the source rect.
//
// Cross-NSWindow and window↔pixmap paths use the same withDrawContext +
// CGImage code path internally; their AppKit dispatch is exercised
// indirectly via the dt-app live tests on u5.

final class CopyAreaPixmapTests: XCTestCase {

    func testPixmapToPixmapBlitCopiesPixels() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }

        // Source: 8×8 pixmap, fill the top-left 4×4 with red.
        let srcId: UInt32 = 0x100
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24, width: 8, height: 8)
        let srcBuf = try XCTUnwrap(pixmaps.buffer(for: srcId))
        srcBuf.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        srcBuf.context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))

        // Destination: 8×8 pixmap, initially transparent black.
        let dstId: UInt32 = 0x101
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24, width: 8, height: 8)

        // Blit the entire 4×4 red region from src to dst at (2, 2).
        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 0, srcY: 0,
            dstX: 2, dstY: 2,
            width: 4, height: 4,
            clipRectangles: nil
        )

        // Read back dst pixels.
        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        let pixels = readARGBPixels(from: dstBuf)

        // The 4×4 region landing at (2,2) in the dst should be red-dominant.
        // Outside that region the dst should still be transparent (alpha=0).
        // Use red-dominates check to absorb sRGB-vs-DeviceRGB gamma drift.
        for row in 2..<6 {
            for col in 2..<6 {
                let px = pixels[row * 8 + col]
                XCTAssertGreaterThan(px.r, px.g, "dst(\(col),\(row)) should be red-dominant")
                XCTAssertGreaterThan(px.r, px.b, "dst(\(col),\(row)) should be red-dominant")
                XCTAssertGreaterThanOrEqual(px.r, 0xF0, "dst(\(col),\(row)) red intensity")
            }
        }
        // Top-left corner outside the blit region should be untouched.
        XCTAssertEqual(pixels[0].a, 0x00, "dst(0,0) should still be transparent")
        XCTAssertEqual(pixels[0].r, 0x00, "dst(0,0) should still be empty")
    }

    func testPixmapToPixmapBlitWithSourceOffset() throws {
        let bridge = CocoaWindowBridge()
        let pixmaps = PixmapTable()
        bridge.setPixmapBufferLookup { id in pixmaps.buffer(for: id) }

        // Source: 8×8 with the BOTTOM-right 4×4 filled red. Top half empty.
        let srcId: UInt32 = 0x200
        pixmaps.allocate(id: srcId, drawable: 0x28, depth: 24, width: 8, height: 8)
        let srcBuf = try XCTUnwrap(pixmaps.buffer(for: srcId))
        srcBuf.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        srcBuf.context.fill(CGRect(x: 4, y: 4, width: 4, height: 4))

        // Destination: 8×8 transparent.
        let dstId: UInt32 = 0x201
        pixmaps.allocate(id: dstId, drawable: 0x28, depth: 24, width: 8, height: 8)

        // Copy the SOURCE'S (4,4)–(8,8) blue region to dst at (0,0). Should
        // land in dst's top-left 4×4.
        bridge.copyArea(
            src: .pixmap(id: srcId, depth: 24),
            dst: .pixmap(id: dstId, depth: 24),
            srcX: 4, srcY: 4,
            dstX: 0, dstY: 0,
            width: 4, height: 4,
            clipRectangles: nil
        )

        let dstBuf = try XCTUnwrap(pixmaps.buffer(for: dstId))
        let pixels = readARGBPixels(from: dstBuf)
        for row in 0..<4 {
            for col in 0..<4 {
                let px = pixels[row * 8 + col]
                XCTAssertGreaterThan(px.b, px.r, "dst(\(col),\(row)) should be blue-dominant")
                XCTAssertGreaterThan(px.b, px.g, "dst(\(col),\(row)) should be blue-dominant")
            }
        }
        // The destination's untouched bottom-right quadrant should still
        // be transparent.
        let bottomRight = pixels[7 * 8 + 7]
        XCTAssertEqual(bottomRight.a, 0x00, "dst(7,7) should still be transparent")
    }

    // MARK: - Helpers

    private struct ARGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

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
