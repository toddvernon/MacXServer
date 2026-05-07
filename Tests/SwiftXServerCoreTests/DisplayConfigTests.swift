import XCTest
@testable import SwiftXServerCore

// Verifies the picker algorithm against every entry in the preset table from
// `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Pure-data test; no NSScreen needed.
final class DisplayConfigTests: XCTestCase {

    func testStudioDisplay5K() {
        let c = DisplayConfig.pick(nativeWidth: 5120, nativeHeight: 2880)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 900)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.deviceWidth, 3840)
        XCTAssertEqual(c.deviceHeight, 2700)
    }

    func testProDisplayXDR6K() {
        // 6016×3384: 1280×900@3x = 3840×2700 fits cleanly. (Doc table claims
        // 4x but that overflows H; 3x is what the algorithm correctly picks.)
        let c = DisplayConfig.pick(nativeWidth: 6016, nativeHeight: 3384)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 900)
        XCTAssertEqual(c.scale, 3)
    }

    func test4KExternalFillsExactly() {
        let c = DisplayConfig.pick(nativeWidth: 3840, nativeHeight: 2160)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 720)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.deviceWidth, 3840)
        XCTAssertEqual(c.deviceHeight, 2160)
    }

    func testMacBookPro16Retina() {
        let c = DisplayConfig.pick(nativeWidth: 3456, nativeHeight: 2234)
        XCTAssertEqual(c.logicalWidth, 1152)
        XCTAssertEqual(c.logicalHeight, 720)
        XCTAssertEqual(c.scale, 3)
    }

    func testMacBookPro14Retina() {
        let c = DisplayConfig.pick(nativeWidth: 3024, nativeHeight: 1964)
        XCTAssertEqual(c.logicalWidth, 1008)
        XCTAssertEqual(c.logicalHeight, 648)
        XCTAssertEqual(c.scale, 3)
    }

    func test1080pExternalFills() {
        let c = DisplayConfig.pick(nativeWidth: 1920, nativeHeight: 1080)
        XCTAssertEqual(c.logicalWidth, 960)
        XCTAssertEqual(c.logicalHeight, 540)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.deviceWidth, 1920)
        XCTAssertEqual(c.deviceHeight, 1080)
    }

    func testUnusualSmallDisplayFallsBackToScale1() {
        // 800×600 is smaller than any (logical * 2). Fallback returns 1:1
        // with native dimensions.
        let c = DisplayConfig.pick(nativeWidth: 800, nativeHeight: 600)
        XCTAssertEqual(c.scale, 1)
        XCTAssertEqual(c.logicalWidth, 800)
        XCTAssertEqual(c.logicalHeight, 600)
    }

    func testReportedPhysicalSizeIsApproximately90DPI() {
        let c = DisplayConfig.studioDisplay
        // 1280 logical px at 90 DPI = 1280 * 25.4 / 90 ≈ 361 mm
        XCTAssertEqual(c.widthMm, 361)
        // 900 logical px at 90 DPI = 900 * 25.4 / 90 ≈ 254 mm
        XCTAssertEqual(c.heightMm, 254)
        // Reported DPI for sanity: 1280 / (361 / 25.4) ≈ 90.06
        let dpi = Double(c.logicalWidth) / (Double(c.widthMm) / 25.4)
        XCTAssertEqual(dpi, 90.0, accuracy: 0.5)
    }

    func testDeviceDimensionsAreLogicalTimesScale() {
        let c = DisplayConfig(
            logicalWidth: 1280, logicalHeight: 900, scale: 3,
            nativePixelWidth: 5120, nativePixelHeight: 2880
        )
        XCTAssertEqual(c.deviceWidth, 3840)
        XCTAssertEqual(c.deviceHeight, 2700)
    }

    func testPickerNeverPicksDeviceLargerThanNative() {
        // Spot-check: across plausible native dimensions, device should fit.
        let cases: [(Int, Int)] = [
            (5120, 2880), (3840, 2160), (3456, 2234), (3024, 1964),
            (2560, 1440), (1920, 1080), (4096, 2160), (5120, 2160),
        ]
        for (w, h) in cases {
            let c = DisplayConfig.pick(nativeWidth: w, nativeHeight: h)
            XCTAssertLessThanOrEqual(c.deviceWidth, w, "device width \(c.deviceWidth) > native \(w) for \(w)x\(h)")
            XCTAssertLessThanOrEqual(c.deviceHeight, h, "device height \(c.deviceHeight) > native \(h) for \(w)x\(h)")
        }
    }
}
