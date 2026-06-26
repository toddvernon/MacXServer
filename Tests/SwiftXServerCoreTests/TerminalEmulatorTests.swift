import XCTest
import CVTerm
@testable import SwiftXServerCore

// Spike-level coverage that the vendored libvterm (Sources/CVTerm) is wired
// up correctly: bytes in -> screen grid + cursor out, and keys in -> the
// right wire bytes out. Not exhaustive emulation coverage (libvterm itself
// is well-tested); this pins our Swift wrapper and the C-interop boundary.
final class TerminalEmulatorTests: XCTestCase {

    func testPlainTextLandsInTheGrid() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("hello".utf8))
        let grid = term.grid()
        XCTAssertEqual(rowString(grid, 0, width: 5), "hello")
        // Cursor should have advanced to column 5 on row 0.
        XCTAssertEqual(term.cursor().row, 0)
        XCTAssertEqual(term.cursor().col, 5)
    }

    func testCRLFMovesToNextRow() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("ab\r\ncd".utf8))
        let grid = term.grid()
        XCTAssertEqual(rowString(grid, 0, width: 2), "ab")
        XCTAssertEqual(rowString(grid, 1, width: 2), "cd")
        XCTAssertEqual(term.cursor().row, 1)
        XCTAssertEqual(term.cursor().col, 2)
    }

    func testCursorAddressingAndEraseScreen() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        // The exact pair vi/curses send: clear screen, home cursor, draw.
        term.feed(Data("garbage".utf8))
        term.feed(Data("\u{1b}[2J\u{1b}[H".utf8))   // ED(2) + CUP home
        term.feed(Data("X".utf8))
        let grid = term.grid()
        XCTAssertEqual(grid[0][0].text, "X")
        // The old "garbage" must be gone after the erase.
        XCTAssertEqual(rowString(grid, 0, width: 7), "X      ")
    }

    func testSGRBoldAndReverseAttributes() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("\u{1b}[1mB\u{1b}[0m\u{1b}[7mR\u{1b}[0mn".utf8))
        let grid = term.grid()
        XCTAssertTrue(grid[0][0].bold,        "cell 0 should be bold")
        XCTAssertFalse(grid[0][0].reverse)
        XCTAssertTrue(grid[0][1].reverse,     "cell 1 should be reverse")
        XCTAssertFalse(grid[0][1].bold)
        XCTAssertFalse(grid[0][2].bold,       "cell 2 should be plain")
        XCTAssertFalse(grid[0][2].reverse)
    }

    func testColorsResolveToRGB() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        // SGR 31 = red foreground. We don't pin an exact palette RGB (that's
        // libvterm's default table), just that it's distinctly red-ish and
        // not the default grey.
        term.feed(Data("\u{1b}[31mr".utf8))
        let fg = term.grid()[0][0].fg
        XCTAssertGreaterThan(fg.r, fg.g)
        XCTAssertGreaterThan(fg.r, fg.b)
    }

    func testTypingProducesWireBytes() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        let bytes = term.sendText("ls")
        XCTAssertEqual(bytes, Data("ls".utf8))
    }

    func testEnterAndArrowEncodeAsEscapeSequences() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        XCTAssertEqual(term.sendKey(VTERM_KEY_ENTER), Data("\r".utf8))
        // Default (DECCKM reset) cursor-up is CSI A.
        XCTAssertEqual(term.sendKey(VTERM_KEY_UP), Data("\u{1b}[A".utf8))
    }

    func testCtrlCEncodesAsETX() {
        let term = TerminalEmulator(rows: 24, cols: 80)
        let bytes = term.sendText("c", mod: VTERM_MOD_CTRL)
        XCTAssertEqual(bytes, Data([0x03]))   // Ctrl-C
    }

    // MARK: - helpers

    /// The first `width` cells of `row` as a String.
    private func rowString(_ grid: [[TerminalEmulator.Cell]], _ row: Int, width: Int) -> String {
        grid[row].prefix(width).map(\.text).joined()
    }
}
