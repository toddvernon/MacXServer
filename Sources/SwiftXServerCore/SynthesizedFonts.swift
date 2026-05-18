import Foundation

// Phase 1 xlsfonts synthesis per SERVER_RESOLUTION_SCALING_AND_FONTS.md.
// ~30-40 entries: named cell aliases + each substitute family at 8/10/12/14/16
// pt, medium/bold roman in iso10646-1. Phase 4 expands to full italic +
// iso8859-1 cross product (~100 entries).

public enum SynthesizedFonts {

    /// All Phase-1 entries (aliases + XLFDs). Returned as raw byte arrays
    /// suitable for placing directly into a `ListFontsReply.names`.
    public static let phase1Names: [[UInt8]] = {
        var names: [String] = []

        // Word aliases that real apps look up directly.
        names.append("fixed")
        names.append("cursor")

        // Cell aliases (from the doc's cell-sizing table).
        for (w, h) in cellAliases {
            names.append("\(w)x\(h)")
        }

        // XLFDs for each substitute family at the common sizes.
        for family in xlfdFamilies {
            for sz in pointSizes {
                for weight in ["medium", "bold"] {
                    names.append(makeXLFD(
                        family: family,
                        weight: weight,
                        slant: "r",
                        pointTenths: sz * 10,
                        spacing: family.spacing
                    ))
                }
            }
        }

        return names.map { Array($0.utf8) }
    }()

    /// Filter `phase1Names` by an X-style pattern. The pattern uses `*` and
    /// `?` wildcards; we do a simple lowercase fnmatch-style match.
    ///
    /// Three-layer lookup, in order:
    ///
    ///   1. **Overrides** (curated). The `overrides` table maps a wildcard
    ///      pattern to a hand-picked list of names. Used when a specific
    ///      X client needs a specific X-protocol font response we'd
    ///      otherwise not produce. Starts empty; entries get added with a
    ///      `// app:` comment naming the app they unblock. Override
    ///      matches are checked FIRST so curated entries always win.
    ///   2. **Synthesized list**. The Phase-1 names — cell aliases plus
    ///      our substitution-table families at common sizes. The "truth"
    ///      tier: what we'd report to an honest enumerator (xfontsel).
    ///   3. **Echo fallback**. If neither of the above matched AND the
    ///      pattern has a concrete (non-wildcard) CHARSET_REGISTRY-
    ///      CHARSET_ENCODING suffix, return the pattern itself as a
    ///      single match. Motif's `XCreateFontSet` does suffix-compare
    ///      on the returned name against the required charset; with the
    ///      echo, dt-Motif `-dt-interface ...-iso8859-1` probes find a
    ///      match and the FontSet builder accepts it. Our OpenFont/
    ///      QueryFont accept any XLFD shape, so OpenFonting the echoed
    ///      name yields a sensible substituted CTFont. Without this,
    ///      Motif emits "Cannot convert string ... to type FontSet"
    ///      warnings and widgets render with no usable font (button
    ///      labels invisible). Bounded by the "concrete charset suffix"
    ///      gate so wildcard enumerators (xfontsel pattern="*") still
    ///      see the honest synth list.
    public static func match(pattern: String, max: Int) -> [[UInt8]] {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        let lowerPattern = trimmed.lowercased()

        // Layer 1: curated overrides.
        for ov in overrides where wildcardMatch(pattern: ov.pattern.lowercased(), string: lowerPattern) {
            let names = ov.names.prefix(max).map { Array($0.utf8) }
            return Array(names)
        }

        // Layer 2: synthesized list. The "*" or empty pattern is the
        // enumerate-everything case — return phase1Names directly.
        if trimmed.isEmpty || trimmed == "*" {
            return Array(phase1Names.prefix(max))
        }
        let synth = phase1Names.compactMap { bytes -> [UInt8]? in
            let s = String(decoding: bytes, as: UTF8.self).lowercased()
            return wildcardMatch(pattern: lowerPattern, string: s) ? bytes : nil
        }
        if !synth.isEmpty {
            return Array(synth.prefix(max))
        }

        // Layer 3: echo fallback. Only kicks in for XLFD-shaped patterns
        // with concrete charset suffix. Returns the pattern itself.
        if patternHasConcreteCharsetSuffix(trimmed) {
            return [Array(trimmed.utf8)]
        }
        return []
    }

    /// Curated override entries. Each entry maps a wildcard pattern to a
    /// list of names that a specific X client needs to find in ListFonts.
    /// Add with a `// app:` comment naming the app and why. Starts empty.
    /// Policy: only add when the echo-fallback path doesn't satisfy a
    /// client AND the client is one we host.
    private static let overrides: [(pattern: String, names: [String])] = [
        // (Future entries go here.)
    ]

    /// True when an XLFD pattern's last two fields (CHARSET_REGISTRY-
    /// CHARSET_ENCODING) are concrete strings rather than `*` wildcards.
    /// Used by the echo-fallback layer to avoid lying to wildcard
    /// enumerators while still answering Motif's per-charset probes.
    private static func patternHasConcreteCharsetSuffix(_ pattern: String) -> Bool {
        guard pattern.hasPrefix("-") else { return false }
        let parts = pattern.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 14 else { return false }
        let registry = parts[12]
        let encoding = parts[13]
        return !registry.contains("*") && !encoding.contains("*")
            && !registry.isEmpty && !encoding.isEmpty
    }

    // MARK: - Tables

    /// Cell aliases from SERVER_RESOLUTION_SCALING_AND_FONTS.md.
    private static let cellAliases: [(Int, Int)] = [
        (5, 7), (5, 8),
        (6, 10), (6, 12), (6, 13),
        (7, 13), (7, 14), (7, 15),
        (8, 13), (8, 16),
        (9, 15),
        (10, 20),
        (12, 24),
    ]

    private struct FamilySpec {
        let xlfdFamily: String      // family name in synthesized XLFDs
        let spacing: String         // "m" (mono) or "p" (proportional)
    }

    private static let xlfdFamilies: [FamilySpec] = [
        FamilySpec(xlfdFamily: "monaco", spacing: "m"),
        FamilySpec(xlfdFamily: "courier", spacing: "m"),
        FamilySpec(xlfdFamily: "lucidatypewriter", spacing: "m"),
        FamilySpec(xlfdFamily: "andale mono", spacing: "m"),
        FamilySpec(xlfdFamily: "helvetica", spacing: "p"),
        FamilySpec(xlfdFamily: "times", spacing: "p"),
        FamilySpec(xlfdFamily: "new century schoolbook", spacing: "p"),
        FamilySpec(xlfdFamily: "symbol", spacing: "p"),
    ]

    private static let pointSizes: [Int] = [8, 10, 12, 14, 16]

    private static func makeXLFD(
        family: FamilySpec, weight: String, slant: String,
        pointTenths: Int, spacing: String
    ) -> String {
        // pixelHeight ≈ pointSize × 1.2 (Monaco-on-macOS line-height ratio);
        // averageWidth = round(pointSize × 0.6 × 10) for monospace.
        let pointSize = Double(pointTenths) / 10.0
        let pixelHeight = Int(round(pointSize * 1.2))
        let avgWidth = Int(round(pointSize * 0.6 * 10))
        return "-apple-\(family.xlfdFamily)-\(weight)-\(slant)-normal--\(pixelHeight)-\(pointTenths)-90-90-\(spacing)-\(avgWidth)-iso10646-1"
    }

    /// Simple `*`/`?` wildcard match on lowercase strings.
    private static func wildcardMatch(pattern: String, string: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let s = Array(string.unicodeScalars)
        return wildcardMatchRec(p, 0, s, 0)
    }

    private static func wildcardMatchRec(_ p: [Unicode.Scalar], _ pi: Int,
                                         _ s: [Unicode.Scalar], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        if p[pi] == "*" {
            // Greedy: try matching zero, one, or more characters.
            // Skip consecutive '*' to avoid exponential blowup.
            var nextPi = pi + 1
            while nextPi < p.count && p[nextPi] == "*" { nextPi += 1 }
            if nextPi == p.count { return true }
            for k in si...s.count {
                if wildcardMatchRec(p, nextPi, s, k) { return true }
            }
            return false
        }
        if si == s.count { return false }
        if p[pi] == "?" || p[pi] == s[si] {
            return wildcardMatchRec(p, pi + 1, s, si + 1)
        }
        return false
    }
}

// MARK: - Keyboard / modifier / pointer defaults

/// US-ASCII keymap defaults backed by `USKeymap`. Returns real keysyms so
/// Xlib can decode keys and applications get correct case / typed text.
public enum DefaultKeyboardMap {
    public static var keysymsPerKeycode: UInt8 { USKeymap.keysymsPerKeycode }

    public static func keysyms(firstKeycode: UInt8, count: UInt8) -> [UInt32] {
        USKeymap.keymapPayload(firstKeycode: firstKeycode, count: count)
    }
}

/// Default modifier mapping from `USKeymap`. Maps Shift / Lock / Control /
/// Mod1 (Option) / Mod4 (Command) to the X keycodes that correspond to the
/// macOS modifier keys.
public enum DefaultModifierMap {
    public static var keycodesPerModifier: UInt8 { USKeymap.keycodesPerModifier }
    public static var keycodes: [UInt8] { USKeymap.modifierKeycodes }
}

/// Default pointer mapping: 1, 2, 3 (left, middle, right buttons).
public enum DefaultPointerMap {
    public static let map: [UInt8] = [1, 2, 3]
}
