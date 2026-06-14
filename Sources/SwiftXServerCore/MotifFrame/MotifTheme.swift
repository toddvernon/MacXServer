import AppKit

public enum MotifFrameButtonStyle: String, Sendable {
    case motif
    case trafficLights
}

/// The four chrome colors that vary with focus state. Built by derivation
/// from a single base background, but exposed as a flat struct so draw
/// code doesn't have to know about derivation.
public struct MotifStateColors: Sendable {
    public let fill: NSColor        // background
    public let highlight: NSColor   // top-shadow (lighter)
    public let shadow: NSColor      // bottom-shadow (darker)
    public let titleColor: NSColor  // title-bar text
}

public struct MotifTheme: @unchecked Sendable {

    // MARK: - Source colors (the two knobs)

    /// Active-window background. Everything else (active highlight/shadow/
    /// title-text, and the entire inactive palette) is derived from this
    /// unless `inactiveBackground` is set explicitly.
    public var activeBackground: NSColor

    /// Inactive-window background. `nil` means derive from `activeBackground`
    /// by blending toward neutral gray — the recommended default. Set
    /// explicitly via `Mwm*inactiveBackground` to pick a specific shade.
    public var inactiveBackground: NSColor?

    // MARK: - Geometry / style (state-independent)

    public var bevelWidth: CGFloat
    public var frameWidth: CGFloat
    public var titleBarHeight: CGFloat
    public var buttonStyle: MotifFrameButtonStyle

    public var band: CGFloat { frameWidth + 2 * bevelWidth }
    public var buttonSize: CGFloat { titleBarHeight }
    public var buttonInset: CGFloat { bevelWidth }
    public var titleFontSize: CGFloat { max(9, titleBarHeight * 0.55) }

    public var menuDashW: CGFloat  { round(titleBarHeight * 0.64) }
    public var menuDashH: CGFloat  { round(titleBarHeight * 0.18) }
    public var restoreSq: CGFloat  { round(titleBarHeight * 0.18) }
    public var maximizeSq: CGFloat { round(titleBarHeight * 0.64) }

    public static let macRed    = NSColor(srgbRed: 0xFF/255, green: 0x5F/255, blue: 0x57/255, alpha: 1)
    public static let macYellow = NSColor(srgbRed: 0xFE/255, green: 0xBC/255, blue: 0x2E/255, alpha: 1)
    public static let macGreen  = NSColor(srgbRed: 0x28/255, green: 0xC8/255, blue: 0x40/255, alpha: 1)

    public var clientLeftInset: CGFloat   { band + bevelWidth }
    public var clientRightInset: CGFloat  { band + bevelWidth }
    public var clientBottomInset: CGFloat { band + bevelWidth }
    public var clientTopInset: CGFloat {
        band + buttonInset + buttonSize + bevelWidth
    }
    public var horizontalPadding: CGFloat { clientLeftInset + clientRightInset }
    public var verticalPadding: CGFloat { clientTopInset + clientBottomInset }

    // MARK: - Derivation

    /// Resolved inactive background — explicit override if set, else derived
    /// from the active background by blending 35% toward neutral gray.
    public var resolvedInactiveBackground: NSColor {
        if let explicit = inactiveBackground { return explicit }
        return MotifTheme.deriveInactive(from: activeBackground)
    }

    public var activeColors: MotifStateColors {
        return MotifTheme.colors(for: activeBackground)
    }

    public var inactiveColors: MotifStateColors {
        return MotifTheme.colors(for: resolvedInactiveBackground)
    }

    /// Build a full chrome color set from a single background. Matches
    /// mwm's `XmGetColors` convention: top-shadow is the bg lightened
    /// toward white, bottom-shadow is the bg darkened toward black.
    /// Fractions are tuned so the default `#B8BAC0` base reproduces the
    /// look of the original hardcoded `#ECECEE` / `#46474C` shadows
    /// (highlight ≈ +0.7 toward white, shadow ≈ +0.6 toward black).
    public static func colors(for bg: NSColor) -> MotifStateColors {
        let highlight = blend(bg, toward: .white, fraction: 0.70)
        let shadow    = blend(bg, toward: .black, fraction: 0.60)
        let titleColor = contrastingTitleColor(for: bg)
        return MotifStateColors(
            fill: bg,
            highlight: highlight,
            shadow: shadow,
            titleColor: titleColor
        )
    }

    /// Derive an inactive background by blending the active background 50%
    /// toward a dark neutral gray. Both darkens (drops the value ~25%) and
    /// desaturates so inactive windows recede visibly from active ones
    /// without losing the visual family. For default `#B8BAC0` active,
    /// inactive resolves near `#8C8E92`.
    public static func deriveInactive(from active: NSColor) -> NSColor {
        let darkNeutral = NSColor(srgbRed: 0x60/255, green: 0x60/255, blue: 0x60/255, alpha: 1)
        return blend(active, toward: darkNeutral, fraction: 0.50)
    }

    /// Pick title-text color based on background luminance: near-black on
    /// light backgrounds, near-white on dark ones. For an inactive window,
    /// further blend the result halfway toward the bg so the title fades.
    private static func contrastingTitleColor(for bg: NSColor) -> NSColor {
        let s = bg.usingColorSpace(.sRGB) ?? bg
        let luminance = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        return luminance > 0.5
            ? NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1)
            : NSColor(srgbRed: 0xF0/255, green: 0xF0/255, blue: 0xF0/255, alpha: 1)
    }

    private static func blend(_ a: NSColor, toward b: NSColor, fraction: CGFloat) -> NSColor {
        return a.blended(withFraction: fraction, of: b) ?? a
    }

    // MARK: - Defaults

    // Defaults match the `[motif-frame]` block in DefaultThemes.seedContent
    // exactly, so a user with no resource file, an empty section, or fully
    // commented values sees the same chrome as a first-launch user.
    public static let `default` = MotifTheme(
        activeBackground: NSColor(srgbRed: 0xB8/255, green: 0xBA/255, blue: 0xC0/255, alpha: 1),
        inactiveBackground: nil,
        bevelWidth: 1,
        frameWidth: 3,
        titleBarHeight: 26,
        buttonStyle: .motif
    )

    // MARK: - Shared instance

    nonisolated(unsafe) private static var _current: MotifTheme = .default
    private static let lock = NSLock()

    public static var current: MotifTheme {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    public static func install(_ theme: MotifTheme) {
        lock.lock(); defer { lock.unlock() }
        _current = theme
    }

    // MARK: - Load from resource file

    public static func fromResourceFile(_ settings: [String: String]) -> MotifTheme {
        var theme = MotifTheme.default

        if let v = settings["Mwm*background"]          { theme.activeBackground   = parseColor(v) ?? theme.activeBackground }
        if let v = settings["Mwm*inactiveBackground"]  { theme.inactiveBackground = parseColor(v) }
        if let v = settings["Mwm*frameBorderWidth"]    { theme.frameWidth     = CGFloat(Double(v) ?? Double(theme.frameWidth)) }
        if let v = settings["Mwm*resizeBorderWidth"]   { theme.bevelWidth     = CGFloat(Double(v) ?? Double(theme.bevelWidth)) }
        if let v = settings["Mwm*titleBarHeight"]      { theme.titleBarHeight = CGFloat(Double(v) ?? Double(theme.titleBarHeight)) }
        if let v = settings["Mwm*buttonStyle"] {
            theme.buttonStyle = MotifFrameButtonStyle(rawValue: v) ?? theme.buttonStyle
        }
        return theme
    }

    private static func parseColor(_ value: String) -> NSColor? {
        guard let rgb = XColorDatabase.lookup(value) else { return nil }
        return NSColor(
            srgbRed: CGFloat(rgb.red) / 65535,
            green: CGFloat(rgb.green) / 65535,
            blue: CGFloat(rgb.blue) / 65535,
            alpha: 1
        )
    }
}
