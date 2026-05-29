import AppKit
import SwiftXServerCore
import SwiftXCaptureUI

// The resource-file token → palette mapping. Lives here (not on EditorTheme,
// which is the generic shared theme in SwiftXCaptureUI) so the shared editor
// stays decoupled from SwiftXServerCore's ResourceTokenKind.
private extension EditorTheme {
    func isItalic(_ token: ResourceTokenKind) -> Bool { token == .comment }

    func color(for token: ResourceTokenKind) -> NSColor {
        switch token {
        case .sectionHeader:    return sectionHeader
        case .comment:          return comment
        case .keyPrefix:        return keyPrefix
        case .key:              return key
        case .separator:        return separator
        case .value:            return value
        case .colorValueHex,
             .colorValueNamed:  return value   // overridden per-line
        }
    }
}

// NSTextStorageDelegate that paints the resources file syntax. The
// tokenizer lives in SwiftXServerCore so the chrome stays thin:
// here we just turn token spans into NSAttributedString attributes
// and special-case color-value tokens so they render in their own
// color (with a luminance fallback for values too dark to read on
// the black editor background).
//
// Strategy: retokenize the whole buffer on every edit. The files
// we're editing are small (hundreds of lines, not thousands) and the
// tokenizer is a single-pass byte walker — measuring it on a 500-line
// file is well under a millisecond. Not worth being clever with
// per-paragraph dirty tracking.
//
// Re-entrancy: attribute-only edits inside `didProcessEditing` are
// safe per Apple's NSTextStorage contract — they don't re-trigger the
// `editedCharacters` mask. We never touch characters from here.

final class ResourceSyntaxHighlighter: NSObject, SyntaxHighlighter {

    private let theme: EditorTheme
    private let baseFont: NSFont
    private let italicFont: NSFont

    init(theme: EditorTheme, baseFont: NSFont) {
        self.theme = theme
        self.baseFont = baseFont
        // Italic variant for comments. NSFontManager.convert with .italic
        // gives us a real italic when one exists for the family, falls
        // back to the upright face otherwise (SF Mono has italics on
        // macOS 14+ so this gives us what we want).
        self.italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        super.init()
    }

    /// Apply highlighting to the full text storage. Call this once after
    /// loading content from disk so the buffer is colored before the
    /// first edit fires the delegate.
    func applyAll(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        applyAttributes(storage: storage, in: full)
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        // Only retokenize when characters changed. Pure attribute edits
        // (which we make ourselves) don't need to re-run the tokenizer.
        guard editedMask.contains(.editedCharacters) else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        applyAttributes(storage: textStorage, in: full)
    }

    // MARK: - Attribute application

    private func applyAttributes(storage: NSTextStorage, in range: NSRange) {
        let text = storage.string

        storage.beginEditing()
        // Reset to defaults across the affected range, then layer token
        // attributes on top. Resetting first prevents stale color from
        // a previous tokenization clinging to whitespace or partially-
        // edited characters.
        storage.setAttributes(defaultAttributes(), range: range)

        let spans = ResourceTokenizer.tokenize(text)
        for span in spans {
            // Clamp the span to the edited range — defensive; tokenizer
            // returns spans in the full text and `range` is always full
            // today, but if we ever do incremental this stays correct.
            let clamped = NSIntersectionRange(span.range, range)
            if clamped.length == 0 { continue }
            applySpan(span.kind, fullText: text, in: clamped, storage: storage)
        }
        storage.endEditing()
    }

    private func applySpan(_ kind: ResourceTokenKind,
                           fullText: String,
                           in range: NSRange,
                           storage: NSTextStorage) {
        var attrs: [NSAttributedString.Key: Any] = [:]
        attrs[.font] = theme.isItalic(kind) ? italicFont : baseFont

        switch kind {
        case .colorValueHex, .colorValueNamed:
            let valueString = (fullText as NSString).substring(with: range)
            attrs[.foregroundColor] = readableColor(forValue: valueString)
        default:
            attrs[.foregroundColor] = theme.color(for: kind)
        }

        storage.addAttributes(attrs, range: range)
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: baseFont,
            .foregroundColor: theme.defaultText,
        ]
    }

    // MARK: - Color value rendering

    /// Convert a value string (`#rrggbb`, `#rgb`, or X11 named color) into
    /// an NSColor suitable for painting on the editor background. Below a
    /// perceived-luminance threshold the value would disappear against
    /// the near-black bg, so we lighten it via HSB instead of dropping to
    /// a flat grey — that way you can still tell SlateBlue4 from
    /// DarkGreen even when both are too dim to use raw.
    private func readableColor(forValue value: String) -> NSColor {
        guard let rgb = colorComponents(for: value) else {
            return theme.value
        }
        let lum = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        if lum >= 0.25 {
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        }
        // Lift brightness so the hue is preserved but the swatch reads.
        // 0.55 is empirical — bright enough to be legible on #0d0d0d
        // without washing the hue out to pastel.
        let raw = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        raw.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: max(b, 0.55), alpha: 1.0)
    }

    private func colorComponents(for value: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        // XColorDatabase.lookup handles both hex (#rgb, #rrggbb, etc.)
        // and the X11 named-color table, returning RGB16 (0...65535 per
        // channel) — same path AllocNamedColor uses on the wire.
        guard let rgb16 = XColorDatabase.lookup(value) else { return nil }
        return (
            r: CGFloat(rgb16.red) / 65535.0,
            g: CGFloat(rgb16.green) / 65535.0,
            b: CGFloat(rgb16.blue) / 65535.0
        )
    }
}
