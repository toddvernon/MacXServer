import XCTest
@testable import SwiftXServerCore

// Covers the TrueColor pack/unpack semantics (since 2026-06-13). Pre-switch
// this file tested PseudoColor cell-pinning + shared-cell behavior; that
// model is gone now — pixel value IS the RGB. AllocColor is a bit pack,
// QueryColors is a bit unpack, no cells, no allocation order to test.

final class ColorTableTests: XCTestCase {

    private let white = RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
    private let black = RGB16(red: 0, green: 0, blue: 0)

    func testWhiteRGBPacksToFFFFFF() {
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: white.red, green: white.green, blue: white.blue)
        XCTAssertEqual(r.pixel, 0x00FFFFFF, "TrueColor whitePixel = packed RGB888 max")
    }

    func testBlackRGBPacksToZero() {
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: black.red, green: black.green, blue: black.blue)
        XCTAssertEqual(r.pixel, 0x00000000, "TrueColor blackPixel = packed RGB888 zero")
    }

    func testRepeatedRGBReturnsSamePixel() {
        // Degenerate in TrueColor — same input always produces the same
        // packed pixel, no allocation state involved. The count semantic
        // matters for CapturedAppReplayTests baselines.
        let table = SwiftXServerCore.ColorTable()
        let rgb = RGB16(red: 0x1234, green: 0x5678, blue: 0x9ABC)
        let first = table.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let second = table.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(first.pixel, second.pixel,
                       "Same RGB must always pack to the same pixel")
        XCTAssertEqual(table.count, 1,
                       "Distinct-pixel count is 1 — repeated alloc is a no-op")
    }

    func testDistinctRGBGetsDistinctPixel() {
        let table = SwiftXServerCore.ColorTable()
        let a = table.allocate(red: 0x1000, green: 0x2000, blue: 0x3000)
        let b = table.allocate(red: 0x1000, green: 0x2000, blue: 0x3100)
        // Distinct after 8-bit quantization: low byte of green differs by 1
        // bit at position 8, which lands in the truncated channel.
        XCTAssertNotEqual(a.pixel, b.pixel, "Differing RGBs (post-quantize) must get distinct pixels")
    }

    func testRgbLookupRoundtripsAfterQuantization() {
        // The returned `allocated` RGB is the 8-bit-quantized form: low
        // byte truncated, top byte broadcast (the `*257` X convention).
        // The full-precision input doesn't survive — but the round trip
        // through allocate → rgb(for:) preserves the quantized form.
        let table = SwiftXServerCore.ColorTable()
        let allocated = table.allocate(red: 0xAA00, green: 0xBB00, blue: 0xCC00)
        XCTAssertEqual(allocated.allocated, RGB16(red: 0xAAAA, green: 0xBBBB, blue: 0xCCCC),
                       "AllocColor returns the 8-bit-broadcast form of the input")
        XCTAssertEqual(table.rgb(for: allocated.pixel), allocated.allocated,
                       "rgb(for:) recovers the quantized RGB exactly")
    }

    func testLowByteTruncatedOnAllocation() {
        // Low byte of each 16-bit channel is the part X spec calls
        // "subject to hardware precision." Our 8-bit TrueColor packs the
        // high byte and broadcasts back; the low byte is lost.
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: 0x12FF, green: 0x34FF, blue: 0x56FF)
        XCTAssertEqual(r.pixel, 0x123456,
                       "Pixel is packed from the high byte of each channel")
        XCTAssertEqual(r.allocated, RGB16(red: 0x1212, green: 0x3434, blue: 0x5656),
                       "Allocated RGB is the high byte broadcast back to 16 bits (×257)")
    }

    func testRgbForUnknownPixelStillUnpacks() {
        // Unlike PseudoColor where unknown pixels returned nil → black,
        // TrueColor has no "unknown" pixels in the 24-bit RGB888 range.
        // Every pixel value is a valid RGB.
        let table = SwiftXServerCore.ColorTable()
        let unallocated: UInt32 = 0x123456
        XCTAssertEqual(table.rgb(for: unallocated),
                       RGB16(red: 0x1212, green: 0x3434, blue: 0x5656))
    }

    func testCoordinatorOwnsSharedColors() {
        // In TrueColor sessions can independently pack the same RGB and
        // get the same pixel (it's deterministic). The coordinator
        // sharing is still valid — distinct-pixel counts coalesce across
        // sessions, matching what real X servers do for replies that
        // reference the colormap state.
        let coordinator = ServerCoordinator()
        let s1 = ServerSession(coordinator: coordinator)
        let s2 = ServerSession(coordinator: coordinator)
        let rgb = RGB16(red: 0x4444, green: 0x5555, blue: 0x6666)
        let a = s1.colors.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let b = s2.colors.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(a.pixel, b.pixel,
                       "Same RGB packs to the same pixel deterministically across sessions")
    }
}
