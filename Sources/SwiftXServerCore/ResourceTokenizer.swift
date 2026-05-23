import Foundation

// Token classification for the swift-x resources file format. Pure
// Swift, no AppKit — the chrome side wraps this in an
// NSTextStorageDelegate to paint attributes.
//
// Grammar is intentionally small (matches what ResourceFile.parse
// recognizes plus a couple of value subtypes for syntax-color use):
//
//   [section]              → sectionHeader   (whole trimmed extent)
//   ! to end of line       → comment
//   key  :  value          → key + separator + (value | colorValueHex | colorValueNamed)
//
// Ranges are UTF-16 NSRanges anchored to the start of the original
// full-text string. That's the indexing NSTextStorage uses, so the
// chrome can apply attributes directly without conversion.

public enum ResourceTokenKind: Equatable {
    case sectionHeader
    case comment
    case keyPrefix       // widget-class root before the first '*' (Dtterm, Dtpad, Dtcalc)
    case key
    case separator
    case value
    case colorValueHex
    case colorValueNamed
}

public struct ResourceTokenSpan: Equatable {
    public let kind: ResourceTokenKind
    public let range: NSRange

    public init(kind: ResourceTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum ResourceTokenizer {

    /// Tokenize the full text. Walks line by line, tracking UTF-16
    /// offset for NSRange compatibility with NSTextStorage.
    public static func tokenize(_ text: String) -> [ResourceTokenSpan] {
        var spans: [ResourceTokenSpan] = []
        var utf16Offset = 0
        // Preserve empty trailing lines so offsets line up with what
        // NSTextStorage sees. `split` with omittingEmptySubsequences:false
        // keeps them.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            tokenizeLine(String(line), offset: utf16Offset, into: &spans)
            utf16Offset += line.utf16.count
            // Account for the `\n` we split on (every line except the last
            // synthetic one). A 5-line file has 4 newlines between the
            // 5 split pieces.
            if i < lines.count - 1 { utf16Offset += 1 }
        }
        return spans
    }

    /// Tokenize a single line. Useful for incremental retokenization
    /// when an NSTextStorageDelegate sees just the edited paragraph.
    /// `offset` is the UTF-16 index of the line's first char in the
    /// surrounding full text (pass 0 if you only care about a stand-
    /// alone line).
    public static func tokenizeLine(
        _ line: String,
        offset: Int,
        into spans: inout [ResourceTokenSpan]
    ) {
        let units = Array(line.utf16)
        let n = units.count

        // Find first non-whitespace (space or tab) char.
        var i = 0
        while i < n, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
        if i == n { return }   // blank or whitespace-only line — no tokens

        let first = units[i]

        // Comment: ! to EOL.
        if first == 0x21 {   // '!'
            spans.append(ResourceTokenSpan(
                kind: .comment,
                range: NSRange(location: offset + i, length: n - i)
            ))
            return
        }

        // Section header: starts with '['. We're permissive — the section
        // extent runs from the '[' to the matching ']' or EOL, whichever
        // comes first. Anything after the ']' on the same line is ignored
        // by ResourceFile.parse anyway; we just don't tokenize it.
        if first == 0x5B {   // '['
            var j = i + 1
            while j < n, units[j] != 0x5D { j += 1 }   // ']'
            let end = (j < n) ? j + 1 : n
            spans.append(ResourceTokenSpan(
                kind: .sectionHeader,
                range: NSRange(location: offset + i, length: end - i)
            ))
            return
        }

        // key : value. Find the first ':' from the first non-whitespace
        // char. No colon → whole line is a malformed key with no value,
        // tag it as .key so the user at least sees it as something we
        // recognize structurally.
        var colon = -1
        for k in i..<n where units[k] == 0x3A {   // ':'
            colon = k
            break
        }

        if colon < 0 {
            spans.append(ResourceTokenSpan(
                kind: .key,
                range: NSRange(location: offset + i, length: n - i)
            ))
            return
        }

        // Key extent: first non-whitespace to last non-whitespace before colon.
        var keyEnd = colon
        while keyEnd > i, units[keyEnd - 1] == 0x20 || units[keyEnd - 1] == 0x09 {
            keyEnd -= 1
        }
        if keyEnd > i {
            // Highlight the leading Class identifier — the "outer scope"
            // of the resource pattern in X's left-to-right hierarchy.
            // Per X naming convention classes start with an uppercase
            // letter (Dtterm, Dtpad, XmText), instances start with a
            // lowercase letter (cursorForeground, mainMenu). We allow
            // exactly one leading binding char ('*' or '.') so patterns
            // like "*XmText.background" still pick up the XmText class.
            // Only the FIRST class — consecutive classes don't compound.
            var p = i
            if units[p] == 0x2A || units[p] == 0x2E { p += 1 }   // '*' or '.'
            if p < keyEnd, isAsciiUpper(units[p]) {
                // Find end of the leading identifier: next binding or keyEnd.
                var identEnd = keyEnd
                for k in p..<keyEnd where units[k] == 0x2A || units[k] == 0x2E {
                    identEnd = k
                    break
                }
                if p > i {
                    // Leading binding char before the class.
                    spans.append(ResourceTokenSpan(
                        kind: .key,
                        range: NSRange(location: offset + i, length: p - i)
                    ))
                }
                spans.append(ResourceTokenSpan(
                    kind: .keyPrefix,
                    range: NSRange(location: offset + p, length: identEnd - p)
                ))
                if identEnd < keyEnd {
                    spans.append(ResourceTokenSpan(
                        kind: .key,
                        range: NSRange(location: offset + identEnd, length: keyEnd - identEnd)
                    ))
                }
            } else {
                spans.append(ResourceTokenSpan(
                    kind: .key,
                    range: NSRange(location: offset + i, length: keyEnd - i)
                ))
            }
        }

        spans.append(ResourceTokenSpan(
            kind: .separator,
            range: NSRange(location: offset + colon, length: 1)
        ))

        // Value extent: char after colon, skip leading whitespace, run to
        // last non-whitespace char before EOL.
        var valStart = colon + 1
        while valStart < n, units[valStart] == 0x20 || units[valStart] == 0x09 {
            valStart += 1
        }
        var valEnd = n
        while valEnd > valStart, units[valEnd - 1] == 0x20 || units[valEnd - 1] == 0x09 {
            valEnd -= 1
        }
        if valEnd > valStart {
            let valueString = utf16Slice(units, from: valStart, to: valEnd)
            let kind = classifyValue(valueString)
            spans.append(ResourceTokenSpan(
                kind: kind,
                range: NSRange(location: offset + valStart, length: valEnd - valStart)
            ))
        }
    }

    // MARK: - Value classification

    /// Decide whether a value is a hex color (#rgb / #rrggbb), an X11
    /// named color, or something else. The chrome uses this to paint
    /// the value text in its own color.
    public static func classifyValue(_ value: String) -> ResourceTokenKind {
        if isHexColor(value) { return .colorValueHex }
        if XColorDatabase.lookup(value) != nil { return .colorValueNamed }
        return .value
    }

    private static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let hex = s.dropFirst()
        guard hex.count == 3 || hex.count == 6 else { return false }
        return hex.allSatisfy { c in
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }
    }

    @inline(__always)
    private static func isAsciiUpper(_ u: UInt16) -> Bool {
        return u >= 0x41 && u <= 0x5A
    }

    private static func utf16Slice(_ units: [UInt16], from start: Int, to end: Int) -> String {
        // Build a String from a contiguous UTF-16 slice. The values we'll
        // ever see in resource files are ASCII so this never fails; the
        // explicit unwrap is fine — a malformed UTF-16 sequence in the
        // middle of a config line is a different kind of problem.
        let slice = Array(units[start..<end])
        return String(utf16CodeUnits: slice, count: slice.count)
    }
}
