import XCTest
import CoreGraphics
import AppKit
@testable import SwiftXServerCore

// Pixel-level regression tests for the Motif scrollbar skin renderer. The skin
// is meant to match the window-frame chrome: crisp, hard-edged bevels (no
// antialiasing), so the stepper-arrow's diagonal edges don't smear and wash out
// the highlight the way they did with AA on.
final class MotifScrollbarRenderTests: XCTestCase {

    // Distinct red channels so any antialiased blend between them is detectable:
    // fill≈128, highlight≈230, shadow≈26.
    private let colors = MotifStateColors(
        fill:      NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1),
        highlight: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1),
        shadow:    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        titleColor: .black)

    /// Render the whole skin and assert every pixel's red channel is one of the
    /// three chrome colors (within rounding) -- i.e. NO antialiased intermediate
    /// values anywhere, including the diagonal arrow edges. With AA on this fails
    /// on the arrow slants (values like 206, 138, 33 appear).
    func testArrowAndBevelsAreCrispNoAntialiasing() {
        let W = 16, H = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: W * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Default bitmap contexts have AA on; the renderer must turn it off itself.
        MotifScrollbarRenderer.paint(ctx, windowRect: CGRect(x: 0, y: 0, width: 16, height: 80),
                                     thumbTop: 0, thumbHeight: 0, colors: colors, bevelWidth: 1)

        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
        // The legitimate FLAT colors of the skin: fill (face/slider/arrow),
        // highlight + shadow (bevels and arrow edges), and the trough channel
        // (fill blended toward shadow). Any pixel that's none of these is an
        // antialiased blend -- exactly what AA-off must eliminate.
        func redByte(_ c: NSColor) -> Int {
            Int(((c.usingColorSpace(.sRGB)?.redComponent ?? 0) * 255).rounded())
        }
        let flats = [redByte(colors.fill), redByte(colors.highlight), redByte(colors.shadow),
                     redByte(MotifScrollbarRenderer.troughColor(colors))]
        func isFlat(_ r: Int) -> Bool { flats.contains { abs($0 - r) <= 1 } }

        var offenders: [(Int, Int, Int)] = []
        for y in 0..<H {
            for x in 0..<W {
                let r = Int(data[(y * W + x) * 4])
                if !isFlat(r) { offenders.append((x, y, r)) }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "found \(offenders.count) antialiased pixels, e.g. \(offenders.prefix(5))")
    }

    /// The up-arrow stepper button keeps its raised top/left highlight bevel: the
    /// left column and one horizontal edge are full highlight, the opposite sides
    /// full shadow. (Orientation-agnostic: we just assert both full-contrast
    /// colors are present on the button's perimeter, crisply.)
    func testArrowButtonHasRaisedBevel() {
        let W = 16, H = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: W * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        MotifScrollbarRenderer.paint(ctx, windowRect: CGRect(x: 0, y: 0, width: 16, height: 80),
                                     thumbTop: 0, thumbHeight: 0, colors: colors, bevelWidth: 1)
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
        func red(_ x: Int, _ y: Int) -> Int { Int(data[(y * W + x) * 4]) }

        // A stepper button occupies the top/bottom `arrow` rows; pick the very
        // first buffer row, which is one button's outer edge. Its left pixel and
        // right pixel are the two bevel colors (highlight vs shadow), full
        // contrast -- proving the raised bevel is present and crisp.
        let leftEdge = red(0, 1)
        let rightEdge = red(W - 1, 1)
        XCTAssertTrue(leftEdge >= 229 || leftEdge <= 27,
                      "left edge should be a full bevel color, got \(leftEdge)")
        XCTAssertTrue(rightEdge >= 229 || rightEdge <= 27,
                      "right edge should be a full bevel color, got \(rightEdge)")
        XCTAssertNotEqual(leftEdge > 128, rightEdge > 128,
                          "left and right edges should be opposite bevel colors (raised look)")
    }
}
