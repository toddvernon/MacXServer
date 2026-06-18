import XCTest
@testable import SwiftXServerCore

final class ConsoleSanitizerTests: XCTestCase {

    // MARK: - Basic line handling

    func testPlainTextAndNewline() {
        let s = ConsoleSanitizer()
        let u = s.feed("Hello\nWorld")
        XCTAssertEqual(u.completedLines, ["Hello"])
        XCTAssertEqual(u.currentLine, "World")
    }

    func testCRLFCollapsesToOneLine() {
        // \r returns to col 0, \n flushes -> no stray \r in the output.
        let s = ConsoleSanitizer()
        let u = s.feed("alpha\r\nbeta\r\n")
        XCTAssertEqual(u.completedLines, ["alpha", "beta"])
        XCTAssertEqual(u.currentLine, "")
    }

    // MARK: - Backspace / echo-erase

    func testBackspaceErasePattern() {
        // The classic "\b \b" erase: back up, overwrite with space, back up.
        let s = ConsoleSanitizer()
        let u = s.feed("ab\u{08} \u{08}")
        // 'a','b' -> "ab"; BS -> col1; ' ' overwrites 'b' -> "a "; BS -> col1.
        XCTAssertEqual(u.currentLine, "a ")
    }

    func testBackspaceThenOverwrite() {
        let s = ConsoleSanitizer()
        let u = s.feed("cat\u{08}\u{08}p")
        // cursor left twice after "cat" -> col1, 'p' overwrites 'a' -> "cpt".
        XCTAssertEqual(u.currentLine, "cpt")
    }

    func testBackspaceDoesNotUnderflow() {
        let s = ConsoleSanitizer()
        let u = s.feed("\u{08}\u{08}x")
        XCTAssertEqual(u.currentLine, "x")
    }

    // MARK: - The spinner (Sun boot/install loves it)

    func testSpinnerFinalFrameInOneChunk() {
        // -\b\b... arriving as one chunk leaves the last frame on the line.
        let s = ConsoleSanitizer()
        let u = s.feed("-\u{08}\\\u{08}|\u{08}/")
        XCTAssertEqual(u.currentLine, "/")
        XCTAssertTrue(u.completedLines.isEmpty)
    }

    func testSpinnerAnimatesAcrossChunks() {
        // Real spinners arrive a frame per read; each feed shows one glyph
        // in the same column. This is what makes it animate in the window.
        let s = ConsoleSanitizer()
        XCTAssertEqual(s.feed("Booting -").currentLine, "Booting -")
        XCTAssertEqual(s.feed("\u{08}\\").currentLine, "Booting \\")
        XCTAssertEqual(s.feed("\u{08}|").currentLine, "Booting |")
        XCTAssertEqual(s.feed("\u{08}/").currentLine, "Booting /")
        // Finishes: backspace, "done", newline.
        let done = s.feed("\u{08}done\n")
        XCTAssertEqual(done.completedLines, ["Booting done"])
        XCTAssertEqual(done.currentLine, "")
    }

    func testCarriageReturnReprintOverwrites() {
        // Progress reprint via \r (full-width) overwrites in place.
        let s = ConsoleSanitizer()
        _ = s.feed("Copying... 50%")
        let u = s.feed("\rCopying... 90%")
        XCTAssertEqual(u.currentLine, "Copying... 90%")
    }

    // MARK: - Escape stripping

    func testStripsSGRColor() {
        let s = ConsoleSanitizer()
        let u = s.feed("a\u{1B}[31mb\u{1B}[0mc")
        XCTAssertEqual(u.currentLine, "abc")
    }

    func testStripsClearScreenWithoutClearing() {
        // We must NOT honor clear-screen: this is an append-only log.
        let s = ConsoleSanitizer()
        let u = s.feed("x\u{1B}[2J\u{1B}[Hy")
        XCTAssertEqual(u.currentLine, "xy")
    }

    func testStripsTwoCharAndCharsetEscapes() {
        let s = ConsoleSanitizer()
        // ESC c (reset), ESC ( B (designate charset) both fully consumed.
        let u = s.feed("a\u{1B}cb\u{1B}(Bc")
        XCTAssertEqual(u.currentLine, "abc")
    }

    func testEscapeSplitAcrossChunks() {
        // The CSI sequence is split mid-stream; parser state must carry.
        let s = ConsoleSanitizer()
        XCTAssertEqual(s.feed("a\u{1B}[").currentLine, "a")
        XCTAssertEqual(s.feed("31mb").currentLine, "ab")
    }

    // MARK: - Other control bytes

    func testDropsBell() {
        let s = ConsoleSanitizer()
        XCTAssertEqual(s.feed("a\u{07}b").currentLine, "ab")
    }

    func testTabExpandsToEightColumnStops() {
        let s = ConsoleSanitizer()
        let u = s.feed("a\tb")
        // 'a' at col0 -> col1; tab fills 7 spaces to col8; 'b' at col8.
        XCTAssertEqual(u.currentLine, "a       b")
        XCTAssertEqual(u.currentLine.count, 9)
    }

    // MARK: - Reset

    func testResetClearsState() {
        let s = ConsoleSanitizer()
        _ = s.feed("partial line and \u{1B}[")
        s.reset()
        let u = s.feed("fresh")
        XCTAssertEqual(u.currentLine, "fresh")
        XCTAssertTrue(u.completedLines.isEmpty)
    }
}
