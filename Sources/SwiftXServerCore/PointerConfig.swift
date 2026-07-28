import Foundation

/// Server-wide pointer behavior knobs. Owned by the app side (SwiftXServer
/// reads UserDefaults via `Preferences` and installs us via `install`);
/// `FlippedXView.dispatchMouse` / `dispatchDrag` and the bridge's
/// `dispatchCrossWindowDrag` read `current` per click. Single source of
/// truth — every site that turns a Mac physical button index into a
/// wire-X button number routes through `remapButton`, so press, release
/// (via FlippedXView OR via the bridge's cross-window drag monitor), and
/// drag MotionNotify state all agree.
public struct PointerConfig: Sendable {

    /// X wire button to emit when the user clicks the Mac primary
    /// (left) mouse button. Default 1 (the X11 "primary" button used
    /// for select / activate / scrollbar-scroll-forward).
    public var leftClickWireButton: UInt8

    /// X wire button to emit when the user clicks the Mac wheel /
    /// middle button. Default 2 (the X11 "middle" button used for
    /// scrollbar thumb grab / xterm paste / Motif drag).
    public var wheelClickWireButton: UInt8

    /// X wire button to emit when the user clicks the Mac secondary
    /// (right) mouse button. Default 3 (the X11 "secondary" button
    /// used for scrollbar-scroll-backward / Motif post-menu / xterm
    /// extend-selection).
    public var rightClickWireButton: UInt8

    /// XTERM EXTENSION (first of what we expect to become a small family
    /// of server-side-knows-the-client hacks). When true, every click that
    /// lands in an xterm-shaped scrollbar widget is force-rewritten to
    /// wire button 2 — "grab thumb." The per-Mac-button popup mapping
    /// still applies in xterm's content area, so left-click still selects
    /// text. Effectively gives xterm the Mac-style scrollbar behavior
    /// without distorting button semantics anywhere else.
    public var xtermScrollbarThumbOverride: Bool

    /// XTERM EXTENSION (sibling of the scrollbar override). When true, a
    /// right-click on an xterm window pops a native Copy/Paste menu (the
    /// iTerm2 pattern) instead of sending wire button 3 to the client.
    /// Gated on the per-window xterm flag in `FlippedXView`, so Motif/CDE
    /// clients — which use button 3 for their own menus — are untouched,
    /// and left-button text selection in xterm is unaffected.
    public var xtermRightClickMenu: Bool

    /// XTERM EXTENSION (rendering). When true, the server reskins the xterm
    /// scrollbar: it suppresses xterm's gray-stipple thumb and flat trough and
    /// draws a Motif XmScrollBar look (recessed trough + raised beveled slider)
    /// in the same window, colored from the live Motif frame palette. Read in
    /// core at draw time (ServerSession), like the thumb override.
    public var xtermScrollbarMotifSkin: Bool

    public init(
        leftClickWireButton: UInt8 = 1,
        wheelClickWireButton: UInt8 = 2,
        rightClickWireButton: UInt8 = 3,
        xtermScrollbarThumbOverride: Bool = false,
        xtermRightClickMenu: Bool = false,
        xtermScrollbarMotifSkin: Bool = false
    ) {
        self.leftClickWireButton = leftClickWireButton
        self.wheelClickWireButton = wheelClickWireButton
        self.rightClickWireButton = rightClickWireButton
        self.xtermScrollbarThumbOverride = xtermScrollbarThumbOverride
        self.xtermRightClickMenu = xtermRightClickMenu
        self.xtermScrollbarMotifSkin = xtermScrollbarMotifSkin
    }

    /// The inert X11-identity baseline: 1/2/3 mapping, every xterm extension
    /// off. This is what core and tests run with when nothing installs a
    /// config -- it is NOT the new-user seed. The app's seed lives in the
    /// registered defaults in `Preferences` (app side) and is installed over
    /// this at startup via `applyPointerConfig`; the two differ on purpose
    /// (the seed maps wheel-click to 1 and turns the xterm extensions on).
    public static let `default` = PointerConfig()

    /// Apply the per-Mac-physical-button mapping. `macPhysicalButton`:
    /// 1 = Mac left, 2 = Mac wheel/middle, 3 = Mac right (the convention
    /// FlippedXView's mouseDown/rightMouseDown/otherMouseDown overrides
    /// already use). Scroll-wheel synthetic buttons (4/5 vertical, 6/7
    /// horizontal) pass through unchanged.
    public func remapButton(_ macPhysicalButton: UInt8) -> UInt8 {
        switch macPhysicalButton {
        case 1: return leftClickWireButton
        case 2: return wheelClickWireButton
        case 3: return rightClickWireButton
        default: return macPhysicalButton
        }
    }

    // MARK: - Shared instance

    nonisolated(unsafe) private static var _current: PointerConfig = .default
    private static let lock = NSLock()

    public static var current: PointerConfig {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    public static func install(_ config: PointerConfig) {
        lock.lock(); defer { lock.unlock() }
        _current = config
    }
}
