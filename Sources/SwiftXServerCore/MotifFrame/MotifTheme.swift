import AppKit

public enum MotifFrameButtonStyle: String, Sendable {
    case motif
    case trafficLights
}

public struct MotifTheme: @unchecked Sendable {

    public var highlight: NSColor
    public var fill: NSColor
    public var shadow: NSColor
    public var titleColor: NSColor

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

    // MARK: - Defaults

    public static let `default` = MotifTheme(
        highlight: NSColor(srgbRed: 0xEC/255, green: 0xEC/255, blue: 0xEE/255, alpha: 1),
        fill: NSColor(srgbRed: 0xB8/255, green: 0xBA/255, blue: 0xC0/255, alpha: 1),
        shadow: NSColor(srgbRed: 0x46/255, green: 0x47/255, blue: 0x4C/255, alpha: 1),
        titleColor: NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1),
        bevelWidth: 2,
        frameWidth: 2,
        titleBarHeight: 32,
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

        if let v = settings["Mwm*background"]        { theme.fill = parseColor(v) ?? theme.fill }
        if let v = settings["Mwm*topShadowColor"]    { theme.highlight = parseColor(v) ?? theme.highlight }
        if let v = settings["Mwm*bottomShadowColor"] { theme.shadow = parseColor(v) ?? theme.shadow }
        if let v = settings["Mwm*title*foreground"]   { theme.titleColor = parseColor(v) ?? theme.titleColor }
        if let v = settings["Mwm*frameBorderWidth"]  { theme.frameWidth = CGFloat(Double(v) ?? Double(theme.frameWidth)) }
        if let v = settings["Mwm*resizeBorderWidth"] { theme.bevelWidth = CGFloat(Double(v) ?? Double(theme.bevelWidth)) }
        if let v = settings["Mwm*titleBarHeight"]    { theme.titleBarHeight = CGFloat(Double(v) ?? Double(theme.titleBarHeight)) }
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
