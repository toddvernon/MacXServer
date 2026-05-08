import Foundation

// XLFD / alias → Mac font + cell metrics resolver. Pure data; no Core Text
// here so this is unit-testable headless. Per the spec in
// SERVER_RESOLUTION_SCALING_AND_FONTS.md.
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

        // Cell sizing per the spec, height-driven for arbitrary XLFDs:
        //   pixelHeight = xlfd.pixelSize (or 14 default if 0)
        //   pointSize   = pixelHeight / 1.2      (Monaco's actual line-height
        //                                         ratio on macOS — ascent/em
        //                                         ≈ 0.9, descent/em ≈ 0.21,
        //                                         lineGap ≈ 0.09; total ~1.2)
        //   cellWidth   = round(pointSize * 0.6)
        //   cellHeight  = pixelHeight
        let pixelHeight = xlfd.pixelSize > 0 ? xlfd.pixelSize : 14
        let pointSize = Double(pixelHeight) / 1.2
        let cellWidth = max(1, Int(round(pointSize * 0.6)))
        let cellHeight = pixelHeight
        let ascent = Int(ceil(pointSize * 0.85))
        let descent = max(1, cellHeight - ascent)

        let fontName = renderFontName(family: familyName, bold: bold, italic: italic && !skew)

        return ResolvedFont(
            macFontName: fontName,
            pointSize: pointSize,
            cellWidth: cellWidth, cellHeight: cellHeight,
            ascent: ascent, descent: descent,
            isMonospace: isMono, bold: bold, skewItalic: skew
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

    /// Build a Monaco-based ResolvedFont with a forced cell size. Used for
    /// aliases like `7x14` and the `fixed` default.
    ///
    /// Point size is the largest where Monaco fits in BOTH cell dimensions.
    /// Monaco's natural ratios on macOS: advance ≈ 0.6 × pointSize, total
    /// line-height ≈ 1.2 × pointSize (ascent ~0.9·em + descent ~0.21·em +
    /// small lineGap). Driving pointSize from cellWidth alone (the
    /// originally shipped behavior) made the glyph natural-height exceed
    /// cellHeight whenever the alias was wider than tall — `g`/`y`
    /// descenders bled into the next line and the over-sized glyph filled
    /// more of the cell, reading as "bold". An interim fix used 1.07 as
    /// the height ratio; that turned out to underestimate Monaco's actual
    /// line height, leaving lines still too tight at small cell aliases.
    /// Taking min(width-derived, height-derived) keeps the glyph entirely
    /// inside the requested cell; the loose dimension just gets a little
    /// extra leading/padding.
    private static func defaultMonacoFont(cellWidth: Int, cellHeight: Int, bold: Bool, skewItalic: Bool) -> ResolvedFont {
        let pointFromWidth  = Double(cellWidth)  / 0.6
        let pointFromHeight = Double(cellHeight) / 1.2
        let pointSize = min(pointFromWidth, pointFromHeight)
        let ascent = Int(ceil(pointSize * 0.85))
        let descent = max(1, cellHeight - ascent)
        let name = bold ? "Monaco Bold" : "Monaco"
        return ResolvedFont(
            macFontName: name,
            pointSize: pointSize,
            cellWidth: cellWidth, cellHeight: cellHeight,
            ascent: ascent, descent: descent,
            isMonospace: true, bold: bold, skewItalic: skewItalic
        )
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
