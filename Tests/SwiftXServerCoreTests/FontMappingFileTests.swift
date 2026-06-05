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
        fixed  ->  Monaco
        """)
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].family, "fixed")
        XCTAssertEqual(file.mappings[0].macFont, "Monaco")
    }

    func testMacFontWithSpaces() {
        // "Helvetica Neue" — multi-word mac font.
        let file = FontMappingFile.parse("helvetica  ->  Helvetica Neue")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Helvetica Neue")
    }

    func testMacFontWithThreeWords() {
        let file = FontMappingFile.parse("times  ->  Times New Roman")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Times New Roman")
    }

    func testMultiWordFamily() {
        // "new century schoolbook" — multi-word family on the left of `->`
        let file = FontMappingFile.parse("new century schoolbook  ->  Charter")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].family, "new century schoolbook")
        XCTAssertEqual(file.mappings[0].macFont, "Charter")
    }

    func testFamilyNameLowercased() {
        let file = FontMappingFile.parse("FIXED  ->  Monaco")
        XCTAssertEqual(file.mappings[0].family, "fixed")
    }

    // The user-facing format includes an optional trailing `mono` / `prop`
    // token to document the spacing kind (see DefaultFontMappings header
    // comment). It's informational only -- isMonospace is derived from
    // CTFontGetSymbolicTraits -- so the parser must drop it. Without this,
    // resolve("fixed") returned "Monaco mono" and CTFont silently fell back
    // to Helvetica; the breakage surfaced as test-suite-only "Monaco mono"
    // failures in FontResolverTests once FontMappingFileTests had loaded
    // the developer's real ~/.macxserver-fonts.
    func testTrailingMonoTokenStripped() {
        let file = FontMappingFile.parse("fixed  ->  Monaco  mono")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].family, "fixed")
        XCTAssertEqual(file.mappings[0].macFont, "Monaco")
    }

    func testTrailingPropTokenStripped() {
        let file = FontMappingFile.parse("helvetica  ->  Helvetica Neue  prop")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Helvetica Neue")
    }

    // Capitalized "Mono" / "Prop" are NOT spacing tokens -- they're part of
    // font names ("Andale Mono", or hypothetically a "Foo Prop" face). The
    // documented format uses lowercase `mono` / `prop` only, and the parser
    // matches strictly. Tests against "Andale Mono" elsewhere rely on this.
    func testCapitalizedMonoStaysAsPartOfMacFontName() {
        let file = FontMappingFile.parse("lucidatypewriter  ->  Andale Mono")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Andale Mono")
    }

    func testNoTrailingTokenStillParses() {
        // Old format without the trailing token must keep working.
        let file = FontMappingFile.parse("fixed  ->  Monaco")
        XCTAssertEqual(file.mappings[0].macFont, "Monaco")
    }

    // Edge case: a one-word mac font that happens to equal the spacing
    // token. The parser must NOT strip it -- the trailing-token rule only
    // applies when at least one mac-font word would survive.
    func testSingleWordMacFontNamedMonoNotStripped() {
        let file = FontMappingFile.parse("weird  ->  mono")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "mono")
    }

    func testFallbackKeysParsedSeparately() {
        let file = FontMappingFile.parse("""
        *fallback-mono  ->  Courier New
        *fallback-prop  ->  Times New Roman
        """)
        XCTAssertTrue(file.mappings.isEmpty)   // fallback keys don't go into mappings
        XCTAssertEqual(file.fallbackMono, "Courier New")
        XCTAssertEqual(file.fallbackProp, "Times New Roman")
    }

    func testMalformedLinesSkipped() {
        let file = FontMappingFile.parse("""
        fixed  ->  Monaco
        garbage line with no arrow
        no-arrow Helvetica
        helvetica  ->  Helvetica Neue
        """)
        XCTAssertEqual(file.mappings.count, 2)
        XCTAssertEqual(file.mappings[0].family, "fixed")
        XCTAssertEqual(file.mappings[1].family, "helvetica")
    }

    func testMissingMacFontSkipped() {
        // `->` with nothing after it
        let file = FontMappingFile.parse("fixed  ->")
        XCTAssertTrue(file.mappings.isEmpty)
    }

    func testMultiWordMacFontWithCapitalMonoPreserved() {
        // "Andale Mono" — the trailing "Mono" is part of the font
        // name. The parser takes everything after `->` verbatim, so
        // there's no risk of it being mis-stripped.
        let file = FontMappingFile.parse("lucidatypewriter  ->  Andale Mono")
        XCTAssertEqual(file.mappings.count, 1)
        XCTAssertEqual(file.mappings[0].macFont, "Andale Mono")
    }

    // MARK: - Lookup

    func testResolveByFamilyIsCaseInsensitive() {
        let file = FontMappingFile.parse("courier  ->  Courier New")
        XCTAssertEqual(file.resolve(family: "courier"), "Courier New")
        XCTAssertEqual(file.resolve(family: "Courier"), "Courier New")
        XCTAssertEqual(file.resolve(family: "COURIER"), "Courier New")
    }

    func testResolveUnknownReturnsNil() {
        let file = FontMappingFile.parse("courier  ->  Courier New")
        XCTAssertNil(file.resolve(family: "helvetica"))
    }

    func testFallbackRoutesOnSpacing() {
        let file = FontMappingFile.parse("""
        *fallback-mono  ->  Andale Mono
        *fallback-prop  ->  Charter
        """)
        XCTAssertEqual(file.fallback(spacing: "c"), "Andale Mono")
        XCTAssertEqual(file.fallback(spacing: "m"), "Andale Mono")
        XCTAssertEqual(file.fallback(spacing: "p"), "Charter")
        XCTAssertEqual(file.fallback(spacing: "*"), "Charter")
        XCTAssertEqual(file.fallback(spacing: ""), "Charter")
    }

    // MARK: - Seed

    func testSeedParsesToExpectedTable() {
        let file = FontMappingFile.parse(DefaultFontMappings.seedContent)

        // Spot-check known mappings from SERVER_RESOLUTION_SCALING_AND_FONTS.md
        XCTAssertEqual(file.resolve(family: "fixed"), "Monaco")
        XCTAssertEqual(file.resolve(family: "courier"), "Courier New")
        XCTAssertEqual(file.resolve(family: "helvetica"), "Helvetica Neue")
        XCTAssertEqual(file.resolve(family: "new century schoolbook"), "Charter")
        XCTAssertEqual(file.resolve(family: "b&h-lucidatypewriter"), "Andale Mono")

        // Fallbacks
        XCTAssertEqual(file.fallback(spacing: "c"), "Monaco")
        XCTAssertEqual(file.fallback(spacing: "p"), "Helvetica Neue")
    }

    func testSeedRoundTripsThroughFontResolver() {
        // Sanity-check the integration. After installMappings, FontResolver
        // .resolveFamily should match the seed. Use the in-memory variant
        // so we don't pull the developer's actual ~/.macxserver-fonts into the
        // shared static (which leaked across tests before 2026-05-30,
        // making FontResolverTests fail in full-suite runs but pass in
        // isolation). tearDown restores the seed for any later test that
        // relies on the default mapping state.
        FontResolver.installMappings(file: FontMappingFile.parse(DefaultFontMappings.seedContent))
        let monaco = FontResolver.resolveFamily(family: "fixed", spacing: "c")
        XCTAssertEqual(monaco.name, "Monaco")
        XCTAssertTrue(monaco.isMonospace)

        let helvetica = FontResolver.resolveFamily(family: "helvetica", spacing: "p")
        XCTAssertEqual(helvetica.name, "Helvetica Neue")
        XCTAssertFalse(helvetica.isMonospace)

        let unknownMono = FontResolver.resolveFamily(family: "unknown", spacing: "c")
        XCTAssertEqual(unknownMono.name, "Monaco")
        XCTAssertTrue(unknownMono.isMonospace)

        let unknownProp = FontResolver.resolveFamily(family: "unknown", spacing: "p")
        XCTAssertEqual(unknownProp.name, "Helvetica Neue")
        XCTAssertFalse(unknownProp.isMonospace)
    }

    override func tearDown() {
        // Restore the in-memory seed after any test that mutated the
        // shared FontResolver.loadedMappings static. Belt-and-suspenders
        // for the test-isolation issue called out above.
        FontResolver.installMappings(file: FontMappingFile.parse(DefaultFontMappings.seedContent))
        super.tearDown()
    }

    // MARK: - isMonospace derivation

    func testCTFontMonospaceTraitDetected() {
        // Truth comes from CTFontGetSymbolicTraits, not the file.
        XCTAssertTrue(FontResolver.isMonospaceFont("Monaco"))
        XCTAssertTrue(FontResolver.isMonospaceFont("Courier New"))
        XCTAssertTrue(FontResolver.isMonospaceFont("Andale Mono"))
        XCTAssertFalse(FontResolver.isMonospaceFont("Helvetica Neue"))
        XCTAssertFalse(FontResolver.isMonospaceFont("Times New Roman"))
        XCTAssertFalse(FontResolver.isMonospaceFont("Charter"))
    }
}
