import AppKit

// Palette for the dark code editor — the iTerm/Xcode vibe Todd referenced.
// A plain value type so a light or alt palette can drop in later without
// touching the highlighters. Generic: it carries named colors only and has
// no knowledge of any specific file's token kinds (each highlighter maps its
// own tokens onto these fields).

// @unchecked Sendable: every field is an immutable `let` NSColor, which is
// safe to read across threads; the compiler just can't prove NSColor itself
// is Sendable.
public struct EditorTheme: @unchecked Sendable {
    public let background: NSColor
    public let gutterBackground: NSColor
    public let gutterForeground: NSColor
    public let selection: NSColor
    public let cursor: NSColor

    /// Default foreground for un-tokenized text (whitespace, malformed lines).
    public let defaultText: NSColor

    /// Named palette slots the per-file highlighters paint with.
    public let sectionHeader: NSColor
    public let comment: NSColor
    public let keyPrefix: NSColor
    public let key: NSColor
    public let separator: NSColor
    public let value: NSColor
}

extension EditorTheme {
    /// The one theme we ship today. Near-black background, warm coral
    /// for section headers, green keys, soft cyan values, muted green-
    /// grey italic comments. Picked to read well in SF Mono 13pt.
    public static let dark = EditorTheme(
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
