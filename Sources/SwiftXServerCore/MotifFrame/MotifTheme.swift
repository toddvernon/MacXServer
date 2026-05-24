import AppKit

// Three-color OSF/Motif (mwm) palette + the geometry constants every other
// piece of frame drawing derives from. Single source of truth: change
// titleBarHeight to scale everything proportionally, change bevelWidth or
// frameWidth to fatten the band without touching the buttons. See
// MotifFrame/MotifFrameDrawOrder.md (in the original WindowTest prototype)
// for the dependency graph.

public enum MotifFrameButtonStyle: String, Sendable {
    case motif         // raised inner glyph (default)
    case trafficLights // red / yellow / green dots
}

public struct MotifTheme {

    // Palette — three colors only. Don't introduce intermediate greys; the
    // mwm aesthetic depends on the limited palette.
    public static let highlight  = NSColor(srgbRed: 0xEC/255, green: 0xEC/255, blue: 0xEE/255, alpha: 1)
    public static let fill       = NSColor(srgbRed: 0xB8/255, green: 0xBA/255, blue: 0xC0/255, alpha: 1)
    public static let shadow     = NSColor(srgbRed: 0x46/255, green: 0x47/255, blue: 0x4C/255, alpha: 1)
    public static let titleColor = NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1)

    // Three primary geometry inputs. Everything else derives from these.
    public static let bevelWidth: CGFloat = 2
    public static let frameWidth: CGFloat = 2
    public static let titleBarHeight: CGFloat = 32

    /// Total band thickness: outerBevel + bandFill + innerBevel.
    public static var band: CGFloat { frameWidth + 2 * bevelWidth }

    /// Title-bar buttons are square and exactly titleBarHeight tall.
    public static var buttonSize: CGFloat { titleBarHeight }

    /// Gap between innerBevel and title-bar elements so the bevel lines
    /// remain visible around the buttons.
    public static var buttonInset: CGFloat { bevelWidth }

    public static var titleFontSize: CGFloat { max(9, titleBarHeight * 0.55) }

    // Glyph dimensions inside the title-bar buttons.
    public static var menuDashW: CGFloat  { round(titleBarHeight * 0.64) }
    public static var menuDashH: CGFloat  { round(titleBarHeight * 0.18) }
    public static var restoreSq: CGFloat  { round(titleBarHeight * 0.18) }
    public static var maximizeSq: CGFloat { round(titleBarHeight * 0.64) }

    // macOS traffic-light colors (used when buttonStyle == .trafficLights).
    public static let macRed    = NSColor(srgbRed: 0xFF/255, green: 0x5F/255, blue: 0x57/255, alpha: 1)
    public static let macYellow = NSColor(srgbRed: 0xFE/255, green: 0xBC/255, blue: 0x2E/255, alpha: 1)
    public static let macGreen  = NSColor(srgbRed: 0x28/255, green: 0xC8/255, blue: 0x40/255, alpha: 1)

    // ── Frame-to-NSWindow geometry helpers ───────────────────────────────

    /// Inset from NSWindow content origin to the X client area. Same on
    /// left, right, bottom. Top is taller because the title row + buttons
    /// sit between the band and the client area.
    public static var clientLeftInset: CGFloat   { band + bevelWidth }
    public static var clientRightInset: CGFloat  { band + bevelWidth }
    public static var clientBottomInset: CGFloat { band + bevelWidth }
    public static var clientTopInset: CGFloat {
        // titleRowY (= band + buttonInset) + buttonSize, plus one bevel
        // gap so the title-row's own bevel lines stay visible against the
        // client area.
        band + buttonInset + buttonSize + bevelWidth
    }

    /// Total horizontal padding the frame adds around the X client area.
    public static var horizontalPadding: CGFloat { clientLeftInset + clientRightInset }

    /// Total vertical padding the frame adds (title bar on top + band on
    /// the bottom).
    public static var verticalPadding: CGFloat { clientTopInset + clientBottomInset }
}
