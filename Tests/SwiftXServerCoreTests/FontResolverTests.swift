import XCTest
import CoreText
@testable import SwiftXServerCore

final class FontResolverTests: XCTestCase {

    // MARK: - Aliases

    func testFixedAliasResolvesToMonacoNaturalCell() {
        let r = FontResolver.resolve(name: "fixed")
        XCTAssertEqual(r.macFontName, "Monaco")
        // Empirical: real macOS Monaco at integer pointSize 10 produces
        // a 6x13 cell. The 7x13 named alias asks for slightly wider; we
        // report what Monaco actually gives.
        XCTAssertEqual(r.cellWidth, 6)
        XCTAssertEqual(r.cellHeight, 13)
        XCTAssertEqual(r.pointSize, 10)
        XCTAssertTrue(r.isMonospace)
        XCTAssertFalse(r.bold)
        XCTAssertFalse(r.skewItalic)
    }

    func testCellAlias9x15DriftsToMonacoNaturalCell() {
        // Empirical: 9x15 → pointSize 11 → 7×15. Width drifts down to
        // Monaco's natural advance at 11pt; height matches the alias.
        let r = FontResolver.resolve(name: "9x15")
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertEqual(r.pointSize, 11)
        XCTAssertEqual(r.cellWidth, 7)
        XCTAssertEqual(r.cellHeight, 15)
    }

    func testCellAlias12x24() {
        // Empirical: 12x24 → pointSize 18 → 11×24. Height matches; width
        // drifts down by 1 because Monaco at 18pt produces a 10.8 logical
        // advance (rounds to 11). Closest integer-pointSize fit.
        let r = FontResolver.resolve(name: "12x24")
        XCTAssertEqual(r.cellWidth, 11)
        XCTAssertEqual(r.cellHeight, 24)
        XCTAssertEqual(r.pointSize, 18)
    }

    func testCellAlias7x14() {
        // Empirical: 7x14 → pointSize 10 → 6×13. Both dims drift down
        // by 1. Same Monaco-natural cell as 6x13, 7x13, 8x13, "fixed" —
        // the small-cell aliases collapse onto one rendering.
        let r = FontResolver.resolve(name: "7x14")
        XCTAssertEqual(r.cellWidth, 6)
        XCTAssertEqual(r.cellHeight, 13)
        XCTAssertEqual(r.pointSize, 10)
    }

    func testCellAliasAlwaysIntegerPointSize() {
        // The "iTerm2 lesson" property: pointSize is always an integer
        // for any alias, so Core Text's hinter lands on its sweet spot.
        for (w, h) in [(5, 7), (6, 10), (7, 13), (7, 14), (8, 13),
                       (8, 16), (9, 15), (10, 20), (12, 24)] {
            let r = FontResolver.resolve(name: "\(w)x\(h)")
            XCTAssertEqual(r.pointSize.rounded(), r.pointSize,
                           "pointSize for \(w)x\(h) must be integer, got \(r.pointSize)")
            XCTAssertGreaterThan(r.pointSize, 0)
        }
    }

    func testUnknownAliasFallsBackToMonacoDefault() {
        // Default falls back to a 7x14 request, which through the actual
        // Monaco metrics produces a 6x13 cell (same as the 7x14 alias).
        let r = FontResolver.resolve(name: "totally-not-a-font")
        XCTAssertEqual(r.macFontName, "Monaco")
        XCTAssertEqual(r.cellWidth, 6)
        XCTAssertEqual(r.cellHeight, 13)
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

    func testXLFDPixelSize14YieldsConsistentMetrics() {
        // Empirical: pixelSize=14 → pointSize 10 → cellHeight=13. xterm
        // builds its window from this reported cellHeight, not from the
        // requested 14 — that's the honest contract: report what we render.
        let xlfd = XLFD(family: "fixed", pixelSize: 14, spacing: "c")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.cellHeight, 13)
        XCTAssertEqual(r.pointSize, 10)
        XCTAssertGreaterThan(r.cellWidth, 0)
        XCTAssertLessThan(r.cellWidth, r.cellHeight)   // monospace narrower than tall
    }

    func testZeroPixelSizeDefaultsTo14() {
        // Empty pixelSize defaults to 14 internally, then maps through
        // the Monaco-natural-cell path. Same result as pixelSize=14.
        let xlfd = XLFD(family: "fixed", pixelSize: 0, spacing: "c")
        let r = FontResolver.resolve(xlfd: xlfd)
        XCTAssertEqual(r.cellHeight, 13)
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

    func testReportedMetricsAreSelfConsistent() {
        // Every resolver path produces metrics that hang together: cellWidth,
        // cellHeight, ascent, descent all derived from the same CTFont at
        // the same pointSize. xterm reads QueryFont and sizes its window
        // grid from these numbers; renderer uses the same numbers; what
        // xterm believes is what we draw.
        for name in ["fixed", "9x15", "7x14", "12x24", "10x20"] {
            let r = FontResolver.resolve(name: name)
            XCTAssertEqual(r.ascent + r.descent, r.cellHeight,
                           "ascent+descent invariant broken for \(name)")
            XCTAssertEqual(r.pointSize.rounded(), r.pointSize,
                           "pointSize for \(name) must be integer, got \(r.pointSize)")
        }
    }

    // MARK: - MOTIF_TEXT_QUALITY invariant

    func testIntegerAdvancesEqualReportedCharInfoWidths() {
        // The load-bearing invariant: for every glyph the renderer will
        // draw, the characterWidth a client reads back via QueryFont is
        // the same integer the renderer uses to position the next glyph.
        // Proven by funneling both through the same integerAdvances
        // helper — if a future refactor splits the paths, this test
        // catches the drift.
        let xlfd = XLFD(family: "helvetica", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        let range: ClosedRange<UInt16> = 32...127
        let payload = FontResolver.measureGlyphMetrics(r, range: range)
        let chars: [UniChar] = (range).map { $0 }
        let (_, advances) = FontResolver.integerAdvances(r, characters: chars)
        XCTAssertEqual(advances.count, payload.infos.count)
        for i in 0..<advances.count {
            XCTAssertEqual(Int(payload.infos[i].characterWidth), advances[i],
                           "CHARINFO.characterWidth[\(i)] must equal integerAdvances[\(i)]")
        }
    }

    func testMeasureTextWidthEqualsSumOfReportedCharInfoWidths() {
        // The QueryTextExtents reply must equal Σ CHARINFO.characterWidth
        // for the same glyphs, or Motif's menu-bar layout (which sums
        // CHARINFO) disagrees with what we promise QueryTextExtents.
        let xlfd = XLFD(family: "helvetica", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        let s = "File Edit View Help"
        let chars: [UniChar] = s.unicodeScalars.map { UniChar($0.value) }
        let reported = FontResolver.measureTextWidth(r, characters: chars)
        let payload = FontResolver.measureGlyphMetrics(r, range: 32...127)
        let summed = chars.reduce(Int32(0)) { acc, c in
            acc + Int32(payload.infos[Int(c) - 32].characterWidth)
        }
        XCTAssertEqual(reported, summed,
                       "measureTextWidth must equal Σ CHARINFO.characterWidth")
    }

    func testIntegerAdvancesAreCeilNotRound() {
        // Ceil is the side of the integer that can't go wrong: under-
        // reporting causes visible overlap, over-reporting leaves gaps
        // small enough no client notices. Confirm none of the reported
        // widths are below the natural CT advance.
        let xlfd = XLFD(family: "helvetica", pixelSize: 14, spacing: "p")
        let r = FontResolver.resolve(xlfd: xlfd)
        let chars: [UniChar] = Array(32...127)
        let (glyphs, advances) = FontResolver.integerAdvances(r, characters: chars)
        let font = CTFontCreateWithName(r.macFontName as CFString,
                                        CGFloat(r.pointSize), nil)
        var ctSizes = [CGSize](repeating: .zero, count: chars.count)
        var glyphsCopy = glyphs
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphsCopy, &ctSizes, chars.count)
        for i in 0..<chars.count where glyphs[i] != 0 {
            XCTAssertGreaterThanOrEqual(CGFloat(advances[i]), ctSizes[i].width,
                                        "advance[\(i)] (=\(advances[i])) must be ≥ natural CT advance \(ctSizes[i].width)")
            XCTAssertLessThan(CGFloat(advances[i]) - ctSizes[i].width, 1.0,
                              "ceil overshoot must be <1px for char \(i)")
        }
    }
}
