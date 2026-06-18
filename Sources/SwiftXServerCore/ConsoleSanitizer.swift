import Foundation

/// Result of feeding a raw serial chunk to `ConsoleSanitizer`: zero or more
/// finished lines to append to the transcript, plus the current in-progress
/// line (no trailing newline). The in-progress line is what makes a spinner
/// animate -- the window re-renders it on every chunk, so `-\b\|\b/` cycles a
/// single column in place.
public struct ConsoleUpdate: Equatable {
    public let completedLines: [String]
    public let currentLine: String
    public init(completedLines: [String], currentLine: String) {
        self.completedLines = completedLines
        self.currentLine = currentLine
    }
}

/// Minimal sanitizer for a read-only serial-console transcript. NOT a terminal
/// emulator -- there is no screen grid, no cursor addressing, no attributes.
/// It does exactly enough to keep an append-only log clean:
///
/// - **LF** flushes the current line.
/// - **CR** returns the cursor to column 0 (so `\r\n` collapses to one newline,
///   and a progress/spinner reprint overwrites in place).
/// - **BS** moves the cursor left one column; the next printable char overwrites
///   (so the `x\b \b` echo-erase pattern and `\b`-driven spinners read cleanly).
/// - **TAB** expands to spaces (8-column stops).
/// - **BEL** and other non-printing C0/DEL bytes are dropped.
/// - **Escape sequences** (CSI `ESC [ … `, OSC, charset/2-char `ESC x`) are
///   stripped. We deliberately do NOT honor cursor/clear escapes: this is an
///   append-only log, and honoring `ESC[2J`/`ESC[H` would wipe scrollback.
///
/// State (current line, cursor column, escape-parser state) carries across
/// `feed` calls, because the pipe splits output at arbitrary byte boundaries --
/// an escape sequence or a `\r` can land split across two reads.
public final class ConsoleSanitizer {

    private var line: [Character] = []
    private var col = 0

    private enum Esc {
        case none      // normal text
        case esc       // just saw ESC, expecting the next byte
        case csi       // inside ESC [ … , consume until a final byte 0x40–0x7E
        case osc       // inside ESC ] … , consume until BEL or ESC (ST)
        case charset   // ESC ( ) * + - . / # : consume one designator byte
    }
    private var esc: Esc = .none

    private static let tabWidth = 8

    public init() {}

    /// Drop all state (call when a new run starts so a fresh boot doesn't
    /// inherit a half-parsed escape or a stale current line).
    public func reset() {
        line = []
        col = 0
        esc = .none
    }

    public func feed(_ raw: String) -> ConsoleUpdate {
        var completed: [String] = []

        for scalar in raw.unicodeScalars {
            let v = scalar.value

            switch esc {
            case .esc:
                switch scalar {
                case "[": esc = .csi
                case "]": esc = .osc
                case "(", ")", "*", "+", "-", ".", "/", "#": esc = .charset
                default:  esc = .none   // two-char sequence (ESC c, ESC =, …): byte consumed
                }
                continue
            case .csi:
                if (0x40...0x7E).contains(v) { esc = .none }   // final byte ends CSI
                continue
            case .osc:
                if v == 0x07 || v == 0x1B { esc = .none }       // BEL or ST terminates OSC
                continue
            case .charset:
                esc = .none                                     // designator byte consumed
                continue
            case .none:
                break
            }

            switch v {
            case 0x1B:                      // ESC
                esc = .esc
            case 0x0A:                      // LF -> flush line
                completed.append(String(line))
                line = []
                col = 0
            case 0x0D:                      // CR -> cursor to column 0
                col = 0
            case 0x08:                      // BS -> cursor left
                if col > 0 { col -= 1 }
            case 0x09:                      // TAB -> spaces to next stop
                let n = Self.tabWidth - (col % Self.tabWidth)
                for _ in 0..<n { write(" ") }
            case 0x07:                      // BEL -> drop
                break
            case 0..<0x20, 0x7F:            // other C0 controls + DEL -> drop
                break
            default:                        // printable -> write at cursor
                write(Character(scalar))
            }
        }

        return ConsoleUpdate(completedLines: completed, currentLine: String(line))
    }

    /// Write one char at the cursor: overwrite if the column already exists,
    /// append if we're at the end. Advances the cursor. Keeps `col <= line.count`.
    private func write(_ c: Character) {
        if col < line.count {
            line[col] = c
        } else {
            line.append(c)
        }
        col += 1
    }
}
