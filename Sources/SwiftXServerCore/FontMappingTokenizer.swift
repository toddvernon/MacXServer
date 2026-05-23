import Foundation

// Token classification for the swift-x font mappings file. Pure Swift
// (no AppKit), parallels ResourceTokenizer. The chrome side wraps this
// in an NSTextStorageDelegate to paint attributes.
//
// Grammar — see DefaultFontMappings for the file format:
//   # ...                                  → comment (also !)
//   <family>  ->  <mac-font>  mono|prop    → data line
//
// Both family and mac-font may be multi-word; `->` separates them; the
// trailing `mono`/`prop` token is the spacing kind. Spans returned span
// the whole family extent (including any internal whitespace) so the
// highlighter paints "new century schoolbook" as one coherent unit.

public enum FontMappingTokenKind: Equatable {
    case comment
    case fallbackKey       // *fallback-mono / *fallback-prop
    case family            // tokens before the `->`
    case arrow             // the literal `->`
    case macFont           // tokens between `->` and the trailing kind
    case spacingKind       // trailing `mono` or `prop`
    case unknown           // line we couldn't classify
}

public struct FontMappingTokenSpan: Equatable {
    public let kind: FontMappingTokenKind
    public let range: NSRange

    public init(kind: FontMappingTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum FontMappingTokenizer {

    /// Tokenize the full file, returning UTF-16 NSRange spans anchored
    /// to the input string.
    public static func tokenize(_ text: String) -> [FontMappingTokenSpan] {
        var spans: [FontMappingTokenSpan] = []
        var utf16Offset = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            tokenizeLine(String(line), offset: utf16Offset, into: &spans)
            utf16Offset += line.utf16.count
            if i < lines.count - 1 { utf16Offset += 1 }
        }
        return spans
    }

    public static func tokenizeLine(
        _ line: String,
        offset: Int,
        into spans: inout [FontMappingTokenSpan]
    ) {
        let units = Array(line.utf16)
        let n = units.count

        // Skip leading whitespace.
        var i = 0
        while i < n, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
        if i == n { return }   // blank line

        // Comment to EOL.
        if units[i] == 0x23 || units[i] == 0x21 {   // '#' or '!'
            spans.append(FontMappingTokenSpan(
                kind: .comment,
                range: NSRange(location: offset + i, length: n - i)
            ))
            return
        }

        // Find token boundaries from i onward.
        var tokenRanges: [(start: Int, end: Int)] = []
        var p = i
        while p < n {
            if units[p] == 0x20 || units[p] == 0x09 { p += 1; continue }
            let start = p
            while p < n, units[p] != 0x20 && units[p] != 0x09 { p += 1 }
            tokenRanges.append((start, p))
        }

        // Locate the `->` token.
        var arrowIdx = -1
        for (k, t) in tokenRanges.enumerated() {
            if t.end - t.start == 2,
               units[t.start] == 0x2D,           // '-'
               units[t.start + 1] == 0x3E {      // '>'
                arrowIdx = k
                break
            }
        }

        // Need at least: family token(s), '->', mac-font token(s), kind.
        guard arrowIdx >= 1,
              tokenRanges.count >= arrowIdx + 3
        else {
            spans.append(FontMappingTokenSpan(
                kind: .unknown,
                range: NSRange(location: offset + i, length: n - i)
            ))
            return
        }

        // Trailing token must be mono/prop.
        let last = tokenRanges.last!
        let lastWord = utf16Slice(units, from: last.start, to: last.end).lowercased()
        guard lastWord == "mono" || lastWord == "prop" else {
            spans.append(FontMappingTokenSpan(
                kind: .unknown,
                range: NSRange(location: offset + i, length: n - i)
            ))
            return
        }

        // Family extent: from first family token start to last family
        // token end. May include internal whitespace ("new century
        // schoolbook") — we paint the whole region so it reads as one.
        let familyStart = tokenRanges[0].start
        let familyEnd = tokenRanges[arrowIdx - 1].end
        let firstWord = utf16Slice(units, from: familyStart, to: tokenRanges[0].end)
        let isFallback = firstWord.hasPrefix("*fallback-")

        spans.append(FontMappingTokenSpan(
            kind: isFallback ? .fallbackKey : .family,
            range: NSRange(location: offset + familyStart, length: familyEnd - familyStart)
        ))

        // Arrow.
        let arrowSpan = tokenRanges[arrowIdx]
        spans.append(FontMappingTokenSpan(
            kind: .arrow,
            range: NSRange(location: offset + arrowSpan.start, length: arrowSpan.end - arrowSpan.start)
        ))

        // Mac font: from token after arrow to token before the last.
        let macStart = tokenRanges[arrowIdx + 1].start
        let macEnd = tokenRanges[tokenRanges.count - 2].end
        spans.append(FontMappingTokenSpan(
            kind: .macFont,
            range: NSRange(location: offset + macStart, length: macEnd - macStart)
        ))

        // Spacing kind.
        spans.append(FontMappingTokenSpan(
            kind: .spacingKind,
            range: NSRange(location: offset + last.start, length: last.end - last.start)
        ))
    }

    private static func utf16Slice(_ units: [UInt16], from start: Int, to end: Int) -> String {
        let slice = Array(units[start..<end])
        return String(utf16CodeUnits: slice, count: slice.count)
    }
}
