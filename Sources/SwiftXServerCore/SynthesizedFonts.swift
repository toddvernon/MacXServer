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
    /// `?` wildcards; we do a simple lowercase fnmatch-style match. Empty
    /// pattern (or `"*"`) returns everything.
    public static func match(pattern: String, max: Int) -> [[UInt8]] {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" {
            return Array(phase1Names.prefix(max))
        }
        let lowerPattern = trimmed.lowercased()
        let result = phase1Names.compactMap { bytes -> [UInt8]? in
            let s = String(decoding: bytes, as: UTF8.self).lowercased()
            return wildcardMatch(pattern: lowerPattern, string: s) ? bytes : nil
        }
        return Array(result.prefix(max))
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
        // pixelHeight ≈ pointSize * 1.07; averageWidth = round(pointSize * 0.6 * 10) for monospace
        let pointSize = Double(pointTenths) / 10.0
        let pixelHeight = Int(round(pointSize * 1.07))
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
