import AppKit
import SwiftXServerCore
import SwiftXCaptureUI

final class LauncherSyntaxHighlighter: NSObject, SyntaxHighlighter {

    private let theme: EditorTheme
    private let baseFont: NSFont
    private let italicFont: NSFont

    init(theme: EditorTheme, baseFont: NSFont) {
        self.theme = theme
        self.baseFont = baseFont
        self.italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        super.init()
    }

    func applyAll(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        applyAttributes(storage: storage, in: full)
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        applyAttributes(storage: textStorage, in: full)
    }

    private func applyAttributes(storage: NSTextStorage, in range: NSRange) {
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.defaultText,
        ], range: range)

        let spans = LauncherTokenizer.tokenize(storage.string)
        for span in spans {
            let clamped = NSIntersectionRange(span.range, range)
            if clamped.length == 0 { continue }
            var attrs: [NSAttributedString.Key: Any] = [:]
            switch span.kind {
            case .comment:
                attrs[.font] = italicFont
                attrs[.foregroundColor] = theme.comment
            case .sectionHeader:
                attrs[.foregroundColor] = theme.sectionHeader
            case .key:
                attrs[.foregroundColor] = theme.key
            case .separator:
                attrs[.foregroundColor] = theme.separator
            case .value:
                attrs[.foregroundColor] = theme.value
            case .unknown:
                attrs[.foregroundColor] = theme.defaultText
            }
            storage.addAttributes(attrs, range: clamped)
        }
        storage.endEditing()
    }
}
