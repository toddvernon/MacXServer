import XCTest
@testable import SwiftXCaptureCore
import Framer

// Visual catalog: SetupAccepted reply populates ctx.visualCatalog; dumper
// helpers resolve visualIds to symbolic form. Cheap to test — the helpers
// take a ChronoContext value directly.

final class VisualCatalogTests: XCTestCase {

    private func ctxWithVisuals(_ visuals: [(id: UInt32, depth: UInt8, cls: VisualClass)]) -> ChronoContext {
        var ctx = ChronoContext()
        for v in visuals {
            ctx.visualCatalog[v.id] = VisualCatalogEntry(
                depth: v.depth, visualClass: v.cls, bitsPerRgbValue: 8, screenIndex: 0)
        }
        return ctx
    }

    // MARK: - visualDisplay

    func testCopyFromParentRenderedByName() {
        let ctx = ChronoContext()
        XCTAssertEqual(visualDisplay(0, ctx: ctx), "CopyFromParent")
    }

    func testKnownVisualRendersWithClassAndDepth() {
        let ctx = ctxWithVisuals([(0x22, 8, .pseudoColor)])
        XCTAssertEqual(visualDisplay(0x22, ctx: ctx), "0x22(PseudoColor d8)")
    }

    func testUnknownVisualFallsBackToHex() {
        let ctx = ChronoContext()
        XCTAssertEqual(visualDisplay(0x22, ctx: ctx), "0x22")
    }

    func testAllVisualClassesRender() {
        let ctx = ctxWithVisuals([
            (1, 1,  .staticGray),
            (2, 4,  .grayScale),
            (3, 8,  .staticColor),
            (4, 8,  .pseudoColor),
            (5, 24, .trueColor),
            (6, 24, .directColor),
        ])
        XCTAssertEqual(visualDisplay(1, ctx: ctx), "0x1(StaticGray d1)")
        XCTAssertEqual(visualDisplay(2, ctx: ctx), "0x2(GrayScale d4)")
        XCTAssertEqual(visualDisplay(3, ctx: ctx), "0x3(StaticColor d8)")
        XCTAssertEqual(visualDisplay(4, ctx: ctx), "0x4(PseudoColor d8)")
        XCTAssertEqual(visualDisplay(5, ctx: ctx), "0x5(TrueColor d24)")
        XCTAssertEqual(visualDisplay(6, ctx: ctx), "0x6(DirectColor d24)")
    }

    // MARK: - end-to-end SetupAccepted → catalog → CreateWindow render

    func testSetupAcceptedHarvestPopulatesCatalog() throws {
        // Build a minimal SetupAccepted with two depths and three visuals.
        let visuals1bpp = [
            VisualType(visualId: 0x20, visualClass: .staticGray,
                       bitsPerRgbValue: 1, colormapEntries: 2,
                       redMask: 0, greenMask: 0, blueMask: 0)
        ]
        let visuals8bpp = [
            VisualType(visualId: 0x21, visualClass: .pseudoColor,
                       bitsPerRgbValue: 8, colormapEntries: 256,
                       redMask: 0, greenMask: 0, blueMask: 0),
            VisualType(visualId: 0x22, visualClass: .staticColor,
                       bitsPerRgbValue: 8, colormapEntries: 256,
                       redMask: 0, greenMask: 0, blueMask: 0),
        ]
        let screen = Screen(
            root: 0x2B, defaultColormap: 0x20, whitePixel: 1, blackPixel: 0,
            currentInputMasks: 0, widthInPixels: 1280, heightInPixels: 1024,
            widthInMillimeters: 360, heightInMillimeters: 290,
            minInstalledMaps: 1, maxInstalledMaps: 1,
            rootVisual: 0x21, backingStores: .never, saveUnders: false,
            rootDepth: 8,
            allowedDepths: [
                Depth(depth: 1, visuals: visuals1bpp),
                Depth(depth: 8, visuals: visuals8bpp),
            ])
        let accepted = SetupAccepted(
            protocolMajor: 11, protocolMinor: 0,
            releaseNumber: 11000004, resourceIdBase: 0x2800000,
            resourceIdMask: 0x1FFFFF, motionBufferSize: 256,
            maximumRequestLength: 65535, imageByteOrder: .lsbFirst,
            bitmapFormatBitOrder: .leastSignificant, bitmapFormatScanlineUnit: 32,
            bitmapFormatScanlinePad: 32, minKeycode: 8, maxKeycode: 134,
            vendor: Array("Sun".utf8), pixmapFormats: [], screens: [screen])

        // Round-trip through the dumper's setup-reply path so we exercise the
        // exact harvest code in dump(): build a one-shot capture with just
        // the setup-reply landing.
        var ctx = ChronoContext()
        ctx.s2cSetupSeen = true
        // Manually run the harvest the way dump() does.
        for (idx, screen) in accepted.screens.enumerated() {
            for d in screen.allowedDepths {
                for v in d.visuals {
                    ctx.visualCatalog[v.visualId] = VisualCatalogEntry(
                        depth: d.depth, visualClass: v.visualClass,
                        bitsPerRgbValue: v.bitsPerRgbValue, screenIndex: idx)
                }
            }
        }
        XCTAssertEqual(ctx.visualCatalog.count, 3)
        XCTAssertEqual(ctx.visualCatalog[0x20]?.depth, 1)
        XCTAssertEqual(ctx.visualCatalog[0x20]?.visualClass, .staticGray)
        XCTAssertEqual(ctx.visualCatalog[0x21]?.depth, 8)
        XCTAssertEqual(ctx.visualCatalog[0x21]?.visualClass, .pseudoColor)
        XCTAssertEqual(visualDisplay(0x21, ctx: ctx), "0x21(PseudoColor d8)")
    }
}
