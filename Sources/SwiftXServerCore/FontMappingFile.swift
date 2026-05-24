import Foundation

// User-editable font substitution table. See SERVER_RESOLUTION_SCALING_AND_FONTS.md
// for the canonical mapping (which the seed reproduces exactly), and
// MOTIF_TEXT_QUALITY.md → Tier 2 for the staged-delivery rationale.
//
// File format (line-oriented, deliberately simple — the mapping is a
// flat lookup with no hierarchy, unlike the resources file):
//
//   # comment to end of line, ! also works
//   <xlfd-family>  ->  <mac-font-name>
//
// The `->` separates the family name from the Mac font. This supports
// multi-word X family names ("new century schoolbook") and multi-word
// Mac font names ("Helvetica Neue") without ambiguity.
//
// Family names are case-insensitive; aliases share a Mac font by
// listing each one on its own line.
//
// Two special keys hold the wildcard fallback used when a client
// requests a family we don't recognize: `*fallback-mono` for
// spacing=c/m, `*fallback-prop` for everything else.
//
// Monospace vs proportional is a property of the Mac font itself, not
// something the user picks per line. `FontResolver.resolveFamily`
// derives it via CTFontGetSymbolicTraits on the resolved font.
//
// Parser is one-way (text → struct). The editor writes the user's raw
// buffer verbatim, same as ResourceFile, so comments/formatting are
// preserved exactly.

public struct FontMapping: Equatable, Sendable {
    public let family: String       // lowercased
    public let macFont: String
}

public struct FontMappingFile: Sendable {

    public let mappings: [FontMapping]
    public let fallbackMono: String      // mac font for spacing=c/m wildcards
    public let fallbackProp: String      // mac font for everything else

    /// Look up a family name (case-insensitive). Returns the Mac font
    /// name, or nil if the name isn't in the table. The caller derives
    /// monospace from the resolved font itself.
    public func resolve(family: String) -> String? {
        let normalized = family.lowercased()
        for m in mappings where m.family == normalized {
            return m.macFont
        }
        return nil
    }

    /// Resolve an unknown family using the spacing-based wildcard
    /// fallback. Spacing `c` (charcell) or `m` (monospace) → mono
    /// fallback's Mac font; anything else → proportional fallback's
    /// Mac font.
    public func fallback(spacing: String) -> String {
        switch spacing.lowercased() {
        case "c", "m": return fallbackMono
        default:       return fallbackProp
        }
    }

    // MARK: - Parser

    public static func parse(_ text: String) -> FontMappingFile {
        var mappings: [FontMapping] = []
        var fallbackMono: String = "Monaco"
        var fallbackProp: String = "Helvetica Neue"

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("!") { continue }

            guard let parsed = parseLine(trimmed) else { continue }
            switch parsed.family {
            case "*fallback-mono":
                fallbackMono = parsed.macFont
            case "*fallback-prop":
                fallbackProp = parsed.macFont
            default:
                mappings.append(FontMapping(
                    family: parsed.family,
                    macFont: parsed.macFont
                ))
            }
        }
        return FontMappingFile(
            mappings: mappings,
            fallbackMono: fallbackMono,
            fallbackProp: fallbackProp
        )
    }

    /// Split a single non-comment, non-blank line into (family, macFont).
    /// Format: `<family>  ->  <mac-font>`. Multi-word family on the
    /// left of `->`, multi-word Mac font on the right.
    private static func parseLine(_ line: String) -> (family: String, macFont: String)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3 else { return nil }   // need at least family, ->, macFont

        guard let arrowIdx = tokens.firstIndex(of: "->") else { return nil }
        guard arrowIdx >= 1, arrowIdx <= tokens.count - 2 else { return nil }
        // arrowIdx >= 1 → at least one family token before the arrow
        // arrowIdx <= count-2 → at least one mac-font token after

        // Family: tokens[0..<arrowIdx], lowercased, joined with spaces.
        let family = tokens[0..<arrowIdx]
            .joined(separator: " ")
            .lowercased()

        // Mac font: everything after the arrow, joined with spaces.
        let macFont = tokens[(arrowIdx + 1)...]
            .joined(separator: " ")
        guard !macFont.isEmpty else { return nil }

        return (family, macFont)
    }
}

// MARK: - File I/O

public enum FontMappingFileLoader {

    /// Standard location for the user's swift-x font mappings. Sibling
    /// of `~/.swiftx-resources`, same dotfile pattern.
    public static let defaultPath: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".swiftx-fonts")

    /// Load the file at `path`. If it doesn't exist, write the seed
    /// content first and then load. Always returns a parsed result; on
    /// read or write failure falls back to parsing the seed directly so
    /// the server still has a usable substitution table.
    public static func loadOrSeed(
        path: String = defaultPath,
        seed: @autoclosure () -> String,
        log: ServerLogSink? = nil
    ) -> FontMappingFile {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let seedContent = seed()
            do {
                try seedContent.write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("FontMappingFile: wrote seed to \(path) (first run)")
            } catch {
                log?.log("FontMappingFile: could not write seed to \(path) (\(error)); using in-memory fallback")
                return FontMappingFile.parse(seedContent)
            }
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return FontMappingFile.parse(content)
        } catch {
            log?.log("FontMappingFile: could not read \(path) (\(error)); using in-memory seed")
            return FontMappingFile.parse(seed())
        }
    }
}
