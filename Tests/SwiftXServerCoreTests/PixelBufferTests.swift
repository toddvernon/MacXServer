import XCTest
import CoreGraphics
@testable import SwiftXServerCore

// PixelBuffer + PixmapTable lifecycle and round-trip pixel verification.
// The CocoaWindowBridge pixmap-routing path is tested via live dt-app
// runs on u5 (no AppKit dependency to mock); these tests cover the data
// model.

final class PixelBufferTests: XCTestCase {

    func testAllocatesContextWithCorrectDimensions() throws {
        let buf = try XCTUnwrap(PixelBuffer(width: 48, height: 32))
        XCTAssertEqual(buf.width, 48)
        XCTAssertEqual(buf.height, 32)
        XCTAssertEqual(buf.context.width, 48)
        XCTAssertEqual(buf.context.height, 32)
    }

    func testZeroOrNegativeDimensionsReturnNil() {
        XCTAssertNil(PixelBuffer(width: 0, height: 10))
        XCTAssertNil(PixelBuffer(width: 10, height: 0))
        XCTAssertNil(PixelBuffer(width: -1, height: 10))
    }

    func testDrawsAreReadableFromBackingMemory() throws {
        // Verify that draws into PixelBuffer.context actually land in the
        // bitmap memory we can read back. Fill the entire buffer with red,
        // confirm every pixel reads as red — independent of y-flip layout,
        // which is verified in production via FlippedXView round-trip.
        let buf = try XCTUnwrap(PixelBuffer(width: 4, height: 4))
        buf.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        buf.context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))

        // Color-space gamma conversion (sRGB CGColor → DeviceRGB context) can
        // leak small values into the other channels, so we check that red
        // dominates rather than asserting strict 0xFF / 0x00.
        let pixels = readARGBPixels(from: buf)
        XCTAssertEqual(pixels.count, 16)
        for (i, px) in pixels.enumerated() {
            XCTAssertGreaterThan(px.r, px.g, "pixel \(i) red should dominate green")
            XCTAssertGreaterThan(px.r, px.b, "pixel \(i) red should dominate blue")
            XCTAssertGreaterThanOrEqual(px.r, 0xF0, "pixel \(i) red intensity")
        }
    }

    // MARK: - PixmapTable lifecycle

    func testAllocateCreatesEntryAndBuffer() {
        let table = PixmapTable()
        table.allocate(id: 0x100, drawable: 0x28, depth: 24, width: 16, height: 16)
        XCTAssertNotNil(table.get(0x100))
        XCTAssertNotNil(table.buffer(for: 0x100))
        XCTAssertEqual(table.buffer(for: 0x100)?.width, 16)
        XCTAssertEqual(table.buffer(for: 0x100)?.height, 16)
    }

    func testRemoveFreesEntryAndBuffer() {
        let table = PixmapTable()
        table.allocate(id: 0x100, drawable: 0x28, depth: 24, width: 16, height: 16)
        XCTAssertNotNil(table.buffer(for: 0x100))
        table.remove(0x100)
        XCTAssertNil(table.get(0x100))
        XCTAssertNil(table.buffer(for: 0x100))
    }

    func testAllocateReplacesExistingEntryAtSameId() {
        let table = PixmapTable()
        table.allocate(id: 0x100, drawable: 0x28, depth: 24, width: 16, height: 16)
        table.allocate(id: 0x100, drawable: 0x28, depth: 8, width: 32, height: 8)
        XCTAssertEqual(table.get(0x100)?.depth, 8)
        XCTAssertEqual(table.get(0x100)?.width, 32)
        XCTAssertEqual(table.buffer(for: 0x100)?.width, 32)
        XCTAssertEqual(table.buffer(for: 0x100)?.height, 8)
    }

    // MARK: - Helpers

    private struct ARGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    /// Read pixels back from the CGBitmapContext. byteOrder32Little + premul
    /// first means bytes-in-memory are B, G, R, A per pixel.
    private func readARGBPixels(from buf: PixelBuffer) -> [ARGB] {
        let data = buf.context.data!
        let count = buf.width * buf.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var out: [ARGB] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let off = i * 4
            // byteOrder32Little + premultipliedFirst: bytes in memory are
            // B, G, R, A per pixel.
            out.append(ARGB(r: bytes[off + 2],
                            g: bytes[off + 1],
                            b: bytes[off],
                            a: bytes[off + 3]))
        }
        return out
    }
}
