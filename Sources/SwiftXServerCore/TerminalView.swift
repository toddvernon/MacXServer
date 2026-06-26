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

        // Layer-backed with a black background so any margin beyond the integer
        // grid (the window rarely divides evenly into cells) reads as terminal
        // background rather than empty.
        wantsLayer = true
        layer?.backgroundColor = TerminalView.cg(TerminalEmulator.Cell.blank.bg)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }   // row 0 at the top
    public override var acceptsFirstResponder: Bool { true }

    // Click anywhere in the terminal to focus it, so typing goes to the guest.
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Resize (grid follows the window; the guest is synced manually)

    /// Current grid size, so the host's "Resize TTY" button can push a matching
    /// stty on demand. We deliberately do NOT auto-push on every reflow: a
    /// serial line has no SIGWINCH, so the only way to tell the guest is to type
    /// `stty`, and injecting that into whatever the user is doing (an editor,
    /// cm) corrupts it. The display follows the window live; the guest syncs
    /// when the user presses the button at a safe moment.
    public var gridSize: (rows: Int, cols: Int) { (term.rows, term.cols) }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reflowToFit()
    }

    /// Recompute the grid from the current bounds + integer cell metrics and
    /// reflow the emulator. Display-only; does not touch the guest.
    private func reflowToFit() {
        let cols = max(1, Int(bounds.width / cellW))
        let rows = max(1, Int(bounds.height / cellH))
        guard rows != term.rows || cols != term.cols else { return }
        term.resize(rows: rows, cols: cols)
        grid = term.grid()
        cursor = term.cursor()
        needsDisplay = true
    }

    private var refreshScheduled = false

    /// Coalesced refresh: schedule ONE grid re-read + repaint for the next
    /// main-queue turn, deduped. The guest/qemu deliver console output in many
    /// small chunks (the ESCC transmits byte-by-byte), so calling the full
    /// `refresh()` per chunk meant rebuilding the whole 1920-cell grid hundreds
    /// of times for a single screen update -- a `top` repaint took ~5s. With
    /// coalescing a burst of feeds collapses to one rebuild + one draw, and we
    /// naturally render only the final state.
    public func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Pull the emulator's new state and invalidate only the cells that
    /// changed (plus the old/new cursor cells). Synchronous; prefer
    /// `setNeedsRefresh()` on the hot path so bursts coalesce.
    public func refresh() {
        let newGrid = term.grid()
        let newCursor = term.cursor()

        if newGrid.count == grid.count {
            for r in 0..<newGrid.count where r < grid.count {
                let oldRow = grid[r], newRow = newGrid[r]
                if oldRow.count == newRow.count {
                    for c in 0..<newRow.count where newRow[c] != oldRow[c] {
                        setNeedsDisplay(cellRect(row: r, col: c))
                    }
                } else {
                    needsDisplay = true   // row width changed -> full repaint
                }
            }
        } else {
            needsDisplay = true           // grid dimensions changed
        }

        if newCursor != cursor {
            setNeedsDisplay(cellRect(row: cursor.row, col: cursor.col))
            setNeedsDisplay(cellRect(row: newCursor.row, col: newCursor.col))
        }

        grid = newGrid
        cursor = newCursor
    }

    // MARK: - Drawing

    private func cellRect(row: Int, col: Int) -> NSRect {
        NSRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH,
               width: cellW, height: cellH)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Each cell paints its own background, so we redraw exactly the cells
        // that intersect the dirty region and leave the rest untouched. We do
        // NOT blanket-fill dirtyRect first: it's the bounding box of possibly
        // scattered dirty cells, and filling it would erase the live cells
        // between them (e.g. text under a cursor that jumped across a line).
        // needsToDraw honors AppKit's real (possibly disjoint) dirty region.
        // Cells tile the view exactly (integer metrics), so there are no gaps.
        for row in 0..<grid.count {
            for col in 0..<grid[row].count {
                guard needsToDraw(cellRect(row: row, col: col)) else { continue }
                drawCell(grid[row][col], row: row, col: col, isCursor: false)
            }
        }

        if cursor.visible,
           cursor.row >= 0, cursor.row < grid.count,
           cursor.col >= 0, cursor.col < grid[cursor.row].count,
           needsToDraw(cellRect(row: cursor.row, col: cursor.col)) {
            drawCell(grid[cursor.row][cursor.col],
                     row: cursor.row, col: cursor.col, isCursor: true)
        }
    }

    private func drawCell(_ cell: TerminalEmulator.Cell, row: Int, col: Int, isCursor: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = cellRect(row: row, col: col)

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
