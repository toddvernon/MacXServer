import XCTest
@testable import SwiftXServerCore

// Covers the shared-cell + pinned-whitePixel behavior added 2026-05-19.
// Motif's no-color-server fallback in dtcalc relies on AllocColor returning
// whitePixel for an RGB-white request — that's what makes its
// BlackWhite-detection trigger and the LCD widget render visibly.

final class ColorTableTests: XCTestCase {

    private let white = RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
    private let black = RGB16(red: 0, green: 0, blue: 0)

    func testWhiteRGBReturnsWhitePixel() {
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: white.red, green: white.green, blue: white.blue)
        XCTAssertEqual(r.pixel, 0, "AllocColor(white) must return whitePixel=0")
    }

    func testBlackRGBReturnsBlackPixel() {
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: black.red, green: black.green, blue: black.blue)
        XCTAssertEqual(r.pixel, 1, "AllocColor(black) must return blackPixel=1")
    }

    func testRepeatedRGBReturnsSamePixel() {
        let table = SwiftXServerCore.ColorTable()
        let rgb = RGB16(red: 0x1234, green: 0x5678, blue: 0x9ABC)
        let first = table.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let second = table.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(first.pixel, second.pixel,
                       "Repeated AllocColor with same RGB must return the same shared pixel")
        XCTAssertEqual(table.count, 4,
                       "Shared-cell hit should not grow the table (3 pinned + 1 new)")
    }

    func testDistinctRGBGetsDistinctPixel() {
        let table = SwiftXServerCore.ColorTable()
        let a = table.allocate(red: 0x1000, green: 0x2000, blue: 0x3000)
        let b = table.allocate(red: 0x1000, green: 0x2000, blue: 0x3001)
        XCTAssertNotEqual(a.pixel, b.pixel, "Differing RGBs must get distinct pixels")
    }

    func testRgbLookupRoundtrips() {
        let table = SwiftXServerCore.ColorTable()
        let rgb = RGB16(red: 0xAAAA, green: 0xBBBB, blue: 0xCCCC)
        let allocated = table.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(table.rgb(for: allocated.pixel), rgb)
    }

    func testPinnedWhiteAtAlternatePixelStillReturnsCanonicalZero() {
        // 0xFFFFFF is pinned to white as a defensive carryover, but
        // shared-cell lookup must prefer the lowest pixel ID (0) so dtcalc's
        // BlackWhite-detection (which compares against whitePixel=0) works.
        let table = SwiftXServerCore.ColorTable()
        let r = table.allocate(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
        XCTAssertEqual(r.pixel, 0)
    }

    func testCoordinatorOwnsSharedColors() {
        // Two sessions on the same coordinator must see the same pixel for
        // the same RGB. This is the SHORTCUTS:32 regression: pre-fix,
        // session A's pixel 17 might be green while session B's pixel 17
        // was the same value with a different RGB. Now they're one table.
        let coordinator = ServerCoordinator()
        let s1 = ServerSession(coordinator: coordinator)
        let s2 = ServerSession(coordinator: coordinator)
        let rgb = RGB16(red: 0x4444, green: 0x5555, blue: 0x6666)
        let a = s1.colors.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let b = s2.colors.allocate(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(a.pixel, b.pixel,
                       "Coordinator-owned ColorTable: both sessions must see the same pixel for the same RGB")
    }
}
