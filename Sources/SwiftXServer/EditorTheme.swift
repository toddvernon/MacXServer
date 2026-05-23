import AppKit
import SwiftXServerCore

// Palette for the resources file editor. Dark code-editor theme — the
// iTerm/Xcode vibe Todd referenced. Structured as a Theme value so a
// light or alt palette can drop in later without touching the
// highlighter.
//
// Token kinds are defined alongside the tokenizer in
// SwiftXServerCore/ResourceTokenizer.swift; the highlighter emits them
// and looks each up here.

struct EditorTheme {
    let background: NSColor
    let gutterBackground: NSColor
    let gutterForeground: NSColor
    let selection: NSColor
    let cursor: NSColor

    /// Default foreground for un-tokenized text (whitespace, malformed lines).
    let defaultText: NSColor

    /// Per-token foreground. Color values are special-cased by the
    /// highlighter — it computes their color from the value text rather
    /// than reading the palette.
    let sectionHeader: NSColor
    let comment: NSColor
    let keyPrefix: NSColor
    let key: NSColor
    let separator: NSColor
    let value: NSColor

    /// Italics flag per token kind. Only comment uses it today.
    func isItalic(_ token: ResourceTokenKind) -> Bool {
        return token == .comment
    }

    /// Look up the static color for a token. Color-value tokens return
    /// the default value color; the highlighter overrides them per-line
    /// using the actual color the value names.
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

extension EditorTheme {
    /// The one theme we ship today. Near-black background, warm coral
    /// for section headers, green keys, soft cyan values, muted green-
    /// grey italic comments. Picked to read well in SF Mono 13pt.
    static let dark = EditorTheme(
        background:       NSColor(srgbRed: 0x0d/255.0, green: 0x0d/255.0, blue: 0x0d/255.0, alpha: 1.0),
        gutterBackground: NSColor(srgbRed: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1.0),
        gutterForeground: NSColor(srgbRed: 0x5a/255.0, green: 0x5a/255.0, blue: 0x5a/255.0, alpha: 1.0),
        selection:        NSColor(srgbRed: 0x3a/255.0, green: 0x3a/255.0, blue: 0x4a/255.0, alpha: 1.0),
        cursor:           .white,
        defaultText:      NSColor(srgbRed: 0xcc/255.0, green: 0xcc/255.0, blue: 0xcc/255.0, alpha: 1.0),
        sectionHeader:    NSColor(srgbRed: 0xff/255.0, green: 0x99/255.0, blue: 0x66/255.0, alpha: 1.0),
        comment:          NSColor(srgbRed: 0x7a/255.0, green: 0x8a/255.0, blue: 0x7a/255.0, alpha: 1.0),
        // Plum — One Dark / Material Theme convention for class names.
        // Distinct from the coral section header so [theme:NAME] and
        // widget-class prefixes (Dtterm, XmText) don't visually conflate.
        keyPrefix:        NSColor(srgbRed: 0xc7/255.0, green: 0x92/255.0, blue: 0xea/255.0, alpha: 1.0),
        key:              NSColor(srgbRed: 0x7e/255.0, green: 0xc9/255.0, blue: 0x7e/255.0, alpha: 1.0),
        separator:        NSColor(srgbRed: 0xcc/255.0, green: 0xcc/255.0, blue: 0xcc/255.0, alpha: 1.0),
        value:            NSColor(srgbRed: 0xa8/255.0, green: 0xd8/255.0, blue: 0xe8/255.0, alpha: 1.0)
    )
}
