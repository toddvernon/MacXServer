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

    func testClearScreenVariants() {
        // The forms `clear`/tput emit across vt100/xterm/sun: ED(2), and
        // home + ED(0)-to-end. All must leave the whole grid blank.
        for clearSeq in ["\u{1b}[2J", "\u{1b}[H\u{1b}[J", "\u{1b}[H\u{1b}[2J", "\u{1b}[1;1H\u{1b}[2J"] {
            let term = TerminalEmulator(rows: 24, cols: 80)
            // Fill several rows with content.
            term.feed(Data("line one\r\nline two\r\nline three\r\n".utf8))
            term.feed(Data(clearSeq.utf8))
            let grid = term.grid()
            let nonBlank = grid.flatMap { $0 }.filter { $0.text != " " }
            XCTAssertTrue(nonBlank.isEmpty,
                          "clear seq \(clearSeq.debugDescription) left \(nonBlank.count) non-blank cells")
        }
    }

    func testFormFeedDoesNotClear() {
        // A bare form-feed (^L) is NOT a screen clear in vt100/xterm; it acts
        // like a line feed. If a guest's `clear` only sent ^L we'd (correctly)
        // not blank the screen -- documents that distinction so a "clear didn't
        // work" report points at TERM, not the emulator.
        let term = TerminalEmulator(rows: 24, cols: 80)
        term.feed(Data("keep me".utf8))
        term.feed(Data("\u{0c}".utf8))   // ^L
        XCTAssertEqual(term.grid()[0].prefix(7).map(\.text).joined(), "keep me")
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

    func testCursorPositionReportRepliesOnFeed() {
        // The resize handshake (cm runs /usr/openwin/bin/resize): move to the
        // far corner, then DSR `ESC[6n` -> the emulator must reply with the
        // cursor position `ESC[r;cR` on the FEED path (not waiting for a
        // keystroke), or resize hangs. The far corner clamps to our grid, so
        // the report should be row 24, col 80 (1-based).
        let term = TerminalEmulator(rows: 24, cols: 80)
        var replies = [Data]()
        term.onOutput = { replies.append($0) }
        term.feed(Data("\u{1b}[999;999H\u{1b}[6n".utf8))
        let joined = replies.reduce(Data(), +)
        XCTAssertEqual(joined, Data("\u{1b}[24;80R".utf8))
    }

    func testDeviceAttributesReplyOnFeed() {
        // `ESC[c` (primary DA) must also get an answer on the feed path.
        let term = TerminalEmulator(rows: 24, cols: 80)
        var got = Data()
        term.onOutput = { got.append($0) }
        term.feed(Data("\u{1b}[c".utf8))
        XCTAssertFalse(got.isEmpty, "primary DA query should produce a reply")
        XCTAssertEqual(got.first, 0x1b)   // a CSI response
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
