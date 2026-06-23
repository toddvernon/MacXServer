import AppKit
import SwiftXCaptureUI

// Syntax highlighter for the guest's /etc/resolv.conf, shown in the DNS admin
// editor. Same shape as ResourceSyntaxHighlighter (an NSTextStorageDelegate
// that retokenizes the whole buffer on each edit) but resolv.conf is trivial
// enough that we don't need a separate tokenizer in SwiftXServerCore — the
// grammar is just: per line, an optional `#`/`;` comment to end-of-line, a
// leading directive keyword, and the rest as a value.
//
// resolv.conf is ASCII by spec, so Character offsets line up with the
// NSString UTF-16 ranges we hand back to the text storage.

final class ResolvConfSyntaxHighlighter: NSObject, SyntaxHighlighter {

    private let theme: EditorTheme
    private let baseFont: NSFont
    private let italicFont: NSFont

    // The resolver directives we color as keywords; anything else on the line
    // stays default-colored so typos are visually obvious (no green keyword).
    private static let directives: Set<String> = [
        "nameserver", "domain", "search", "sortlist", "options", "lookup",
    ]

    init(theme: EditorTheme, baseFont: NSFont) {
        self.theme = theme
        self.baseFont = baseFont
        self.italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        super.init()
    }

    func applyAll(to storage: NSTextStorage) {
        applyAttributes(storage: storage)
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        // Only retokenize on character changes; our own attribute edits don't
        // re-trigger this (Apple's NSTextStorage contract).
        guard editedMask.contains(.editedCharacters) else { return }
        applyAttributes(storage: textStorage)
    }

    // MARK: - Coloring

    private func applyAttributes(storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: theme.defaultText], range: full)
        text.enumerateSubstrings(in: full, options: [.byLines]) { _, lineRange, _, _ in
            self.colorLine(storage: storage, text: text, lineRange: lineRange)
        }
        storage.endEditing()
    }

    private func colorLine(storage: NSTextStorage, text: NSString, lineRange: NSRange) {
        let chars = Array(text.substring(with: lineRange))
        let base = lineRange.location

        // A `#` or `;` starts a comment that runs to end of line.
        var codeEnd = chars.count
        if let c = chars.firstIndex(where: { $0 == "#" || $0 == ";" }) {
            storage.addAttributes([.foregroundColor: theme.comment, .font: italicFont],
                                  range: NSRange(location: base + c, length: chars.count - c))
            codeEnd = c
        }

        // First whitespace-delimited token in the code part = directive keyword.
        func isSpace(_ ch: Character) -> Bool { ch == " " || ch == "\t" }
        var i = 0
        while i < codeEnd, isSpace(chars[i]) { i += 1 }
        var j = i
        while j < codeEnd, !isSpace(chars[j]) { j += 1 }
        guard j > i else { return }

        let token = String(chars[i..<j]).lowercased()
        guard Self.directives.contains(token) else { return }
        storage.addAttributes([.foregroundColor: theme.key],
                              range: NSRange(location: base + i, length: j - i))

        // Everything after the keyword (up to any comment) is the value.
        var k = j
        while k < codeEnd, isSpace(chars[k]) { k += 1 }
        if codeEnd > k {
            storage.addAttributes([.foregroundColor: theme.value],
                                  range: NSRange(location: base + k, length: codeEnd - k))
        }
    }
}
