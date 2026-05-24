import XCTest
@testable import SwiftXServerCore

final class FontMappingTokenizerTests: XCTestCase {

    // MARK: - Comments

    func testHashComment() {
        let spans = FontMappingTokenizer.tokenize("# this is a comment")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 19))
    }

    func testBangComment() {
        let spans = FontMappingTokenizer.tokenize("! also a comment")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
    }

    func testBlankLineNoSpans() {
        XCTAssertTrue(FontMappingTokenizer.tokenize("").isEmpty)
        XCTAssertTrue(FontMappingTokenizer.tokenize("   ").isEmpty)
    }

    // MARK: - Data lines

    func testSimpleDataLine() {
        // "fixed  ->  Monaco" → family + arrow + macFont
        let spans = FontMappingTokenizer.tokenize("fixed  ->  Monaco")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .family)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 5))    // "fixed"
        XCTAssertEqual(spans[1].kind, .arrow)
        XCTAssertEqual(spans[1].range, NSRange(location: 7, length: 2))    // "->"
        XCTAssertEqual(spans[2].kind, .macFont)
        XCTAssertEqual(spans[2].range, NSRange(location: 11, length: 6))   // "Monaco"
    }

    func testMacFontWithSpacesSpansThroughInternalWhitespace() {
        // "helvetica  ->  Helvetica Neue" — macFont span covers
        // "Helvetica Neue" including the internal space.
        let spans = FontMappingTokenizer.tokenize("helvetica  ->  Helvetica Neue")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .family)
        XCTAssertEqual(spans[1].kind, .arrow)
        XCTAssertEqual(spans[2].kind, .macFont)
        XCTAssertEqual(spans[2].range, NSRange(location: 15, length: 14))  // "Helvetica Neue"
    }

    func testMultiWordFamily() {
        // "new century schoolbook  ->  Charter" — family span covers
        // the full multi-word name.
        let spans = FontMappingTokenizer.tokenize("new century schoolbook  ->  Charter")
        XCTAssertEqual(spans[0].kind, .family)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 22))   // "new century schoolbook"
    }

    func testFallbackKey() {
        let spans = FontMappingTokenizer.tokenize("*fallback-mono  ->  Monaco")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .fallbackKey)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 14))   // "*fallback-mono"
    }

    func testLeadingWhitespacePreserved() {
        let spans = FontMappingTokenizer.tokenize("    fixed  ->  Monaco")
        XCTAssertEqual(spans[0].kind, .family)
        XCTAssertEqual(spans[0].range, NSRange(location: 4, length: 5))    // "fixed" starts after spaces
    }

    func testMalformedLineGetsUnknown() {
        // No `->` separator
        let spans = FontMappingTokenizer.tokenize("fixed Monaco")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .unknown)
    }

    // MARK: - Multi-line offsets

    func testMultilineOffsets() {
        let text = "# header\nfixed  ->  Monaco"
        let spans = FontMappingTokenizer.tokenize(text)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 8))    // "# header"
        // Line 2 starts at offset 9 (after the \n)
        XCTAssertEqual(spans[1].range.location, 9)
        XCTAssertEqual(spans[1].kind, .family)
        XCTAssertEqual(spans[2].kind, .arrow)
        XCTAssertEqual(spans[3].kind, .macFont)
    }
}
