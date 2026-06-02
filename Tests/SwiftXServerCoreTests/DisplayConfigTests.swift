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

    // MARK: - forcedScale (SCALE_PICKER.md)

    func testForcedScale2OnStudioDisplay() {
        // Studio Display at scale=3 picks 1280×900. Forcing scale=2 should
        // also land 1280×900 (still the largest preset that fits).
        let c = DisplayConfig.pick(nativeWidth: 5120, nativeHeight: 2880, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 900)
        XCTAssertEqual(c.deviceWidth, 2560)
        XCTAssertEqual(c.deviceHeight, 1800)
    }

    func testForcedScale2OnMacBookPro14() {
        // 14" MBP at scale=3 picks 1008×648 (the only preset that fits).
        // Forcing scale=2 unlocks 1280×900 because 2560×1800 fits 3024×1964.
        // This is the SunOS-app-fits motivation for --scale 2.
        let c = DisplayConfig.pick(nativeWidth: 3024, nativeHeight: 1964, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 900)
    }

    func testForcedScale2OnMacBookPro16() {
        // 16" MBP at scale=3 picks 1152×720 from the doc table (or 1280×720
        // per the actual picker — verified empirically at 4112×2658 native).
        // Forcing scale=2 lands 1280×900 because 2560×1800 fits comfortably.
        let c = DisplayConfig.pick(nativeWidth: 4112, nativeHeight: 2658, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 900)
    }

    func testForcedScale3MatchesDefaultBehavior() {
        // --scale 3 should be a no-op vs no flag, since the picker already
        // prefers 3x. Verify on a 4K external where 3x and the default agree.
        let forced = DisplayConfig.pick(nativeWidth: 3840, nativeHeight: 2160, forcedScale: 3)
        let auto   = DisplayConfig.pick(nativeWidth: 3840, nativeHeight: 2160)
        XCTAssertEqual(forced.scale, auto.scale)
        XCTAssertEqual(forced.logicalWidth, auto.logicalWidth)
        XCTAssertEqual(forced.logicalHeight, auto.logicalHeight)
    }

    func testForcedScale2OnTinyDisplayFallsBack() {
        // No preset fits at 2x on a 640×480 display. The fallback path returns
        // 1:1 with native dimensions. Documents existing behavior; not great UX
        // but matches the "always return something" contract of pick().
        let c = DisplayConfig.pick(nativeWidth: 640, nativeHeight: 480, forcedScale: 2)
        XCTAssertEqual(c.scale, 1)
        XCTAssertEqual(c.logicalWidth, 640)
        XCTAssertEqual(c.logicalHeight, 480)
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
