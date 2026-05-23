import XCTest
@testable import SwiftXServerCore

final class FontMappingFileTests: XCTestCase {

    // MARK: - Parsing

    func testEmptyTextParsesWithDefaultFallbacks() {
        let file = FontMappingFile.parse("")
        XCTAssertTrue(file.mappings.isEmpty)
        XCTAssertEqual(file.fallbackMono, "Monaco")
        XCTAssertEqual(file.fallbackProp, "Helvetica Neue")
    }

    func testCommentLinesIgnored() {
        let file = FontMappingFile.parse("""
        # this is a comment
        ! so is this
        fixed  ->  Monaco  mono
        """)
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].family, "fixed")
        XCTAssertEqual(file.mappings[0].macFont, "Monaco")
        XCTAssertTrue(file.mappings[0].isMonospace)
    }

    func testMacFontWithSpaces() {
        // "Helvetica Neue" — multi-word mac font.
        let file = FontMappingFile.parse("helvetica  ->  Helvetica Neue  prop")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Helvetica Neue")
        XCTAssertFalse(file.mappings[0].isMonospace)
    }

    func testMacFontWithThreeWords() {
        let file = FontMappingFile.parse("times  ->  Times New Roman  prop")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Times New Roman")
    }

    func testMultiWordFamily() {
        // "new century schoolbook" — multi-word family on the left of `->`
        let file = FontMappingFile.parse("new century schoolbook  ->  Charter  prop")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].family, "new century schoolbook")
        XCTAssertEqual(file.mappings[0].macFont, "Charter")
    }

    func testFamilyNameLowercased() {
        let file = FontMappingFile.parse("FIXED  ->  Monaco  mono")
        XCTAssertEqual(file.mappings[0].family, "fixed")
    }

    func testFallbackKeysParsedSeparately() {
        let file = FontMappingFile.parse("""
        *fallback-mono  ->  Courier New      mono
        *fallback-prop  ->  Times New Roman  prop
        """)
        XCTAssertTrue(file.mappings.isEmpty)   // fallback keys don't go into mappings
        XCTAssertEqual(file.fallbackMono, "Courier New")
        XCTAssertEqual(file.fallbackProp, "Times New Roman")
    }

    func testMalformedLinesSkipped() {
        let file = FontMappingFile.parse("""
        fixed  ->  Monaco  mono
        garbage line with no arrow or kind
        no-arrow Helvetica prop
        helvetica  ->  Helvetica Neue  prop
        """)
        XCTAssertEqual(file.mappings.count, 2)
        XCTAssertEqual(file.mappings[0].family, "fixed")
        XCTAssertEqual(file.mappings[1].family, "helvetica")
    }

    func testMissingMonoPropTokenSkipped() {
        let file = FontMappingFile.parse("fixed  ->  Monaco")
        XCTAssertTrue(file.mappings.isEmpty)
    }

    // MARK: - Lookup

    func testResolveByFamilyIsCaseInsensitive() {
        let file = FontMappingFile.parse("courier  ->  Courier New  mono")
        XCTAssertEqual(file.resolve(family: "courier")?.macFont, "Courier New")
        XCTAssertEqual(file.resolve(family: "Courier")?.macFont, "Courier New")
        XCTAssertEqual(file.resolve(family: "COURIER")?.macFont, "Courier New")
    }

    func testResolveUnknownReturnsNil() {
        let file = FontMappingFile.parse("courier  ->  Courier New  mono")
        XCTAssertNil(file.resolve(family: "helvetica"))
    }

    func testFallbackRoutesOnSpacing() {
        let file = FontMappingFile.parse("""
        *fallback-mono  ->  Andale Mono  mono
        *fallback-prop  ->  Charter      prop
        """)
        XCTAssertEqual(file.fallback(spacing: "c").macFont, "Andale Mono")
        XCTAssertEqual(file.fallback(spacing: "m").macFont, "Andale Mono")
        XCTAssertEqual(file.fallback(spacing: "p").macFont, "Charter")
        XCTAssertEqual(file.fallback(spacing: "*").macFont, "Charter")
        XCTAssertEqual(file.fallback(spacing: "").macFont, "Charter")
    }

    // MARK: - Seed

    func testSeedParsesToExpectedTable() {
        let file = FontMappingFile.parse(DefaultFontMappings.seedContent)

        // Spot-check known mappings from SERVER_RESOLUTION_SCALING_AND_FONTS.md
        XCTAssertEqual(file.resolve(family: "fixed")?.macFont, "Monaco")
        XCTAssertEqual(file.resolve(family: "courier")?.macFont, "Courier New")
        XCTAssertEqual(file.resolve(family: "helvetica")?.macFont, "Helvetica Neue")
        XCTAssertEqual(file.resolve(family: "new century schoolbook")?.macFont, "Charter")
        XCTAssertEqual(file.resolve(family: "b&h-lucidatypewriter")?.macFont, "Andale Mono")

        // Fallbacks
        XCTAssertEqual(file.fallback(spacing: "c").macFont, "Monaco")
        XCTAssertEqual(file.fallback(spacing: "p").macFont, "Helvetica Neue")
    }

    func testSeedRoundTripsThroughFontResolver() {
        // Sanity-check the integration. After installMappings (which the
        // server does at startup), FontResolver.resolveFamily should
        // match the seed.
        FontResolver.installMappings()
        XCTAssertEqual(FontResolver.resolveFamily(family: "fixed", spacing: "c").name, "Monaco")
        XCTAssertEqual(FontResolver.resolveFamily(family: "helvetica", spacing: "p").name, "Helvetica Neue")
        XCTAssertEqual(FontResolver.resolveFamily(family: "unknown", spacing: "c").name, "Monaco")
        XCTAssertEqual(FontResolver.resolveFamily(family: "unknown", spacing: "p").name, "Helvetica Neue")
    }
}
