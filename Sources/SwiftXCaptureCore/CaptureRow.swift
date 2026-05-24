import Foundation

// One displayable line from a decoded capture. Carries
// ChronoDumper's formatted text plus a separate first-token "title"
// the UI uses as the row primary label.
//
// Splitting happens once at row-construction time so the UI doesn't
// re-parse on every render.

public struct CaptureRow: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let lineText: String       // full chronodumper line
    public let title: String          // first packet-name token
    public let detail: String         // everything after the title

    public init(id: Int, lineText: String) {
        self.id = id
        self.lineText = lineText
        (self.title, self.detail) = CaptureRow.split(lineText)
    }

    /// Pull the first packet-name token out of a chronodumper line.
    /// The leading content is timestamp + direction marker, e.g.
    ///   "    0.000ms        SetupRequest byteOrder=lsb-first"
    ///   "    0.010ms   →    PolyFillRectangle drawable=0x4400023"
    /// Skip while a token starts with a digit (timestamp variants
    /// like "12345", "0.000ms"), bracket (`[→]`), or matches one of
    /// the bare direction arrows. Stop at the first token that
    /// starts with a letter or `*` — that's the packet name.
    public static func split(_ line: String) -> (title: String, detail: String) {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var idx = 0
        while idx < tokens.count {
            let t = String(tokens[idx])
            guard let first = t.first else { idx += 1; continue }
            if first.isLetter || first == "*" {
                break
            }
            // Starts with digit, punctuation, or arrow glyph — keep
            // walking. Catches "0.000ms", "12345", "[→]", "→", "←".
            idx += 1
        }
        guard idx < tokens.count else { return ("", line) }
        let title = String(tokens[idx])
        let detail = tokens[(idx + 1)...].joined(separator: " ")
        return (title, detail)
    }
}
