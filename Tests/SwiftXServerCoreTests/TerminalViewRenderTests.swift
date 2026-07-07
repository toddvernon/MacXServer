import XCTest
import AppKit
@testable import SwiftXServerCore

// Spike proof that the rendering half works end to end: feed bytes -> grid ->
// TerminalView.draw produces actual pixels. Renders the view offscreen into a
// bitmap and inspects cells. This is the integration unknown CONSOLE_TERMINAL
// flagged (our own Core Text drawing of libvterm's grid), so it's worth a
// real pixel assertion rather than a compile-only check.
final class TerminalViewRenderTests: XCTestCase {

    @MainActor
    func testGlyphCellPaintsAndBlankCellDoesNot() throws {
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("\u{1b}[2J\u{1b}[H".utf8))   // clear + home
        term.feed(Data("X".utf8))                    // single glyph at (0,0)

        let view = TerminalView(emulator: term)
        view.refresh()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // Cell (0,0) holds 'X' -> some non-black ink in its box.
        XCTAssertTrue(cellHasInk(rep, row: 0, col: 0, view: view),
                      "the 'X' cell should have rendered ink")
        // A far blank cell -> pure background, no ink.
        XCTAssertFalse(cellHasInk(rep, row: 10, col: 40, view: view),
                       "a blank cell should be background only")
    }

    @MainActor
    func testReverseVideoFillsTheCellBackground() throws {
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
        term.feed(Data("\u{1b}[7m ".utf8))          // reverse-video SPACE at (0,0)

        let view = TerminalView(emulator: term)
        view.refresh()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // Even though it's a space (no glyph), reverse video swaps fg/bg so
        // the cell background is now the bright fg -> non-black.
        XCTAssertTrue(cellHasInk(rep, row: 0, col: 0, view: view),
                      "a reverse-video space should paint a bright background")
    }

    /// True if any sampled pixel in the cell box is meaningfully non-black.
    @MainActor
    private func cellHasInk(_ rep: NSBitmapImageRep, row: Int, col: Int, view: TerminalView) -> Bool {
        // Ask the view for the exact cell box (it offsets the grid by its
        // gridInset breathing margin), then convert points -> bitmap pixels:
        // on a Retina machine the cached rep is 2x, and sampling in point
        // coordinates would land in the margin.
        let box = view.cellRect(row: row, col: col)
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        let cw = box.width * sx
        let ch = box.height * sy
        let x0 = Int(box.minX * sx)
        let y0 = Int(box.minY * sy)
        for dy in stride(from: 2, to: Int(ch) - 2, by: 2) {
            for dx in stride(from: 1, to: Int(cw) - 1, by: 2) {
                guard let c = rep.colorAt(x: x0 + dx, y: y0 + dy) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 0.15 {
                    return true
                }
            }
        }
        return false
    }
}
