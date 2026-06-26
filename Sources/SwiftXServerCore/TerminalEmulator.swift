import Foundation
import CVTerm

// TerminalEmulator -- a thin Swift wrapper over the vendored libvterm
// (Sources/CVTerm). It is the emulator half of the interactive console
// terminal (CONSOLE_TERMINAL.md): you feed it the bytes coming off the
// serial console, it maintains an rows x cols screen grid + cursor, and it
// turns key/text input into the bytes to write back to the console.
//
// Spike scope: pull-based, no C callbacks. After feed() we flush libvterm's
// damage and the caller reads the whole grid via `grid()` -- an 80x24
// rebuild is trivial and sidesteps all C-function-pointer plumbing for now.
// Input keys go in and the resulting wire bytes come back out of libvterm's
// own output buffer via vterm_output_read. Scrollback (sb_pushline) and
// incremental damage are deliberately deferred past the spike.
//
// Threading: not thread-safe. Drive it from one queue (the UI/main thread
// in the app). Marshal SerialConsoleClient.onData onto that queue first.
public final class TerminalEmulator {

    /// One screen cell: its character(s), resolved RGB colors, and the
    /// attributes the renderer cares about. Colors are pre-resolved to RGB
    /// here (libvterm cells can be indexed/default) so the view never has to
    /// know about VTermColor.
    public struct Cell: Equatable, Sendable {
        public var text: String          // the cell glyph(s); " " when blank
        public var fg: RGB
        public var bg: RGB
        public var bold: Bool
        public var underline: Bool
        public var reverse: Bool

        public static let blank = Cell(text: " ",
                                       fg: RGB(176, 176, 176),
                                       bg: RGB(0, 0, 0),
                                       bold: false, underline: false, reverse: false)
    }

    public struct RGB: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    public struct Cursor: Equatable, Sendable {
        public var row: Int
        public var col: Int
        public var visible: Bool
    }

    public private(set) var rows: Int
    public private(set) var cols: Int

    private let vt: OpaquePointer
    private let screen: OpaquePointer
    private let state: OpaquePointer

    public init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(vt, 1)
        screen = vterm_obtain_screen(vt)
        state = vterm_obtain_state(vt)
        // Honor the alternate-screen buffer (DEC ?1047/?1049): full-screen apps
        // (vi, less, curses) swap to it and restore on exit instead of
        // scribbling over the main screen. NOTE: the old ?47 form is NOT
        // handled by libvterm 0.3.3 (logs "Unknown DEC mode 47"); apps using
        // it -- e.g. cm -- still redraw on the main screen. A small vendored
        // patch mapping 47 -> 1047 is the follow-up if that matters.
        vterm_screen_enable_altscreen(screen, 1)
        vterm_screen_reset(screen, 1)   // hard reset: clears + sets defaults
    }

    deinit { vterm_free(vt) }

    // MARK: - Output side (console -> screen)

    /// Feed bytes read from the console into the emulator and settle the
    /// screen model. Call `grid()` afterward to read the new state.
    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: CChar.self).baseAddress {
                _ = vterm_input_write(vt, base, data.count)
            }
        }
        vterm_screen_flush_damage(screen)
    }

    /// The full rows x cols grid, top-to-bottom, left-to-right. Colors are
    /// resolved to RGB; the renderer can draw this directly.
    public func grid() -> [[Cell]] {
        var out = [[Cell]]()
        out.reserveCapacity(rows)
        for row in 0..<rows {
            var line = [Cell]()
            line.reserveCapacity(cols)
            for col in 0..<cols {
                line.append(cell(row: row, col: col))
            }
            out.append(line)
        }
        return out
    }

    public func cursor() -> Cursor {
        var pos = VTermPos()
        vterm_state_get_cursorpos(state, &pos)
        return Cursor(row: Int(pos.row), col: Int(pos.col), visible: cursorVisible)
    }

    private var cursorVisible = true

    private func cell(row: Int, col: Int) -> Cell {
        var c = VTermScreenCell()
        let pos = VTermPos(row: Int32(row), col: Int32(col))
        guard vterm_screen_get_cell(screen, pos, &c) != 0 else { return .blank }

        // chars[] is a fixed C array of up to VTERM_MAX_CHARS_PER_CELL
        // codepoints (base + combining). chars[0] == 0 means a blank cell.
        var scalars = [Unicode.Scalar]()
        withUnsafeBytes(of: c.chars) { raw in
            let cps = raw.bindMemory(to: UInt32.self)
            for cp in cps {
                if cp == 0 { break }
                if let s = Unicode.Scalar(cp) { scalars.append(s) }
            }
        }
        let text = scalars.isEmpty ? " " : String(String.UnicodeScalarView(scalars))

        return Cell(text: text,
                    fg: resolve(c.fg),
                    bg: resolve(c.bg),
                    bold: c.attrs.bold != 0,
                    underline: c.attrs.underline != 0,
                    reverse: c.attrs.reverse != 0)
    }

    /// Resolve a (possibly indexed/default) VTermColor to concrete RGB.
    private func resolve(_ color: VTermColor) -> RGB {
        var c = color
        vterm_screen_convert_color_to_rgb(screen, &c)
        return RGB(c.rgb.red, c.rgb.green, c.rgb.blue)
    }

    // MARK: - Input side (keys -> console bytes)

    /// Send literal text (each scalar as a key press). Returns the wire bytes
    /// the caller should write to the console socket.
    public func sendText(_ s: String, mod: VTermModifier = VTERM_MOD_NONE) -> Data {
        for scalar in s.unicodeScalars {
            vterm_keyboard_unichar(vt, scalar.value, mod)
        }
        return drainOutput()
    }

    /// Send a special key (arrows, Enter, Backspace, ...). Returns the wire
    /// bytes to write to the console socket. libvterm encodes per the current
    /// cursor-key mode (DECCKM) for us.
    public func sendKey(_ key: VTermKey, mod: VTermModifier = VTERM_MOD_NONE) -> Data {
        vterm_keyboard_key(vt, key, mod)
        return drainOutput()
    }

    /// Drain libvterm's pending output (the bytes produced by the key calls).
    private func drainOutput() -> Data {
        var data = Data()
        var buf = [CChar](repeating: 0, count: 256)
        while true {
            let n = buf.withUnsafeMutableBufferPointer {
                vterm_output_read(vt, $0.baseAddress, $0.count)
            }
            if n == 0 { break }
            buf.prefix(n).withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }
}
