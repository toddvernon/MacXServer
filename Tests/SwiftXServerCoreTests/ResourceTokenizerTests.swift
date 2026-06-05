import XCTest
@testable import SwiftXServerCore

final class ResourceTokenizerTests: XCTestCase {

    // MARK: - Section headers

    func testSectionHeaderMacxserverConfig() {
        let spans = ResourceTokenizer.tokenize("[macxserver-config]")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .sectionHeader)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 19))
    }

    func testSectionHeaderGlobalWithLeadingWhitespace() {
        let spans = ResourceTokenizer.tokenize("  [global]")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .sectionHeader)
        // Header starts at the '[' (offset 2), runs through the ']' (offset 9).
        XCTAssertEqual(spans[0].range, NSRange(location: 2, length: 8))
    }

    func testSectionHeaderThemeQuickplot() {
        let spans = ResourceTokenizer.tokenize("[theme:quickplot]")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .sectionHeader)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 17))
    }

    // MARK: - Comments

    func testCommentToEndOfLine() {
        let spans = ResourceTokenizer.tokenize("! this is a comment")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 19))
    }

    func testCommentLeadingWhitespacePreservesStart() {
        let spans = ResourceTokenizer.tokenize("    ! indented")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(spans[0].range, NSRange(location: 4, length: 10))
    }

    // MARK: - key : value

    func testKeyValueSplit() {
        let spans = ResourceTokenizer.tokenize("*background: White")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 11))   // "*background"
        XCTAssertEqual(spans[1].kind, .separator)
        XCTAssertEqual(spans[1].range, NSRange(location: 11, length: 1))   // ":"
        XCTAssertEqual(spans[2].kind, .colorValueNamed)
        XCTAssertEqual(spans[2].range, NSRange(location: 13, length: 5))   // "White"
    }

    // MARK: - keyPrefix split

    func testKeyPrefixSplitOnFirstStar() {
        // "Dtterm*background: Gray" → "Dtterm" prefix, "*background" key
        let spans = ResourceTokenizer.tokenize("Dtterm*background: Gray")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0].kind, .keyPrefix)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 6))    // "Dtterm"
        XCTAssertEqual(spans[1].kind, .key)
        XCTAssertEqual(spans[1].range, NSRange(location: 6, length: 11))   // "*background"
        XCTAssertEqual(spans[2].kind, .separator)
        XCTAssertEqual(spans[2].range, NSRange(location: 17, length: 1))   // ":"
        XCTAssertEqual(spans[3].kind, .colorValueNamed)
    }

    func testKeyPrefixSplitOnFirstStarOfMany() {
        // "Dtpad*XmText.background: White" — split on FIRST '*' only
        let spans = ResourceTokenizer.tokenize("Dtpad*XmText.background: White")
        XCTAssertEqual(spans[0].kind, .keyPrefix)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 5))    // "Dtpad"
        XCTAssertEqual(spans[1].kind, .key)
        XCTAssertEqual(spans[1].range, NSRange(location: 5, length: 18))   // "*XmText.background"
    }

    func testLeadingBindingPlusClassPickedUp() {
        // "*XmText.background: White" — leading '*' then XmText class.
        // Spans: .key "*" + .keyPrefix "XmText" + .key ".background" + sep + value
        let spans = ResourceTokenizer.tokenize("*XmText.background: White")
        XCTAssertEqual(spans.count, 5)
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 1))    // "*"
        XCTAssertEqual(spans[1].kind, .keyPrefix)
        XCTAssertEqual(spans[1].range, NSRange(location: 1, length: 6))    // "XmText"
        XCTAssertEqual(spans[2].kind, .key)
        XCTAssertEqual(spans[2].range, NSRange(location: 7, length: 11))   // ".background"
        XCTAssertEqual(spans[3].kind, .separator)
        XCTAssertEqual(spans[4].kind, .colorValueNamed)
    }

    func testNoBindingButLeadingClassPickedUp() {
        // "Dtcalc.foreground: Black" — class at the start, no leading binding.
        // Spans: .keyPrefix "Dtcalc" + .key ".foreground" + sep + value
        let spans = ResourceTokenizer.tokenize("Dtcalc.foreground: Black")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0].kind, .keyPrefix)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 6))    // "Dtcalc"
        XCTAssertEqual(spans[1].kind, .key)
        XCTAssertEqual(spans[1].range, NSRange(location: 6, length: 11))   // ".foreground"
    }

    func testLowercaseInstanceAfterBindingGetsNoPrefix() {
        // "*menubar*background:" — lowercase after the leading '*' means
        // this is an instance, not a class. No coral.
        let spans = ResourceTokenizer.tokenize("*menubar*background: SlateBlue1")
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 19))   // whole pattern stays green
    }

    func testOnlyFirstClassHighlighted() {
        // "*XmDialogShell*XmPushButtonGadget*background:" — two classes
        // in a row, but only the first one (XmDialogShell) gets coral.
        let spans = ResourceTokenizer.tokenize("*XmDialogShell*XmPushButtonGadget*background: White")
        // Spans: .key "*" + .keyPrefix "XmDialogShell" + .key "*XmPushButtonGadget*background" + sep + value
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 1))
        XCTAssertEqual(spans[1].kind, .keyPrefix)
        XCTAssertEqual(spans[1].range, NSRange(location: 1, length: 13))   // "XmDialogShell"
        XCTAssertEqual(spans[2].kind, .key)
        XCTAssertEqual(spans[2].range.location, 14)                        // "*XmPushButtonGadget*background"
    }

    func testKeyValueWithTrailingWhitespace() {
        let spans = ResourceTokenizer.tokenize("foo: bar   ")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[2].kind, .value)
        XCTAssertEqual(spans[2].range, NSRange(location: 5, length: 3))    // "bar"
    }

    func testHexColorValueShortForm() {
        // "Foo*bg: #abc" → keyPrefix "Foo" + key "*bg" + separator + colorValueHex "#abc"
        let spans = ResourceTokenizer.tokenize("Foo*bg: #abc")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[3].kind, .colorValueHex)
        XCTAssertEqual(spans[3].range, NSRange(location: 8, length: 4))    // "#abc"
    }

    func testHexColorValueLongForm() {
        let spans = ResourceTokenizer.tokenize("Foo*bg: #2a2a2a")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[3].kind, .colorValueHex)
    }

    func testNonColorValueStaysValue() {
        // "XmText.fontList: -*-helvetica-*" — XmText is a leading class,
        // so spans are keyPrefix + key + separator + value (4 spans).
        let spans = ResourceTokenizer.tokenize("XmText.fontList: -*-helvetica-*")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[3].kind, .value)
    }

    func testNumericValueStaysValue() {
        let spans = ResourceTokenizer.tokenize("*shadowThickness: 2")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[2].kind, .value)
    }

    // MARK: - Edge cases

    func testEmptyLineProducesNoSpans() {
        XCTAssertTrue(ResourceTokenizer.tokenize("").isEmpty)
        XCTAssertTrue(ResourceTokenizer.tokenize("   ").isEmpty)
        XCTAssertTrue(ResourceTokenizer.tokenize("\t\t").isEmpty)
    }

    func testKeyWithoutValueTaggedAsKey() {
        let spans = ResourceTokenizer.tokenize("malformed")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 9))
    }

    func testKeyWithEmptyValue() {
        let spans = ResourceTokenizer.tokenize("foo:")
        // key + separator, no value span
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].kind, .key)
        XCTAssertEqual(spans[1].kind, .separator)
    }

    // MARK: - Multi-line offset tracking

    func testMultiLineOffsetsAreUTF16AnchoredToFullText() {
        let text = """
        [global]
        *bg: White
        ! tail
        """
        let spans = ResourceTokenizer.tokenize(text)
        // Spans, in order:
        //   "[global]"    @ 0   length 8
        //   "*bg"         @ 9   length 3   (line 2 starts at 9)
        //   ":"           @ 12
        //   "White"       @ 14  length 5
        //   "! tail"      @ 20  length 6
        XCTAssertEqual(spans.count, 5)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 8))
        XCTAssertEqual(spans[1].range, NSRange(location: 9, length: 3))
        XCTAssertEqual(spans[2].range, NSRange(location: 12, length: 1))
        XCTAssertEqual(spans[3].range, NSRange(location: 14, length: 5))
        XCTAssertEqual(spans[3].kind, .colorValueNamed)
        XCTAssertEqual(spans[4].range, NSRange(location: 20, length: 6))
        XCTAssertEqual(spans[4].kind, .comment)
    }

    func testTrailingNewlineDoesNotShiftOffsets() {
        let text = "[global]\n*bg: White\n"
        let spans = ResourceTokenizer.tokenize(text)
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0].range.location, 0)
        XCTAssertEqual(spans[1].range.location, 9)
        XCTAssertEqual(spans[3].range.location, 14)
    }

    // MARK: - classifyValue helper

    func testClassifyValueHex() {
        XCTAssertEqual(ResourceTokenizer.classifyValue("#abc"), .colorValueHex)
        XCTAssertEqual(ResourceTokenizer.classifyValue("#abcdef"), .colorValueHex)
        XCTAssertEqual(ResourceTokenizer.classifyValue("#ABCDEF"), .colorValueHex)
    }

    func testClassifyValueNamed() {
        XCTAssertEqual(ResourceTokenizer.classifyValue("White"), .colorValueNamed)
        XCTAssertEqual(ResourceTokenizer.classifyValue("SlateBlue1"), .colorValueNamed)
        XCTAssertEqual(ResourceTokenizer.classifyValue("DarkSeaGreen"), .colorValueNamed)
    }

    func testClassifyValueBareString() {
        XCTAssertEqual(ResourceTokenizer.classifyValue("hello"), .value)
        XCTAssertEqual(ResourceTokenizer.classifyValue("-*-helvetica-*"), .value)
        XCTAssertEqual(ResourceTokenizer.classifyValue("2"), .value)
    }

    func testClassifyValueMalformedHexStaysValue() {
        // # without enough digits → not a hex color
        XCTAssertEqual(ResourceTokenizer.classifyValue("#zz"), .value)
        XCTAssertEqual(ResourceTokenizer.classifyValue("#1234"), .value)   // 4 digits, not 3 or 6
    }
}
