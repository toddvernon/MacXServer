import AppKit

// NSView that draws an OSF/Motif (mwm) window-manager decoration: a flat
// raised grey band wrapped around a client area, with a row of raised
// buttons across the top bearing the window title, and L-shaped resize
// grooves cut into all four corners.
//
// One subview (the X client view, typically a FlippedXView) lives at
// `clientRect` and resizes with the frame. All bevel/title/button drawing
// + mouse handling for buttons, title drag, and edge resize is owned here.

public final class MotifFrameView: NSView {

    public var windowTitle: String = "" {
        didSet {
            guard windowTitle != oldValue else { return }
            setNeedsDisplay(titleBarRect())
        }
    }

    public var buttonStyle: MotifFrameButtonStyle = .motif {
        didSet { needsDisplay = true }
    }

    /// Per-window _MOTIF_WM_HINTS overrides; nil = use the static
    /// `[motif-frame]` defaults (every decoration drawn). When non-nil
    /// AND `hasExplicitDecorations` is true, the decoration bits gate
    /// which chrome elements render. Title-bar buttons that the client
    /// hid via this property won't be hit-testable either (`pressedButton`
    /// stays nil because the rect drew empty); resize grooves remain
    /// hit-testable since AppKit owns the actual NSWindow edge resize.
    public var motifHints: MotifWMHints? {
        didSet { needsDisplay = true }
    }

    /// Apply a new _MOTIF_WM_HINTS value (called by the bridge on every
    /// ChangeProperty for `_MOTIF_WM_HINTS`). Equivalent to writing
    /// `motifHints` directly; kept as a named method so the bridge call
    /// site reads cleanly.
    public func applyMotifHints(_ hints: MotifWMHints?) {
        motifHints = hints
    }

    /// True if this decoration bit should render. Default (no hints,
    /// or hints with no explicit DECORATIONS flag): true.
    private func decorationShown(_ bit: MotifWMHints.Decorations) -> Bool {
        guard let h = motifHints, h.hasExplicitDecorations else { return true }
        return h.decorations.contains(bit)
    }

    /// True when the X client has a SHAPE bounding region. Following mwm's
    /// SetFrameShape (frame = rectangular title bar OR'ed with the client's
    /// shape, punting on the resize border), we then draw ONLY the title bar
    /// and leave the rest transparent so the (separately-clipped) shaped
    /// client shows with the desktop around it. Driven by the bridge.
    public var clientIsShaped: Bool = false {
        didSet {
            guard clientIsShaped != oldValue else { return }
            needsDisplay = true
        }
    }

    // Non-opaque while shaped so the area outside the title bar + client shape
    // composites through to the desktop (the NSWindow is made non-opaque too).
    public override var isOpaque: Bool { !clientIsShaped }

    /// The X client view. Installed at init and kept sized to `clientRect`
    /// on every layout pass. Cocoa routes mouse events to it normally as
    /// long as the pointer is inside its frame; events on the surrounding
    /// frame stay with `self`.
    public let clientView: NSView

    /// Pointer-moved handler used while the cursor is over the FRAME
    /// CHROME (not the X client area — the clientView gets its own
    /// mouseMoved). Bridge installs this so the session's global pointer
    /// cache keeps updating across the chrome and root-pollers like xeyes
    /// don't freeze their pupils while the cursor is over the frame.
    /// Args: (x, y in clientView-local X-logical pixels — may be negative
    /// or exceed the client size, since the chrome is outside it; raw
    /// modifier flags).
    public var pointerMovedHandler: ((Int16, Int16, UInt) -> Void)?

    /// Set by CocoaWindowBridge.applyNativeDragLock when an X pointer grab
    /// is active on the owning session. While true, mouseDown short-circuits
    /// before seeding dragOrigin / resizeEdge, so the user can't drag or
    /// resize the window via the Motif chrome. Real X11 prevents this at
    /// the hardware-grab layer; see lockNativeWindowDrag on WindowBridge.
    public var isDragLocked: Bool = false

    /// Fired from mouseDown when isDragLocked is true. The bridge wires this
    /// to fire a ButtonPress at the click location in clientView-local
    /// coords; the click lands well outside the popup geometry, so Motif's
    /// outside-popup detector fires and dismisses the menu. The matching
    /// ButtonRelease comes naturally through the cross-window drag tracker's
    /// mouseUp path. Without this, clicking the chrome while a menu is up
    /// only emits the release on mouseUp — fine for a clean click, but a
    /// click-and-drag attempt visually "does nothing" until release, and
    /// Motif's dismiss heuristics treat press as the canonical signal.
    /// Coords are (x, y, button, modifierFlags) like fireMouse.
    public var outsideGrabClickHandler: ((Int16, Int16, UInt8, UInt) -> Void)?

    public override var isFlipped: Bool { true }

    public init(frame frameRect: NSRect, clientView: NSView) {
        self.clientView = clientView
        super.init(frame: frameRect)
        clientView.autoresizingMask = []   // we manage its frame in resizeSubviews
        addSubview(clientView)
        layoutClientView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutClientView()
        // Repaint the frame chrome on every layout pass — the title bar /
        // grooves / corner buttons all move with the new bounds, and any
        // stray pixels the client view bled into the title region during a
        // live shrink (between bound shrink and bitmap rebuild at end of
        // live resize) get covered over.
        needsDisplay = true
    }

    private func layoutClientView() {
        clientView.frame = clientRect
    }

    // MARK: - Theme aliases (kept short for the drawing math)

    private var bv: CGFloat   { MotifTheme.current.bevelWidth }
    private var band: CGFloat { MotifTheme.current.band }
    private var bs: CGFloat   { MotifTheme.current.buttonSize }
    private var bi: CGFloat   { MotifTheme.current.buttonInset }

    // MARK: - Layout rects

    public var clientRect: NSRect {
        NSRect(
            x: MotifTheme.current.clientLeftInset,
            y: MotifTheme.current.clientTopInset,
            width: max(0, bounds.width - MotifTheme.current.horizontalPadding),
            height: max(0, bounds.height - MotifTheme.current.verticalPadding)
        )
    }

    private var titleRowY: CGFloat { band + bi }

    private func menuButtonRect() -> NSRect {
        NSRect(x: band + bi, y: titleRowY, width: bs, height: bs)
    }
    private func maximizeButtonRect() -> NSRect {
        NSRect(x: bounds.width - band - bi - bs, y: titleRowY, width: bs, height: bs)
    }
    private func restoreButtonRect() -> NSRect {
        let mx = maximizeButtonRect()
        return NSRect(x: mx.minX - bs, y: titleRowY, width: bs, height: bs)
    }
    /// Extent of the title bar text band. When a corner button is hidden
    /// via `_MOTIF_WM_HINTS` decoration bits (Motif convention: the .menu
    /// bit governs the left button, .minimize and .maximize govern the
    /// right pair), the title bar extends into the freed-up corner so
    /// the title text band runs frame-to-frame instead of leaving an
    /// empty chrome carve-out. Matches real Sun mwm rendering on
    /// minimal-decoration dialogs (quickplot About / Quit, every
    /// XmMessageBox / XmFormDialog that requests `decorations =
    /// BORDER | RESIZEH | TITLE`). Verified against u5 2026-06-13.
    /// Marked `internal` (not `private`) so MotifFrameViewGeometryTests
    /// can pin the four cases without going through a real draw cycle.
    func titleBarRect() -> NSRect {
        let left: CGFloat = decorationShown(.menu)
            ? menuButtonRect().maxX
            : (band + bi)
        let right: CGFloat
        if decorationShown(.minimize) {
            // Inner-right button visible: title ends at its left edge.
            right = restoreButtonRect().minX
        } else if decorationShown(.maximize) {
            // Inner-right hidden but outer-right (maximize) visible:
            // title ends at maximize's left edge.
            right = maximizeButtonRect().minX
        } else {
            // Both right buttons hidden: title extends to the frame.
            right = bounds.width - band - bi
        }
        return NSRect(x: left, y: titleRowY, width: max(0, right - left), height: bs)
    }

    /// Full title row (used as the drag-to-move hit zone).
    private var titleDragRect: NSRect {
        NSRect(x: band, y: titleRowY,
               width: bounds.width - 2 * band, height: bs)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width, H = bounds.height

        // Shaped client: mwm draws only the rectangular title bar and lets the
        // client shape show below it, with no surrounding border or resize
        // grooves (SetFrameShape "punts on the resize handle"). Clear to
        // transparent, draw the title-bar strip, done — the shaped client view
        // composites on top in its clientRect.
        if clientIsShaped {
            // Render the EXACT normal top-of-frame chrome (outer raised + inner
            // sunken bevel band + title bar), but clipped to the title-bar
            // strip so the raised band border wraps above and to the sides of
            // the title row just like the unshaped frame. Everything below the
            // client top stays transparent — mwm shapes away the side/bottom
            // border + resize handles for a shaped client (SetFrameShape).
            ctx.clear(bounds)
            ctx.saveGState()
            // Clip the strip to the bottom of the button row (not all the way
            // to clientTopInset) — clientTopInset includes a bevelWidth of band
            // below the buttons, which otherwise shows as a stray sliver of
            // frame fill above the shaped client. Ending at the button bottoms
            // gives the clean lower edge.
            let stripBottom = MotifTheme.current.clientTopInset - MotifTheme.current.bevelWidth
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: stripBottom))
            fill(ctx, bounds, MotifTheme.current.fill)
            bevel(ctx, bounds, topLeft: MotifTheme.current.highlight, bottomRight: MotifTheme.current.shadow)
            let innerTop = CGRect(x: band, y: band, width: W - 2*band, height: H - 2*band)
            bevel(ctx, innerTop, topLeft: MotifTheme.current.shadow, bottomRight: MotifTheme.current.highlight)
            // Corner grooves: the clip keeps the two TOP grab-handle grooves
            // (where the buttons meet the outer frame) and drops the bottom
            // pair, matching mwm punting on the lower resize handles.
            drawCornerGrooves(ctx, W: W, H: H)
            drawTitleBar(ctx)
            ctx.restoreGState()
            return
        }

        // Band body
        fill(ctx, bounds, MotifTheme.current.fill)

        // Outer raised bevel
        bevel(ctx, bounds, topLeft: MotifTheme.current.highlight, bottomRight: MotifTheme.current.shadow)

        // Inner sunken bevel — combined with the outer raised, the band reads
        // as a slab raised from both sides simultaneously.
        let inner = CGRect(x: band, y: band, width: W - 2*band, height: H - 2*band)
        bevel(ctx, inner, topLeft: MotifTheme.current.shadow, bottomRight: MotifTheme.current.highlight)

        drawCornerGrooves(ctx, W: W, H: H)
        drawTitleBar(ctx)
    }

    private func drawTitleBar(_ ctx: CGContext) {
        // If the client explicitly turned the title-bar decoration off via
        // _MOTIF_WM_HINTS, draw nothing in the title strip — the chrome
        // bevel from drawChrome still ringed the bounds, so the empty
        // strip just reads as more grey at the top.
        guard decorationShown(.title) else { return }

        let menuR = menuButtonRect()
        let maxR  = maximizeButtonRect()
        let restR = restoreButtonRect()

        let showMenu     = decorationShown(.menu)
        let showRestore  = decorationShown(.minimize)
        let showMaximize = decorationShown(.maximize)

        if showMenu     { raisedTile(ctx, menuR, pressed: pressedButton == 0) }
        if showMaximize { raisedTile(ctx, maxR,  pressed: pressedButton == 2) }
        if showRestore  { raisedTile(ctx, restR, pressed: pressedButton == 1) }

        switch buttonStyle {
        case .motif:
            if showMenu     { raisedTileCentered(ctx, in: menuR, width: MotifTheme.current.menuDashW, height: MotifTheme.current.menuDashH) }
            if showMaximize { raisedTileCentered(ctx, in: maxR,  width: MotifTheme.current.maximizeSq, height: MotifTheme.current.maximizeSq) }
            if showRestore  { raisedTileCentered(ctx, in: restR, width: MotifTheme.current.restoreSq, height: MotifTheme.current.restoreSq) }
        case .trafficLights:
            if showMenu     { dot(ctx, in: menuR, color: MotifTheme.macRed) }
            if showRestore  { dot(ctx, in: restR, color: MotifTheme.macYellow) }
            if showMaximize { dot(ctx, in: maxR,  color: MotifTheme.macGreen) }
        }

        let titleR = titleBarRect()
        raisedTile(ctx, titleR)
        drawTitleText(in: titleR)
    }

    private func dot(_ ctx: CGContext, in rect: CGRect, color: NSColor) {
        let d = round(MotifTheme.current.titleBarHeight * 0.45)
        let outerD = d + 2 * bv
        let outerR = CGRect(x: rect.midX - outerD/2, y: rect.midY - outerD/2,
                            width: outerD, height: outerD)
        let innerR = CGRect(x: rect.midX - d/2, y: rect.midY - d/2,
                            width: d, height: d)

        // Sunken bevel ring drawn as a linear gradient clipped to the annulus.
        // A hard upper-left/bottom-right split looks abrupt on circles; the
        // gradient sells the recess at any size.
        ctx.saveGState()
        ctx.addEllipse(in: outerR)
        ctx.addEllipse(in: innerR)
        ctx.clip(using: .evenOdd)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [MotifTheme.current.shadow.cgColor, MotifTheme.current.highlight.cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: outerR.minX, y: outerR.minY),
            end:   CGPoint(x: outerR.maxX, y: outerR.maxY),
            options: [])
        ctx.restoreGState()

        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: innerR)
    }

    private func drawTitleText(in rect: CGRect) {
        // dtwm's WmDrawXmString does exactly this: center when the text fits,
        // switch to left-aligned + visual clip (mid-glyph) when it overflows.
        // Real mwm gets the clip for free because the title bar is its own
        // X window of bounded width; we approximate by clipping the draw to
        // the title-bar rect. See reference/cde/cde/programs/dtwm/WmGraphics.c
        // (WmDrawXmString) + WmCDecor.c (GetTextBox).
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MotifTheme.current.titleFontSize, weight: .medium),
            .foregroundColor: MotifTheme.current.titleColor,
        ]
        let text = windowTitle as NSString
        let sz = text.size(withAttributes: attrs)
        let fits = sz.width <= rect.width
        let origin: CGPoint
        if fits {
            origin = CGPoint(x: rect.midX - sz.width / 2,
                             y: rect.midY - sz.height / 2)
        } else {
            // Left-align with a small inset so the text doesn't kiss the
            // raised bevel on the menu-button side.
            origin = CGPoint(x: rect.minX + bv,
                             y: rect.midY - sz.height / 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        text.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Corner grooves

    private func drawCornerGrooves(_ ctx: CGContext, W: CGFloat, H: CGFloat) {
        let btnLeftX     = band + bi
        let btnTopY      = band + bi
        let btnRightX    = W - band - bi - bs
        let btnBotY      = H - band - bi - bs
        let btnRightEdge = btnLeftX + bs - bv
        let btnBotEdge   = btnTopY  + bs - bv

        horizontalGroove(ctx, x: 0,              y: btnBotEdge,   length: band)
        verticalGroove(ctx,   x: btnRightEdge,   y: 0,            length: band)
        horizontalGroove(ctx, x: W - band,       y: btnBotEdge,   length: band)
        verticalGroove(ctx,   x: btnRightX - bv, y: 0,            length: band)
        horizontalGroove(ctx, x: 0,              y: btnBotY - bv, length: band)
        verticalGroove(ctx,   x: btnRightEdge,   y: H - band,     length: band)
        horizontalGroove(ctx, x: W - band,       y: btnBotY - bv, length: band)
        verticalGroove(ctx,   x: btnRightX - bv, y: H - band,     length: band)
    }

    // MARK: - Bevel primitives

    private func raisedTile(_ ctx: CGContext, _ r: CGRect, pressed: Bool = false) {
        fill(ctx, r, MotifTheme.current.fill)
        bevel(ctx, r,
              topLeft:     pressed ? MotifTheme.current.shadow    : MotifTheme.current.highlight,
              bottomRight: pressed ? MotifTheme.current.highlight : MotifTheme.current.shadow)
    }

    private func raisedTileCentered(_ ctx: CGContext, in outer: CGRect,
                                    width: CGFloat, height: CGFloat) {
        // floor() the offsets so the icon always lands on integer-pixel
        // boundaries. Without this, parity mismatches between the button
        // size and `round(titleBarHeight * 0.64)` etc. produce half-
        // pixel offsets that AppKit rasterises blurry. Example: at
        // titleBarHeight=24, menuDashW=round(15.36)=15 and (24-15)/2
        // gives 4.5. The asymmetry bias (toward top-left) is invisible
        // at the rendering resolutions we use; the half-pixel shimmer
        // is very visible.
        let r = CGRect(
            x: floor(outer.minX + (outer.width  - width)  / 2),
            y: floor(outer.minY + (outer.height - height) / 2),
            width: width, height: height
        )
        raisedTile(ctx, r)
    }

    private func bevel(_ ctx: CGContext, _ r: CGRect,
                       topLeft: NSColor, bottomRight: NSColor) {
        for i in 0..<Int(bv) {
            let o = CGFloat(i)
            fill(ctx, CGRect(x: r.minX + o, y: r.minY + o,
                             width: r.width - 2*o, height: 1), topLeft)
            fill(ctx, CGRect(x: r.minX + o, y: r.minY + o,
                             width: 1, height: r.height - 2*o), topLeft)
            fill(ctx, CGRect(x: r.minX + o, y: r.maxY - 1 - o,
                             width: r.width - 2*o, height: 1), bottomRight)
            fill(ctx, CGRect(x: r.maxX - 1 - o, y: r.minY + o,
                             width: 1, height: r.height - 2*o), bottomRight)
        }
    }

    private func horizontalGroove(_ ctx: CGContext,
                                  x: CGFloat, y: CGFloat, length: CGFloat) {
        for i in 0..<Int(bv) {
            let o = CGFloat(i)
            fill(ctx, CGRect(x: x, y: y + o,      width: length, height: 1), MotifTheme.current.shadow)
            fill(ctx, CGRect(x: x, y: y + bv + o, width: length, height: 1), MotifTheme.current.highlight)
        }
    }

    private func verticalGroove(_ ctx: CGContext,
                                x: CGFloat, y: CGFloat, length: CGFloat) {
        for i in 0..<Int(bv) {
            let o = CGFloat(i)
            fill(ctx, CGRect(x: x + o,      y: y, width: 1, height: length), MotifTheme.current.shadow)
            fill(ctx, CGRect(x: x + bv + o, y: y, width: 1, height: length), MotifTheme.current.highlight)
        }
    }

    private func fill(_ ctx: CGContext, _ r: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(r)
    }

    // MARK: - Mouse handling

    private var dragOrigin: NSPoint?
    private var dragWindowOrigin: NSPoint?
    private var pressedButton: Int? = nil
    private var resizeEdge: ResizeEdge = .none
    private var resizeInitialFrame: NSRect = .zero

    private enum ResizeEdge {
        case none, top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        window?.makeKeyAndOrderFront(nil)

        if menuButtonRect().contains(pt)     { pressedButton = 0; needsDisplay = true; return }
        if restoreButtonRect().contains(pt)  { pressedButton = 1; needsDisplay = true; return }
        if maximizeButtonRect().contains(pt) { pressedButton = 2; needsDisplay = true; return }

        // Native drag/resize is locked while an X pointer grab is active.
        // The bridge sets isDragLocked so we don't seed dragOrigin /
        // resizeEdge — mouseDragged then no-ops. Without this, the user
        // could move the window while a Motif menu was up, corrupting
        // Motif's per-pulldown coord cache (see lockNativeWindowDrag doc).
        //
        // Before short-circuiting, fire the outside-grab click handler so
        // the bridge synthesizes a ButtonPress at this chrome location on
        // the underlying X client. The click lands outside the popup
        // geometry, Motif's outside-popup detector fires, the menu
        // dismisses, and the client issues XUngrabPointer (which then
        // releases our lock). Mirrors what a real X11 server would do
        // automatically: a pointer grab redirects every chrome click to
        // the grab window with outside-popup coords.
        if isDragLocked {
            if let handler = outsideGrabClickHandler {
                let pointsInClient = clientView.convert(event.locationInWindow, from: nil)
                let backingScale = window?.backingScaleFactor ?? 2.0
                let scale = (clientView as? FlippedXView)?.scaleFactor ?? 1.0
                let lx = Int16(clamping: Int((pointsInClient.x * backingScale / CGFloat(scale)).rounded()))
                let ly = Int16(clamping: Int((pointsInClient.y * backingScale / CGFloat(scale)).rounded()))
                handler(lx, ly, 1, event.modifierFlags.rawValue)
            }
            // The handler force-released the lock and stopped the cross-
            // window drag tracker. Seed dragOrigin so the user's continued
            // mouseDragged in this same gesture moves the window —
            // matching Mac click-and-drag UX (one gesture: menu dismisses
            // AND window moves) rather than real-X11's two-click pattern.
            // Only seed for the title-drag area; if the click is on a
            // resize edge, fall through to the resize path below so the
            // gesture continues as a resize instead of a move.
            if hitTestEdge(at: pt) == .none && titleDragRect.contains(pt) {
                dragOrigin = NSEvent.mouseLocation
                dragWindowOrigin = window?.frame.origin
            }
            return
        }

        let edge = hitTestEdge(at: pt)
        if edge != .none {
            resizeEdge = edge
            resizeInitialFrame = window?.frame ?? .zero
            dragOrigin = NSEvent.mouseLocation
            return
        }

        if titleDragRect.contains(pt) {
            if event.clickCount == 2 {
                window?.zoom(nil)
                return
            }
            dragOrigin = NSEvent.mouseLocation
            dragWindowOrigin = window?.frame.origin
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if resizeEdge != .none, let o = dragOrigin {
            applyResize(dx: now.x - o.x, dy: now.y - o.y); return
        }
        if let o = dragOrigin, let wo = dragWindowOrigin {
            window?.setFrameOrigin(NSPoint(x: wo.x + now.x - o.x, y: wo.y + now.y - o.y))
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let handler = pointerMovedHandler else { return }
        // Report the cursor in clientView-local X-logical pixels. Outside
        // the client rect (which is always the case here since the chrome
        // is around it) at least one coord is negative or beyond width/
        // height — that's intentional. The session translates these to
        // root coords via the top-level's WM-emulation origin and pushes
        // to the bridge's global pointer cache.
        let pointsInClient = clientView.convert(event.locationInWindow, from: nil)
        let backingScale = window?.backingScaleFactor ?? 2.0
        let scale = (clientView as? FlippedXView)?.scaleFactor ?? 1.0
        let lx = Int16(clamping: Int((pointsInClient.x * backingScale / CGFloat(scale)).rounded()))
        let ly = Int16(clamping: Int((pointsInClient.y * backingScale / CGFloat(scale)).rounded()))
        handler(lx, ly, event.modifierFlags.rawValue)
    }

    /// Install an always-active tracking area covering the whole frame
    /// (including chrome). Without it, AppKit only delivers mouseMoved
    /// while a button is held; root-pollers like xeyes need bare-hover
    /// updates so their last-known root_x/root_y stays fresh while the
    /// cursor is over the frame chrome.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    public override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let btn = pressedButton {
            switch btn {
            case 0:
                // performClose beeps on non-.titled windows. Invoke the
                // delegate's windowShouldClose hook manually (that's where
                // the WM_DELETE_WINDOW polite-close flow lives) and then
                // close the NSWindow directly.
                if menuButtonRect().contains(pt), let win = window {
                    let ok = win.delegate?.windowShouldClose?(win) ?? true
                    if ok { win.close() }
                }
            case 1: if restoreButtonRect().contains(pt)  { window?.miniaturize(nil) }
            case 2: if maximizeButtonRect().contains(pt) { window?.zoom(nil) }
            default: break
            }
            pressedButton = nil
            needsDisplay = true
        }
        dragOrigin = nil
        dragWindowOrigin = nil
        resizeEdge = .none
    }

    // MARK: - Edge-resize

    private func hitTestEdge(at pt: NSPoint) -> ResizeEdge {
        let b = band
        let cs = band + bi + bs   // corner span — same length as a title button
        let w = bounds.width, h = bounds.height
        let nearT = pt.y < b, nearB = pt.y > h - b
        let nearL = pt.x < b, nearR = pt.x > w - b
        if (nearT && pt.x < cs)    || (nearL && pt.y < cs)    { return .topLeft }
        if (nearT && pt.x > w - cs) || (nearR && pt.y < cs)    { return .topRight }
        if (nearB && pt.x < cs)    || (nearL && pt.y > h - cs) { return .bottomLeft }
        if (nearB && pt.x > w - cs) || (nearR && pt.y > h - cs) { return .bottomRight }
        if nearT { return .top }
        if nearB { return .bottom }
        if nearL { return .left }
        if nearR { return .right }
        return .none
    }

    private func applyResize(dx: CGFloat, dy: CGFloat) {
        // NSEvent.mouseLocation is screen coords (bottom-up). NSWindow.frame
        // is also screen coords (bottom-up origin). So a positive dy = pointer
        // moved up, which for the top edge grows height and for the bottom
        // edge shrinks height (anchoring the top by sliding the origin up).
        guard let window = window else { return }
        var f = resizeInitialFrame
        let minW: CGFloat = MotifTheme.current.horizontalPadding + 60
        let minH: CGFloat = MotifTheme.current.verticalPadding + 40
        func cL(_ d: CGFloat) {
            let nw = max(minW, f.width - d); f.origin.x += f.width - nw; f.size.width = nw
        }
        func cR(_ d: CGFloat) { f.size.width = max(minW, f.width + d) }
        func cT(_ d: CGFloat) { f.size.height = max(minH, f.height + d) }
        func cB(_ d: CGFloat) {
            let nh = max(minH, f.height - d); f.origin.y += f.height - nh; f.size.height = nh
        }
        switch resizeEdge {
        case .left:        cL(dx)
        case .right:       cR(dx)
        case .top:         cT(dy)
        case .bottom:      cB(dy)
        case .topLeft:     cL(dx); cT(dy)
        case .topRight:    cR(dx); cT(dy)
        case .bottomLeft:  cL(dx); cB(dy)
        case .bottomRight: cR(dx); cB(dy)
        case .none:        return
        }
        window.setFrame(f, display: true)
    }

    // MARK: - Key/active state

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyChanged), name: name, object: nil)
        }
    }
    @objc private func keyChanged(_ n: Notification) {
        if (n.object as? NSWindow) === window { needsDisplay = true }
    }
}
