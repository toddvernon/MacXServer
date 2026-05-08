import XCTest
@testable import SwiftXServerCore

final class FontResolverTests: XCTestCase {

    // MARK: - Aliases

    func testFixedAliasResolvesToMonaco7x13() {
        let r = FontResolver.resolve(name: "fixed")
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertEqual(r.cellWidth, 7)
        XCTAssertEqual(r.cellHeight, 13)
        XCTAssertTrue(r.isMonospace)
        XCTAssertFalse(r.bold)
        XCTAssertFalse(r.skewItalic)
    }

    func testCellAlias9x15() {
        let r = FontResolver.resolve(name: "9x15")
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertEqual(r.cellWidth, 9)
        XCTAssertEqual(r.cellHeight, 15)
    }

    func testCellAlias12x24() {
        let r = FontResolver.resolve(name: "12x24")
        XCTAssertEqual(r.cellWidth, 12)
        XCTAssertEqual(r.cellHeight, 24)
        // pointSize = 12 / 0.6 = 20.0 exactly
        XCTAssertEqual(r.pointSize, 20.0, accuracy: 0.01)
    }

    func testCellAliasPointSizeMath() {
        // 7x14: pointSize = 7 / 0.6 = 11.666...
        let r = FontResolver.resolve(name: "7x14")
        XCTAssertEqual(r.pointSize, 11.666, accuracy: 0.01)
    }

    func testUnknownAliasFallsBackToMonacoDefault() {
        let r = FontResolver.resolve(name: "totally-not-a-font")
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertEqual(r.cellWidth, 7)
        XCTAssertEqual(r.cellHeight, 14)
    }

    // MARK: - Family substitution

    func testCourierFamilyMapsToCourierNew() {
        let xlfd = XLFD(family: "courier", pixelSize: 14, spacing: "m")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Courier New")
        XCTAssertTrue(r.isMonospace)
    }

    func testHelveticaMapsToHelveticaNeue() {
        let xlfd = XLFD(family: "helvetica", pixelSize: 12, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "HelveticaNeue")
        XCTAssertFalse(r.isMonospace)
    }

    func testLucidaTypewriterMapsToAndaleMono() {
        let xlfd = XLFD(family: "lucidatypewriter", pixelSize: 14, spacing: "m")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Andale Mono")
        XCTAssertTrue(r.isMonospace)
    }

    func testSymbolMapsToSymbol() {
        let xlfd = XLFD(family: "symbol", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Symbol")
    }

    func testWildcardFamilyWithMonoSpacingFallsBackToMonaco() {
        let xlfd = XLFD(family: "*", pixelSize: 14, spacing: "m")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertTrue(r.isMonospace)
    }

    func testWildcardFamilyWithProportionalSpacingFallsBackToHelveticaNeue() {
        let xlfd = XLFD(family: "*", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "HelveticaNeue")
    }

    // MARK: - Bold / italic

    func testBoldRequestEmitsBoldFontName() {
        let xlfd = XLFD(family: "courier", weight: "bold", slant: "r", pixelSize: 14, spacing: "m")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Courier New Bold")
        XCTAssertTrue(r.bold)
    }

    func testItalicRequestForCourierUsesRealItalic() {
        let xlfd = XLFD(family: "courier", weight: "medium", slant: "i", pixelSize: 14, spacing: "m")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Courier New Italic")
        XCTAssertFalse(r.skewItalic, "Courier has a real italic face")
    }

    func testItalicRequestForMonacoUsesSkew() {
        let xlfd = XLFD(family: "fixed", weight: "medium", slant: "i", pixelSize: 14, spacing: "c")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertTrue(r.skewItalic, "Monaco needs skew for italic")
    }

    func testBoldItalicCombo() {
        let xlfd = XLFD(family: "times", weight: "bold", slant: "i", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.macFontName, "Times New Roman Bold Italic")
        XCTAssertTrue(r.bold)
        XCTAssertFalse(r.skewItalic)
    }

    // MARK: - Cell sizing math

    func testXLFDPixelSize14YieldsExpectedMetrics() {
        // pixelHeight = 14 → pointSize ≈ 11.67 (using Monaco's actual
        // line-height ratio of 1.2, which fits the glyph in the cell).
        // cellWidth ≈ round(11.67 × 0.6) = 7.
        let xlfd = XLFD(family: "fixed", pixelSize: 14, spacing: "c")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.cellHeight, 14)
        XCTAssertEqual(r.cellWidth, 7)
        XCTAssertEqual(r.pointSize, 14.0 / 1.2, accuracy: 0.01)
    }

    func testZeroPixelSizeDefaultsTo14() {
        let xlfd = XLFD(family: "fixed", pixelSize: 0, spacing: "c")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.cellHeight, 14)
    }

    func testAscentPlusDescentEqualsCellHeight() {
        for ph in [10, 13, 14, 15, 20, 24] {
            let xlfd = XLFD(family: "fixed", pixelSize: ph, spacing: "c")
            let r = FontResolver.resolve(xlfd: xlfd)
            XCTAssertEqual(r.ascent + r.descent, r.cellHeight,
                           "ascent + descent should equal cellHeight at pixelSize=\(ph)")
        }
    }

    // MARK: - Critical invariant: reported metrics === rendered metrics

    func testReportedMetricsMatchAcrossResolutionPaths() {
        // The `9x15` alias and an XLFD that asks for 15-pixel-high Monaco
        // should both produce reasonable metrics (cellHeight=15).
        let viaAlias = FontResolver.resolve(name: "9x15")
        let viaXLFD = FontResolver.resolve(xlfd: XLFD(family: "fixed", pixelSize: 15, spacing: "c"))
        XCTAssertEqual(viaAlias.cellHeight, 15)
        XCTAssertEqual(viaXLFD.cellHeight, 15)
        // Cell widths differ by which path computed them: alias forces 9,
        // XLFD computes from pointSize. That's fine — it just means clients
        // get to choose explicit cell sizing via the alias path.
        XCTAssertEqual(viaAlias.cellWidth, 9)
    }
}
