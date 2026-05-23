import AppKit

// Line-number column for the resources editor. A plain NSView (not an
// NSRulerView) drawn beside the editor's NSScrollView — see SHORTCUTS
// "Line-number gutter deferred" for the NSRulerView story we abandoned.
// Going through a plain view sidesteps the layout entanglement that
// caused NSRulerView to scramble SwiftUI's NSViewRepresentable hosting.
//
// The gutter is driven entirely by the editor's NSTextView: it asks the
// layout manager for visible line fragments, counts newlines to derive
// each fragment's logical line number, and draws right-aligned in the
// theme's gutter colors. Scroll position comes via a clip-view bounds
// observer that the container hooks up.

final class LineNumberGutter: NSView {

    private let theme: EditorTheme
    private let font: NSFont
    weak var textView: NSTextView?

    /// Y offset from the top of the text view's content to the top of the
    /// visible area — the container updates this on scroll. Used to map
    /// line-fragment y positions (which are in text-container coords) to
    /// our flipped view coords.
    var scrollOffset: CGFloat = 0 {
        didSet { if scrollOffset != oldValue { needsDisplay = true } }
    }

    init(theme: EditorTheme, font: NSFont) {
        self.theme = theme
        // One point smaller than the editor font so numbers read as
        // secondary; monospacedDigit so digit columns line up across line
        // counts.
        self.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        // Match the text view's coordinate system so line-fragment y
        // values from layoutManager can be plotted directly.
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Top-left origin like the text view so y math matches up.
    override var isFlipped: Bool { true }

    /// Preferred width based on the digit count of the largest line
    /// number we'd display. The container reads this whenever the text
    /// changes and re-runs its layout.
    var preferredWidth: CGFloat {
        let digits = max(2, String(lineCount()).count)
        let digitW = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * digitW + 16)   // 8pt padding each side
    }

    private func lineCount() -> Int {
        guard let s = textView?.string, !s.isEmpty else { return 1 }
        var n = 1
        for ch in s where ch == "\n" { n += 1 }
        return n
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        // Background — fill the dirty rect, not bounds, so partial
        // redraws cover stale content under AppKit's dirty-rect clipping.
        theme.gutterBackground.setFill()
        rect.fill()

        // Subtle right-edge divider matching what the NSRulerView version
        // had.
        theme.gutterForeground.withAlphaComponent(0.25).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        divider.lineWidth = 1
        divider.stroke()

        guard
            let textView = textView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }

        // Visible glyph range relative to the text view's full content,
        // not just the area corresponding to our dirty rect (we draw all
        // visible labels; AppKit clips to the dirty rect for us).
        let visibleTextRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleTextRect, in: container)
        if visibleGlyphRange.length == 0 { return }

        let str = textView.string as NSString
        let textInset = textView.textContainerInset.height
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.gutterForeground,
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { rect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let lineNo = self.lineNumber(forCharacterAt: charIndex, in: str)

            // rect.minY is in text-container coords. Add the text-view's
            // top inset, then subtract scrollOffset to get our y. Both
            // we and the text view are flipped, so this is straight
            // subtraction.
            let yInGutter = (rect.minY + textInset) - self.scrollOffset

            let label = "\(lineNo)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let x = self.bounds.width - labelSize.width - 8   // right-align, 8pt right pad
            label.draw(at: NSPoint(x: x, y: yInGutter), withAttributes: attrs)
        }
    }

    private func lineNumber(forCharacterAt index: Int, in str: NSString) -> Int {
        var n = 1
        var i = 0
        let cap = min(index, str.length)
        while i < cap {
            if str.character(at: i) == 0x0A { n += 1 }
            i += 1
        }
        return n
    }
}
