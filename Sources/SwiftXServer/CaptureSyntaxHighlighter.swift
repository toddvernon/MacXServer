import AppKit

// Syntax highlighter for the decoded .xtap chrono dump shown in the capture
// viewer (the same text ChronoDumper writes to the .txt sidecar). The dump
// format is ours and strictly line-oriented, so we highlight by regex passes
// over the whole buffer rather than a token stream:
//
//   3.337ms  →   [seq=6     ] AllocNamedColor   cmap=0x21 name="Gray"
//   3.577ms  ←   [seq=6     ] Reply (AllocNamedColor) → pixel=0x12 ...
//   230.160ms  ←                MapNotify window=0x4600008
//   ...      →   [seq=42    ] BadWindow major=...
//
// Passes run in order; later passes override earlier ones where ranges
// overlap. So the message-name pass paints the leading word, then Reply /
// error passes repaint it in their own colors, and hex / string passes win
// inside the trailing field text.
//
// The buffer is read-only in the viewer, so applyAll runs once at load and
// the only edits are buffer replacements (Open another capture).

final class CaptureSyntaxHighlighter: NSObject, SyntaxHighlighter {

    private let theme: EditorTheme
    private let baseFont: NSFont
    private let italicFont: NSFont

    // Palette — keeps the dark resource-editor vibe. Direction is the primary
    // signal: client→server (requests) and the → arrow share one color;
    // server→client (replies + events) and the ← arrow share another.
    private let cTimestamp = NSColor(srgbRed: 0x6a/255, green: 0x6a/255, blue: 0x6a/255, alpha: 1)
    private let cRequest   = NSColor(srgbRed: 0x7e/255, green: 0xc9/255, blue: 0x7e/255, alpha: 1) // → client→server
    private let cResponse  = NSColor(srgbRed: 0x6a/255, green: 0xb8/255, blue: 0xff/255, alpha: 1) // ← server→client
    private let cSeq        = NSColor(srgbRed: 0x70/255, green: 0x70/255, blue: 0x70/255, alpha: 1)
    private let cError      = NSColor(srgbRed: 0xe0/255, green: 0x6c/255, blue: 0x75/255, alpha: 1) // BadWindow, Error#N
    private let cHex        = NSColor(srgbRed: 0xc7/255, green: 0x92/255, blue: 0xea/255, alpha: 1) // 0x...
    private let cString     = NSColor(srgbRed: 0xe5/255, green: 0xc0/255, blue: 0x7b/255, alpha: 1) // "..."
    private let cHeader     = NSColor(srgbRed: 0xff/255, green: 0x99/255, blue: 0x66/255, alpha: 1) // === path ===

    private let reHeader: NSRegularExpression
    private let reTimestamp: NSRegularExpression
    private let reRequestName: NSRegularExpression
    private let reResponseName: NSRegularExpression
    private let reReply: NSRegularExpression
    private let reSetupReq: NSRegularExpression
    private let reSetupAcc: NSRegularExpression
    private let reError: NSRegularExpression
    private let reSeq: NSRegularExpression
    private let reArrowOut: NSRegularExpression
    private let reArrowIn: NSRegularExpression
    private let reHex: NSRegularExpression
    private let reString: NSRegularExpression

    init(theme: EditorTheme, baseFont: NSFont) {
        self.theme = theme
        self.baseFont = baseFont
        self.italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        func rx(_ pattern: String) -> NSRegularExpression {
            // Patterns are fixed literals; a failure is a programmer error.
            return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
        reHeader    = rx("^===.*$")
        reTimestamp = rx("^\\s*[0-9]+\\.[0-9]+ms")
        // The message name (group 1) is the first word after the timestamp,
        // direction arrow, and optional [seq=N] field (events have a blank
        // there). Split by direction so the name is colored to match the
        // arrow: → lines = request color, ← lines (replies + events) = response.
        reRequestName  = rx("^\\s*[0-9.]+ms\\s+→\\s+(?:\\[seq=[^\\]]*\\]\\s*)?\\s*([A-Za-z][A-Za-z0-9]*)")
        reResponseName = rx("^\\s*[0-9.]+ms\\s+←\\s+(?:\\[seq=[^\\]]*\\]\\s*)?\\s*(?:\\[SendEvent\\]\\s*)?([A-Za-z][A-Za-z0-9]*)")
        reReply     = rx("Reply \\([^)]*\\)")
        // Setup lines carry no arrow; color them by direction explicitly.
        reSetupReq  = rx("\\bSetupRequest\\b")
        reSetupAcc  = rx("\\bSetupAccepted\\b")
        reError     = rx("\\bBad[A-Za-z]+\\b|\\bError#[0-9]+\\b")
        reSeq       = rx("\\[seq=\\s*[0-9]+\\s*\\]")
        reArrowOut  = rx("→")
        reArrowIn   = rx("←")
        reHex       = rx("0x[0-9A-Fa-f]+")
        reString    = rx("\"[^\"]*\"")
        super.init()
    }

    func applyAll(to storage: NSTextStorage) {
        applyAttributes(storage: storage)
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyAttributes(storage: textStorage)
    }

    private func applyAttributes(storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: theme.defaultText], range: full)

        // Order matters: later passes override earlier ones on overlap.
        color(storage, text, reTimestamp, cTimestamp)
        color(storage, text, reHeader, cHeader)
        // Message name by direction (request green / response blue), then
        // extend the response color across the full "Reply (...)".
        color(storage, text, reRequestName, cRequest, group: 1)
        color(storage, text, reResponseName, cResponse, group: 1)
        color(storage, text, reReply, cResponse)
        color(storage, text, reSetupReq, cRequest)
        color(storage, text, reSetupAcc, cResponse)
        color(storage, text, reError, cError)
        color(storage, text, reSeq, cSeq)
        color(storage, text, reArrowOut, cRequest)   // → matches request color
        color(storage, text, reArrowIn, cResponse)   // ← matches response color
        color(storage, text, reHex, cHex)
        color(storage, text, reString, cString)

        storage.endEditing()
    }

    /// Paint every match of `regex` (or its capture `group`) in `color`.
    private func color(_ storage: NSTextStorage, _ text: String,
                       _ regex: NSRegularExpression, _ color: NSColor, group: Int = 0) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let r = match.range(at: group)
            guard r.location != NSNotFound, r.length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
