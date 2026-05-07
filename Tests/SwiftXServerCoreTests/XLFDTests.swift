import XCTest
@testable import SwiftXServerCore

final class XLFDTests: XCTestCase {

    func testParseFullXLFD() {
        let s = "-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso8859-1"
        let x = XLFD.parse(s)!
        XCTAssertEqual(x.foundry, "misc")
        XCTAssertEqual(x.family, "fixed")
        XCTAssertEqual(x.weight, "medium")
        XCTAssertEqual(x.slant, "r")
        XCTAssertEqual(x.setwidth, "semicondensed")
        XCTAssertEqual(x.addStyle, "")
        XCTAssertEqual(x.pixelSize, 13)
        XCTAssertEqual(x.pointSize, 120)
        XCTAssertEqual(x.resolutionX, 75)
        XCTAssertEqual(x.resolutionY, 75)
        XCTAssertEqual(x.spacing, "c")
        XCTAssertEqual(x.averageWidth, 60)
        XCTAssertEqual(x.charsetRegistry, "iso8859")
        XCTAssertEqual(x.charsetEncoding, "1")
    }

    func testParseAllWildcards() {
        let s = "-*-*-*-*-*-*-*-*-*-*-*-*-*-*"
        let x = XLFD.parse(s)!
        XCTAssertEqual(x.foundry, "*")
        XCTAssertEqual(x.pixelSize, 0)
        XCTAssertEqual(x.spacing, "*")
    }

    func testParseMissingLeadingDashRejected() {
        XCTAssertNil(XLFD.parse("misc-fixed-medium-r-normal--13-120-75-75-c-60-iso8859-1"))
    }

    func testParseTooFewFieldsRejected() {
        XCTAssertNil(XLFD.parse("-misc-fixed-medium"))
    }

    func testRoundTripPreservesAllFields() {
        let original = XLFD(
            foundry: "apple", family: "monaco", weight: "medium",
            slant: "r", setwidth: "normal", addStyle: "",
            pixelSize: 14, pointSize: 140,
            resolutionX: 90, resolutionY: 90,
            spacing: "m", averageWidth: 84,
            charsetRegistry: "iso10646", charsetEncoding: "1"
        )
        let s = original.format()
        XCTAssertEqual(s, "-apple-monaco-medium-r-normal--14-140-90-90-m-84-iso10646-1")
        let parsed = XLFD.parse(s)!
        XCTAssertEqual(parsed, original)
    }

    func testFormatWithZerosUsesWildcards() {
        let x = XLFD(family: "monaco", pixelSize: 0, pointSize: 0)
        let s = x.format()
        // Empty (zero) numeric fields render as "*"
        XCTAssertTrue(s.contains("-*-*-"))
    }
}
