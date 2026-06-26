import AppKit
import CVTerm

// TerminalView -- the rendering half of the interactive console terminal
// (CONSOLE_TERMINAL.md). It owns a TerminalEmulator, draws its cell grid +
// cursor with a monospace font, and turns key events into console bytes via
// the `onInput` callback.
//
// SPIKE STATUS (2026-06-26): this proves the integration unknown -- that we
// can render libvterm's grid with our own Core Text drawing and drive input.
// It is NOT yet wired into SparcPlugConsoleWindowController, and it does the
// boring/obvious thing in a few places that v1 should tighten:
//   - Per-cell draw (no same-attribute run coalescing). Fine for 80x24.
//   - Full-grid repaint on every update (no incremental damage rects).
//   - Self-contained Menlo metrics; v1 should reconcile point-size + the
//     display scaleFactor with FontResolver / XTERM_FONT_QUALITY.md so the
//     console matches the server's text-quality bar.
//   - 16-color + bold/underline/reverse only (matches v1 scope).
public final class TerminalView: NSView {

    /// Wire bytes produced by key input; the host writes these to the console
    /// socket. Set by whoever owns the view.
    public var onInput: ((Data) -> Void)?

    private let term: TerminalEmulator
    private var grid: [[TerminalEmulator.Cell]]
    private var cursor: TerminalEmulator.Cursor

    // Monospace cell metrics, integer per the text-quality discipline.
    private let font: NSFont
    private let boldFont: NSFont
    private let cellW: CGFloat
    private let cellH: CGFloat
    private let ascent: CGFloat

    public init(emulator: TerminalEmulator, pointSize: CGFloat = 13) {
        self.term = emulator
        self.grid = emulator.grid()
        self.cursor = emulator.cursor()

        let f = NSFont(name: "Menlo", size: pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        self.font = f
        self.boldFont = NSFont(name: "Menlo-Bold", size: pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)

        // Cell width = the monospace advance; cell height = ascent + descent
        // + leading, ceil'd to whole pixels so the grid lands on integer
        // boundaries (the reported===rendered discipline).
        self.cellW = ceil(f.maximumAdvancement.width)
        self.ascent = ceil(f.ascender)
        self.cellH = ceil(f.ascender - f.descender + f.leading)

        let size = NSSize(width: cellW * CGFloat(emulator.cols),
                          height: cellH * CGFloat(emulator.rows))
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }   // row 0 at the top
    public override var acceptsFirstResponder: Bool { true }

    /// Push the emulator's current state into the view and redraw. Call after
    /// feeding bytes into the emulator.
    public func refresh() {
        grid = term.grid()
        cursor = term.cursor()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Default background behind everything (also covers any sub-cell gap).
        ctx.setFillColor(TerminalView.cg(TerminalEmulator.Cell.blank.bg))
        ctx.fill(bounds)

        for row in 0..<grid.count {
            for col in 0..<grid[row].count {
                drawCell(grid[row][col], row: row, col: col, isCursor: false)
            }
        }

        if cursor.visible,
           cursor.row >= 0, cursor.row < grid.count,
           cursor.col >= 0, cursor.col < grid[cursor.row].count {
            drawCell(grid[cursor.row][cursor.col],
                     row: cursor.row, col: cursor.col, isCursor: true)
        }
    }

    private func drawCell(_ cell: TerminalEmulator.Cell, row: Int, col: Int, isCursor: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = NSRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH,
                          width: cellW, height: cellH)

        // reverse video and the block cursor both swap fg/bg.
        let swap = cell.reverse != isCursor
        let bg = swap ? cell.fg : cell.bg
        let fg = swap ? cell.bg : cell.fg

        ctx.setFillColor(TerminalView.cg(bg))
        ctx.fill(rect)

        if cell.text != " " {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: cell.bold ? boldFont : font,
                .foregroundColor: NSColor(srgbRed: CGFloat(fg.r) / 255,
                                          green: CGFloat(fg.g) / 255,
                                          blue: CGFloat(fg.b) / 255, alpha: 1),
            ]
            // Baseline at cell-top + ascent; with isFlipped the string draws
            // top-down so we position by the top-left origin.
            let s = NSAttributedString(string: cell.text, attributes: attrs)
            s.draw(at: NSPoint(x: rect.minX, y: rect.minY))
        }

        if cell.underline {
            ctx.setStrokeColor(TerminalView.cg(fg))
            ctx.setLineWidth(1)
            let y = rect.maxY - 1.5
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
        }
    }

    private static func cg(_ c: TerminalEmulator.RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255, alpha: 1)
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        let mod = TerminalView.modifier(from: event.modifierFlags)

        // Special keys first (arrows, navigation, editing).
        if let key = TerminalView.specialKey(for: event.keyCode) {
            emit(term.sendKey(key, mod: mod))
            return
        }

        // Otherwise the typed characters. Strip Control from the flags we pass
        // as text (libvterm applies VTERM_MOD_CTRL itself to fold to a control
        // byte); Option-as-Meta is left for v1.
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        emit(term.sendText(chars, mod: mod))
    }

    private func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        onInput?(data)
    }

    private static func modifier(from flags: NSEvent.ModifierFlags) -> VTermModifier {
        var mod = VTERM_MOD_NONE.rawValue
        if flags.contains(.control) { mod |= VTERM_MOD_CTRL.rawValue }
        if flags.contains(.option)  { mod |= VTERM_MOD_ALT.rawValue }
        if flags.contains(.shift)   { mod |= VTERM_MOD_SHIFT.rawValue }
        return VTermModifier(rawValue: mod)
    }

    /// Map the small set of special keys v1 needs to VTermKey. Returns nil for
    /// ordinary character keys (handled as text).
    private static func specialKey(for keyCode: UInt16) -> VTermKey? {
        switch keyCode {
        case 36, 76: return VTERM_KEY_ENTER        // Return, keypad Enter
        case 48:     return VTERM_KEY_TAB
        case 51:     return VTERM_KEY_BACKSPACE
        case 53:     return VTERM_KEY_ESCAPE
        case 117:    return VTERM_KEY_DEL          // forward delete
        case 126:    return VTERM_KEY_UP
        case 125:    return VTERM_KEY_DOWN
        case 123:    return VTERM_KEY_LEFT
        case 124:    return VTERM_KEY_RIGHT
        case 115:    return VTERM_KEY_HOME
        case 119:    return VTERM_KEY_END
        case 116:    return VTERM_KEY_PAGEUP
        case 121:    return VTERM_KEY_PAGEDOWN
        default:     return nil
        }
    }
}
