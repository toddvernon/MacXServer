import Foundation
import CoreText
import Framer

// XLFD / alias → Mac font + cell metrics resolver. Per the spec in
// SERVER_RESOLUTION_SCALING_AND_FONTS.md.
//
// As of 2026-05-09: iTerm2's playbook. Pick the largest integer pointSize
// where Monaco fits in both the requested width and height, then report the
// cell that Monaco actually produces at that pointSize — not the cell the
// XLFD asked for. Integer pointSize hits Core Text's hinter sweet spot
// (fractional sizes lose stem crispness, which produced the "feels bold"
// residue at 3× scale even with smoothing off). The XLFD's named cell
// dimensions become a hint of intended size, not a contract: xterm builds
// its grid from the metrics we report, so reporting what Monaco truly
// produces means glyphs land in cells that fit them.
//
// Produces a `ResolvedFont` with everything the renderer needs:
//   - PostScript-style font name for Core Text
//   - point size to instantiate at
//   - cell width / height in logical X pixels
//   - ascent / descent
//   - whether italic should be synthesised by skew (Monaco / Symbol have no
//     italic face) or use a real italic Mac font

public struct ResolvedFont: Equatable, Sendable {
    /// Mac font name suitable for `CTFontCreateWithName` (display name; Core
    /// Text accepts both display and PostScript names for system fonts).
    public var macFontName: String
    /// Point size to instantiate the CTFont at (logical, before scale).
    public var pointSize: Double
    /// Cell width in logical X pixels. For monospace, this is the advance.
    /// For proportional fonts, the maxBounds advance.
    public var cellWidth: Int
    /// Cell height in logical X pixels = ascent + descent.
    public var cellHeight: Int
    public var ascent: Int
    public var descent: Int
    public var isMonospace: Bool
    public var bold: Bool
    /// True when italic was requested but the Mac font has no real italic
    /// face — renderer should apply a 12° skew transform.
    public var skewItalic: Bool
    /// Charset registry (last-but-one XLFD field), e.g. "iso8859", "adobe",
    /// "jisx0201". Defaults to "iso8859" for aliases that don't specify.
    /// Used by QueryFont to decide the reported character range and to
    /// emit CHARSET_REGISTRY FONTPROPS that Motif's XCreateFontSet reads.
    public var charsetRegistry: String
    /// Charset encoding (last XLFD field), e.g. "1" for iso8859-1,
    /// "fontspecific" for adobe-fontspecific. Defaults to "1".
    public var charsetEncoding: String
}

public enum FontResolver {

    /// Top-level entry: try alias first (e.g., `fixed`, `9x15`), then full
    /// XLFD parse, then a defaulted Monaco 7×14 if the name is unrecognised.
    public static func resolve(name: String) -> ResolvedFont {
        if let alias = resolveAlias(name) { return alias }
        if let xlfd = XLFD.parse(name) { return resolve(xlfd: xlfd) }
        // Unknown / unparseable name. Default to Monaco 7×14 — same default
        // as bare `fixed`.
        return defaultMonacoFont(cellWidth: 7, cellHeight: 14, bold: false, skewItalic: false)
    }

    /// Recognised non-XLFD aliases:
    ///   - WxH cell aliases (5x7, 6x10, 7x14, 9x15, etc.)
    ///   - Word aliases: `fixed`, `cursor`
    public static func resolveAlias(_ name: String) -> ResolvedFont? {
        let n = name.lowercased()
        if let cell = parseCellAlias(n) {
            return defaultMonacoFont(
                cellWidth: cell.width, cellHeight: cell.height,
                bold: false, skewItalic: false
            )
        }
        switch n {
        case "fixed":
            // Per X conventions `fixed` typically aliases to a 7×13 Monaco-ish
            // font. xterm's default font when no `-fn` specified.
            return defaultMonacoFont(cellWidth: 7, cellHeight: 13, bold: false, skewItalic: false)
        case "cursor":
            // X cursor font is a special font of cursor glyphs. We don't
            // implement it as a real font yet — return a sentinel that the
            // dispatch layer can intercept. For Phase 1, just return Monaco
            // at a plausible cursor size; cursor work belongs in a separate
            // subsystem (see SERVER_RESOLUTION_SCALING_AND_FONTS Open Questions).
            return defaultMonacoFont(cellWidth: 8, cellHeight: 16, bold: false, skewItalic: false)
        default:
            return nil
        }
    }

    /// Resolve a fully-decoded XLFD.
    public static func resolve(xlfd: XLFD) -> ResolvedFont {
        let (familyName, isMono) = resolveFamily(family: xlfd.family, spacing: xlfd.spacing)
        let bold = xlfd.weight.lowercased() == "bold"
        let italic = xlfd.slant.lowercased() == "i" || xlfd.slant.lowercased() == "o"
        let skew = italic && !hasRealItalic(family: familyName)
        let pixelHeight = xlfd.pixelSize > 0 ? xlfd.pixelSize : 14
        let fontName = renderFontName(family: familyName, bold: bold, italic: italic && !skew)

        // Snap pointSize to the nearest integer where the font fits the
        // requested pixelHeight, then report the cell the font actually
        // produces. Integer pointSize is where Core Text's hinter does
        // its best work; reporting actual metrics means the QueryFont
        // reply matches what we render. xterm's window is sized from
        // these metrics, so it's truthful all the way through.
        let probe = ctMetrics(fontName: fontName)
        let pointSize = max(1, (Double(pixelHeight) / probe.lineHeightRatio).rounded())
        let cellWidth = max(1, Int(round(pointSize * probe.advanceRatio)))
        let cellHeight = max(1, Int(round(pointSize * probe.lineHeightRatio)))

        let actual = CTFontCreateWithName(fontName as CFString, CGFloat(pointSize), nil)
        let ascent = max(1, Int(ceil(CTFontGetAscent(actual))))
        let descent = max(1, cellHeight - ascent)

        // Charset: take whatever the XLFD requested, lowercased. Wildcards
        // ("*") fall back to iso8859-1 — Motif's XCreateFontSet for C
        // locale needs a real iso8859-1 match in the FontSet, so a
        // wildcard charset that resolves to iso8859-1 satisfies it.
        let registry = xlfd.charsetRegistry == "*" ? "iso8859" : xlfd.charsetRegistry.lowercased()
        let encoding = xlfd.charsetEncoding == "*" ? "1"       : xlfd.charsetEncoding.lowercased()

        return ResolvedFont(
            macFontName: fontName,
            pointSize: pointSize,
            cellWidth: cellWidth, cellHeight: cellHeight,
            ascent: ascent, descent: descent,
            isMonospace: isMono, bold: bold, skewItalic: skew,
            charsetRegistry: registry, charsetEncoding: encoding
        )
    }

    // MARK: - Substitution table

    /// Maps an XLFD family name (with optional spacing fallback for
    /// wildcards) to a Mac font family name. Per the substitution table in
    /// SERVER_RESOLUTION_SCALING_AND_FONTS.md.
    public static func resolveFamily(family: String, spacing: String) -> (name: String, isMonospace: Bool) {
        let f = family.lowercased()
        switch f {
        case "fixed", "misc-fixed":                               return ("Monaco", true)
        case "courier", "adobe-courier":                          return ("Courier New", true)
        case "lucidatypewriter", "b&h-lucidatypewriter":          return ("Andale Mono", true)
        case "terminal", "vt100", "screen":                       return ("Monaco", true)
        case "clean", "schumacher-clean":                         return ("Monaco", true)
        case "helvetica", "adobe-helvetica":                      return ("Helvetica Neue", false)
        case "times", "adobe-times":                              return ("Times New Roman", false)
        case "new century schoolbook", "adobe-new century schoolbook":
            return ("Charter", false)
        case "symbol", "adobe-symbol":                            return ("Symbol", false)
        default:
            // Wildcard or unknown family — fall back on spacing.
            switch spacing.lowercased() {
            case "c", "m":
                return ("Monaco", true)
            default:
                return ("Helvetica Neue", false)
            }
        }
    }

    // MARK: - Helpers

    /// Parse "9x15" / "7x14" / etc. into (width, height). Returns nil for
    /// anything else.
    public static func parseCellAlias(_ s: String) -> (width: Int, height: Int)? {
        let parts = s.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let w = Int(parts[0]),
              let h = Int(parts[1]),
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Build a Monaco-based ResolvedFont. Used for aliases like `7x14` and
    /// the `fixed` default.
    ///
    /// `requestedW` × `requestedH` is the cell the alias names. We snap
    /// pointSize to the nearest integer that fits within both, then
    /// re-measure: cellWidth and cellHeight come from Monaco's actual
    /// advance and line-height at the snapped pointSize, NOT from the
    /// requested values. iTerm2's lesson — fit the cell to the font, not
    /// the font to the cell. xterm sizes its window from these metrics,
    /// so reporting the truth means glyphs fit cleanly.
    ///
    /// Most aliases land where the user expects (7x14 stays 7x14 because
    /// 12pt Monaco produces ~7.2 × 14.4 → rounds back to 7×14). A few
    /// drift slightly: 9x15 becomes 8x16 because Monaco's 1:1.78 natural
    /// aspect doesn't fit 1:1.67 at any integer size, so we land on the
    /// nearest natural cell.
    private static func defaultMonacoFont(cellWidth requestedW: Int, cellHeight requestedH: Int, bold: Bool, skewItalic: Bool) -> ResolvedFont {
        let name = bold ? "Monaco Bold" : "Monaco"
        let probe = ctMetrics(fontName: name)
        let pointFromWidth  = Double(requestedW) / probe.advanceRatio
        let pointFromHeight = Double(requestedH) / probe.lineHeightRatio
        let pointSize = max(1, min(pointFromWidth, pointFromHeight).rounded())
        let cellWidth = max(1, Int(round(pointSize * probe.advanceRatio)))
        let cellHeight = max(1, Int(round(pointSize * probe.lineHeightRatio)))
        let actual = CTFontCreateWithName(name as CFString, CGFloat(pointSize), nil)
        let ascent = max(1, Int(ceil(CTFontGetAscent(actual))))
        let descent = max(1, cellHeight - ascent)
        return ResolvedFont(
            macFontName: name,
            pointSize: pointSize,
            cellWidth: cellWidth, cellHeight: cellHeight,
            ascent: ascent, descent: descent,
            isMonospace: true, bold: bold, skewItalic: skewItalic,
            charsetRegistry: "iso8859", charsetEncoding: "1"
        )
    }

    /// Per-em ratios for a Mac font, probed via Core Text. Using a 100pt
    /// probe (then dividing) gets enough precision that the resulting
    /// ratios round to stable integer cell metrics at any reasonable
    /// rendering point size. CTFont creation is cheap and macOS caches
    /// internally, so we don't memoise.
    private struct CTMetrics {
        /// Advance of 'M' / pointSize. ~0.6 for Monaco, ~0.6 for Andale.
        let advanceRatio: Double
        /// (ascent + descent + leading) / pointSize. Monaco ≈ 1.2.
        let lineHeightRatio: Double
    }

    private static func ctMetrics(fontName: String) -> CTMetrics {
        let probeSize: CGFloat = 100
        let f = CTFontCreateWithName(fontName as CFString, probeSize, nil)
        let ascent = Double(CTFontGetAscent(f))
        let descent = Double(CTFontGetDescent(f))
        let leading = Double(CTFontGetLeading(f))
        let lineHeight = ascent + descent + leading

        var glyph: CGGlyph = 0
        var ch: UniChar = 0x4D    // 'M' — typical advance for monospace
        CTFontGetGlyphsForCharacters(f, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(f, .horizontal, &glyph, &advance, 1)

        return CTMetrics(
            advanceRatio: Double(advance.width) / Double(probeSize),
            lineHeightRatio: lineHeight / Double(probeSize)
        )
    }

    /// Per-glyph integer advance for a UniChar sequence in the resolved
    /// font. THE single source of truth for the MOTIF_TEXT_QUALITY
    /// invariant: every caller that reports a glyph's width (CHARINFO,
    /// QueryTextExtents) or positions a glyph for drawing (PolyText8
    /// renderer) must read from here, so reported widths === rendered
    /// positions, byte for byte.
    ///
    /// Two playbooks, dispatched on isMonospace:
    ///   - Monospace (xterm/dtterm): every glyph reports `resolved.cellWidth`.
    ///     drawImageText8 positions at `i*cellW` and CHARINFO must agree —
    ///     cell IS the advance, single number. (CT's per-glyph natural
    ///     advance for Monaco can drift up by ~1px from the cell metrics
    ///     ratio if we ceil naively, which would break the xterm grid.)
    ///   - Proportional (Helvetica/Times/etc): per-glyph ceil of the
    ///     natural CT advance. drawPolyText8 sums these for positioning.
    ///     Ceil is the side that can't go wrong: under-reporting causes
    ///     visible overlap, over-reporting leaves sub-pixel gaps no
    ///     client notices.
    ///
    /// Missing glyphs (CT returns glyph 0) always report 0 to match the
    /// zero CharInfo emitted for missing glyphs in QueryFont.
    public static func integerAdvances(_ resolved: ResolvedFont,
                                       characters: [UniChar])
        -> (glyphs: [CGGlyph], advances: [Int])
    {
        let n = characters.count
        guard n > 0 else { return ([], []) }
        let font = CTFontCreateWithName(
            resolved.macFontName as CFString,
            CGFloat(resolved.pointSize), nil
        )
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var chars = characters
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, n)

        var advances = [Int](repeating: 0, count: n)
        if resolved.isMonospace {
            for i in 0..<n {
                advances[i] = glyphs[i] == 0 ? 0 : resolved.cellWidth
            }
        } else {
            var ctAdvances = [CGSize](repeating: .zero, count: n)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &ctAdvances, n)
            for i in 0..<n {
                advances[i] = glyphs[i] == 0 ? 0 : Int(ceil(ctAdvances[i].width))
            }
        }
        return (glyphs, advances)
    }

    /// Sum of per-glyph integer advances. Returned width matches
    /// `Σ integerAdvances(...).advances` exactly, which is what the
    /// renderer lays down. Used by QueryTextExtents.
    public static func measureTextWidth(_ resolved: ResolvedFont, characters: [UniChar]) -> Int32 {
        let (_, advances) = integerAdvances(resolved, characters: characters)
        return Int32(clamping: advances.reduce(0, +))
    }

    /// Per-glyph metrics over a UniChar range, in the format QueryFontReply's
    /// CHARINFO array expects. Per X spec:
    ///   - lsb: x-offset from origin to leftmost ink (signed; negative for
    ///          italic glyphs that extend left of origin)
    ///   - rsb: x-offset from origin to rightmost ink
    ///   - characterWidth: horizontal advance to next glyph's origin
    ///   - ascent / descent: ink-box height above / below baseline (positive)
    /// Missing-glyph entries (CT returns glyph index 0) are reported as
    /// all-zeros CharInfo per spec convention; `allExist` flips false when
    /// any glyph is missing so the reply's allCharsExist bit reads correctly.
    public struct GlyphMetricsPayload {
        public var infos: [CharInfo]
        public var allExist: Bool
    }

    public static func measureGlyphMetrics(_ resolved: ResolvedFont,
                                           range: ClosedRange<UInt16>) -> GlyphMetricsPayload {
        let count = Int(range.upperBound - range.lowerBound) + 1
        var chars: [UniChar] = []
        chars.reserveCapacity(count)
        for c in range { chars.append(c) }

        // characterWidth comes from the shared integerAdvances path so
        // reporters and renderer can't drift. lsb/rsb/asc/desc are
        // bbox-derived ink metrics, unrelated to the advance invariant.
        let (glyphs, advances) = integerAdvances(resolved, characters: chars)

        let font = CTFontCreateWithName(
            resolved.macFontName as CFString,
            CGFloat(resolved.pointSize), nil
        )
        var bboxes = [CGRect](repeating: .zero, count: count)
        var glyphsForBbox = glyphs
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphsForBbox, &bboxes, count)

        var infos: [CharInfo] = []
        infos.reserveCapacity(count)
        var allExist = true
        for i in 0..<count {
            if glyphs[i] == 0 {
                infos.append(CharInfo(
                    leftSideBearing: 0, rightSideBearing: 0,
                    characterWidth: 0, ascent: 0, descent: 0, attributes: 0
                ))
                allExist = false
                continue
            }
            let bbox = bboxes[i]
            let lsb = Int(bbox.origin.x.rounded(.down))
            let rsb = Int((bbox.origin.x + bbox.size.width).rounded(.up))
            let asc = max(0, Int((bbox.origin.y + bbox.size.height).rounded(.up)))
            let desc = max(0, Int((-bbox.origin.y).rounded(.up)))
            infos.append(CharInfo(
                leftSideBearing: Int16(clamping: lsb),
                rightSideBearing: Int16(clamping: rsb),
                characterWidth: Int16(clamping: advances[i]),
                ascent: Int16(clamping: asc),
                descent: Int16(clamping: desc),
                attributes: 0
            ))
        }
        return GlyphMetricsPayload(infos: infos, allExist: allExist)
    }

    /// Mac font name including bold/italic variants. We only emit names that
    /// are known to exist on macOS — for italic where no real face exists
    /// (Monaco, Symbol), we drop the italic suffix; the caller is expected
    /// to apply skew via `skewItalic = true`.
    private static func renderFontName(family: String, bold: Bool, italic: Bool) -> String {
        switch family {
        case "Monaco":
            return bold ? "Monaco Bold" : "Monaco"
        case "Courier New":
            if bold && italic { return "Courier New Bold Italic" }
            if bold { return "Courier New Bold" }
            if italic { return "Courier New Italic" }
            return "Courier New"
        case "Andale Mono":
            // No italic / bold variants ship on macOS; base name only.
            return "Andale Mono"
        case "Helvetica Neue":
            if bold && italic { return "HelveticaNeue-BoldItalic" }
            if bold { return "HelveticaNeue-Bold" }
            if italic { return "HelveticaNeue-Italic" }
            return "HelveticaNeue"
        case "Times New Roman":
            if bold && italic { return "Times New Roman Bold Italic" }
            if bold { return "Times New Roman Bold" }
            if italic { return "Times New Roman Italic" }
            return "Times New Roman"
        case "Charter":
            if bold && italic { return "Charter Bold Italic" }
            if bold { return "Charter Bold" }
            if italic { return "Charter Italic" }
            return "Charter"
        case "Symbol":
            return "Symbol"
        default:
            return family
        }
    }

    /// Whether the Mac font family has a real italic face on macOS. Drives
    /// the `skewItalic` flag — false means we apply a 12° skew, true means
    /// we use the real italic name.
    private static func hasRealItalic(family: String) -> Bool {
        switch family {
        case "Courier New", "Helvetica Neue", "Times New Roman", "Charter":
            return true
        default:
            // Monaco, Andale Mono, Symbol: no real italic face.
            return false
        }
    }
}
