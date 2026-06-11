import XCTest
@testable import SwiftXServerCore

// Verifies the picker algorithm. As of 2026-06-11 the preset table only gates
// the SCALE choice; the logical root is derived to span the whole display at
// that scale (`native ÷ scale`, floored). So these assert the scale the gate
// picks plus the screen-derived logical size. Pure-data test; no NSScreen.
final class DisplayConfigTests: XCTestCase {

    func testStudioDisplay5K() {
        // 1280×900@3x fits → scale 3 gated in. Logical spans the panel:
        // floor(5120/3)=1706, floor(2880/3)=960.
        let c = DisplayConfig.pick(nativeWidth: 5120, nativeHeight: 2880)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.logicalWidth, 1706)
        XCTAssertEqual(c.logicalHeight, 960)
        XCTAssertEqual(c.deviceWidth, 5118)   // 1706×3, ≤ 5120
        XCTAssertEqual(c.deviceHeight, 2880)  // 960×3, == 2880
    }

    func testProDisplayXDR6K() {
        // 1280×900@3x fits → scale 3. Logical: floor(6016/3)=2005,
        // floor(3384/3)=1128.
        let c = DisplayConfig.pick(nativeWidth: 6016, nativeHeight: 3384)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.logicalWidth, 2005)
        XCTAssertEqual(c.logicalHeight, 1128)
    }

    func test4KExternalFillsExactly() {
        // 3840/3 and 2160/3 are exact, so the logical root still lands on
        // 1280×720 and the device canvas fills the panel exactly.
        let c = DisplayConfig.pick(nativeWidth: 3840, nativeHeight: 2160)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.logicalWidth, 1280)
        XCTAssertEqual(c.logicalHeight, 720)
        XCTAssertEqual(c.deviceWidth, 3840)
        XCTAssertEqual(c.deviceHeight, 2160)
    }

    func testMacBookPro16Retina() {
        // scale 3 gated in. Logical: floor(3456/3)=1152, floor(2234/3)=744.
        let c = DisplayConfig.pick(nativeWidth: 3456, nativeHeight: 2234)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.logicalWidth, 1152)
        XCTAssertEqual(c.logicalHeight, 744)
    }

    func testMacBookPro14Retina() {
        // scale 3 gated in. Logical: floor(3024/3)=1008, floor(1964/3)=654.
        let c = DisplayConfig.pick(nativeWidth: 3024, nativeHeight: 1964)
        XCTAssertEqual(c.scale, 3)
        XCTAssertEqual(c.logicalWidth, 1008)
        XCTAssertEqual(c.logicalHeight, 654)
    }

    func test1080pExternalFills() {
        // No preset fits at 3x; 960×540@2x fits → scale 2. 1920/2 and 1080/2
        // are exact, so logical is 960×540 and the canvas fills the panel.
        let c = DisplayConfig.pick(nativeWidth: 1920, nativeHeight: 1080)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 960)
        XCTAssertEqual(c.logicalHeight, 540)
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
        // Forcing scale=2 → logical spans the panel at 2x:
        // 5120/2=2560, 2880/2=1440 (both exact).
        let c = DisplayConfig.pick(nativeWidth: 5120, nativeHeight: 2880, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 2560)
        XCTAssertEqual(c.logicalHeight, 1440)
        XCTAssertEqual(c.deviceWidth, 5120)
        XCTAssertEqual(c.deviceHeight, 2880)
    }

    func testForcedScale2OnMacBookPro14() {
        // Forcing scale=2 gives a bigger logical screen (the SunOS-app-fits
        // motivation for --scale 2). Logical: floor(3024/2)=1512,
        // floor(1964/2)=982.
        let c = DisplayConfig.pick(nativeWidth: 3024, nativeHeight: 1964, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 1512)
        XCTAssertEqual(c.logicalHeight, 982)
    }

    func testForcedScale2OnMacBookPro16() {
        // Forcing scale=2. Logical: floor(4112/2)=2056, floor(2658/2)=1329.
        let c = DisplayConfig.pick(nativeWidth: 4112, nativeHeight: 2658, forcedScale: 2)
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.logicalWidth, 2056)
        XCTAssertEqual(c.logicalHeight, 1329)
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

    func testLogicalRootSpansWholeDisplay() {
        // The fix for the 2026-06-11 menu-drift bug: the advertised root must
        // cover the entire area a window can be dragged into, so the device
        // canvas comes within one scale-step of the native panel — no dead
        // strip the X coordinate space doesn't claim. (Pre-fix the preset
        // size left up to ~25% of a 5K panel outside the root.)
        let cases: [(Int, Int)] = [
            (5120, 2880), (3840, 2160), (3456, 2234), (3024, 1964),
            (2560, 1440), (1920, 1080), (4112, 2658),
        ]
        for (w, h) in cases {
            let c = DisplayConfig.pick(nativeWidth: w, nativeHeight: h)
            let s = Int(c.scale)
            XCTAssertLessThan(w - c.deviceWidth, s, "horizontal dead strip \(w - c.deviceWidth)px ≥ scale \(s) for \(w)x\(h)")
            XCTAssertLessThan(h - c.deviceHeight, s, "vertical dead strip \(h - c.deviceHeight)px ≥ scale \(s) for \(w)x\(h)")
        }
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
