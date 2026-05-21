import AppKit
import CoreGraphics

// NSView subclass that:
//   * uses X11's top-left origin convention (isFlipped = true) so X coords
//     pass through unchanged
//   * holds a CGBitmapContext sized at logical*scale device pixels (the
//     "device" coordinate space per RENDERING_DESIGN.md commitment 11)
//   * has a pre-applied CGAffineTransform on the backing context so
//     drawing requests issued in X-logical coordinates land at the right
//     device-pixel positions, and the y-axis is top-down
//   * blits the dirty rect to the screen in draw(_:)
//
// One NSView per top-level X window; drawing for any X subwindow in that
// subtree clips against the subwindow's geometry and writes into this
// single backing context.

public final class FlippedXView: NSView {

    /// X window id this view backs. Used by the keyboard event path so the
    /// session can resolve which X window in the subtree should receive
    /// key events. Set by the bridge at NSWindow creation.
    public var topLevelXWindowId: UInt32 = 0

    /// Keyboard event sink. The bridge installs this; FlippedXView calls it
    /// from keyDown / keyUp. Args: (NSEvent, isDown).
    public var keyHandler: ((NSEvent, Bool) -> Void)?

    /// Mouse event sink. The bridge installs this; FlippedXView calls it
    /// from mouseDown / mouseUp / rightMouseDown / rightMouseUp /
    /// otherMouseDown / otherMouseUp. Args: (X-logical x in top-level
    /// coords, X-logical y, X button number 1..3, isDown). The view
    /// converts NSEvent coords from view-local points → device px →
    /// logical px before calling.
    public var mouseHandler: ((Int16, Int16, UInt8, Bool) -> Void)?

    /// Drag event sink. Fires from mouseDragged / rightMouseDragged /
    /// otherMouseDragged. Same coord convention as mouseHandler. The held
    /// button number is forwarded so the session can populate the state
    /// field of the X MotionNotify event correctly.
    public var mouseDraggedHandler: ((Int16, Int16, UInt8) -> Void)?

    /// Pointer-moved event sink (no button held). Fires from `mouseMoved`
    /// when the tracking area is active. Args: (X-logical x, y in
    /// top-level coords). The session uses this to track which X subwindow
    /// currently contains the pointer and emit EnterNotify / LeaveNotify.
    public var mouseMovedHandler: ((Int16, Int16) -> Void)?

    /// Pointer entered the NSView's content area (from outside the window).
    /// Args: (X-logical x, y). The session emits the EnterNotify chain.
    public var mouseEnteredHandler: ((Int16, Int16) -> Void)?

    /// Pointer left the NSView's content area. Args: (X-logical x, y at exit
    /// time — may be outside the view's bounds). The session emits the
    /// LeaveNotify chain for whichever X window the pointer was last in,
    /// stamping these coords as the cursor's position at the crossing.
    public var mouseExitedHandler: ((Int16, Int16) -> Void)?

    /// Cursor to display while the pointer is over this view. Bridge sets
    /// this from `setCursor(topLevel:glyph:)` in response to crossing
    /// events. AppKit picks it up via `resetCursorRects`.
    public var currentCursor: NSCursor = .arrow {
        didSet {
            // Cheapest way to make AppKit reread the cursor rects.
            window?.invalidateCursorRects(for: self)
        }
    }

    public override func resetCursorRects() {
        // One rect spanning the whole view; cursor changes drive via
        // `currentCursor` setter triggering invalidateCursorRects.
        // Per-X-subwindow cursor rects would be more efficient (cursor
        // would update without crossing-event traffic) but for the
        // current pointer-driven model this is enough.
        addCursorRect(bounds, cursor: currentCursor)
    }

    /// Paste sink. The bridge installs this; FlippedXView calls it when the
    /// user invokes paste (Cmd-V) with the NSPasteboard's string content.
    /// The session synthesises a KeyPress/KeyRelease pair per character so
    /// the running X client receives the paste as if it were typed.
    public var pasteHandler: ((String) -> Void)?

    /// Copy sink. The bridge installs this; FlippedXView calls it when the
    /// user invokes copy (Cmd-C or Edit > Copy). The session looks up the
    /// current X selection owner, runs the ConvertSelection roundtrip, and
    /// pushes the result to NSPasteboard.
    public var copyHandler: (() -> Void)?

    /// CGBitmapContext sized at `logicalWidth * scale × logicalHeight * scale`.
    /// The CGContext has a pre-applied transform so callers can issue draw
    /// commands in logical coordinates — the transform handles the scale-up
    /// and the y-flip.
    public var backing: CGContext?

    /// Top-level X window's CWBackPixel resolved to RGB. Used to colour the
    /// view's layer so live-resize fills new region in the right color
    /// (instead of flashing the default NSView/NSWindow white) before the
    /// bitmap gets resized + repainted on windowDidEndLiveResize.
    public var liveResizeBackground: CGColor = .white {
        didSet {
            if wantsLayer { layer?.backgroundColor = liveResizeBackground }
        }
    }

    /// Logical X-protocol dimensions (what the client sees).
    public private(set) var logicalWidth: Int = 0
    public private(set) var logicalHeight: Int = 0

    /// Device-pixel dimensions of the backing bitmap. = logical × scale.
    public private(set) var backingWidth: Int = 0
    public private(set) var backingHeight: Int = 0

    /// Scale factor: 1 logical pixel = `scaleFactor` device pixels.
    /// Integer values (1, 2, 3) are the Phase-1 happy path with clean
    /// N×N device-pixel blocks. Fractional (e.g. 2.5) supported with AA
    /// at cell boundaries — see SERVER_RESOLUTION_SCALING_AND_FONTS.md.
    public private(set) var scaleFactor: Double = 1

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed: AppKit fills the new region with layer.backgroundColor
        // during a live drag, instead of flashing the default white before
        // our draw cycle catches up to the new bounds.
        wantsLayer = true
        layer?.backgroundColor = liveResizeBackground
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// We accept keyboard focus so the NSWindow can route keyDown / keyUp
    /// events to us. The bridge calls makeFirstResponder(view) right after
    /// makeKeyAndOrderFront in mapTopLevel.
    public override var acceptsFirstResponder: Bool { true }

    /// Accept the click that ALSO activates the window, so users can press
    /// a button in a non-key xcalc window without needing two clicks.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Intercept Cmd-V → paste path and Cmd-C → copy path. We don't pass
        // them through to keyHandler (which would otherwise translate them
        // into Mod4+v / Mod4+c X KeyPresses and confuse the running client).
        // For real copy/paste the user expects clipboard text moved between
        // the X selection and NSPasteboard, not raw key events.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": handlePaste(); return
            case "c": handleCopy(); return
            default: break
            }
        }
        keyHandler?(event, true)
    }

    public override func keyUp(with event: NSEvent) {
        // Mirror the keyDown filter: don't deliver the key-up half of an
        // intercepted Cmd-V / Cmd-C either, otherwise the X client sees a
        // stray KeyRelease with no matching KeyPress.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v", "c": return
            default: break
            }
        }
        keyHandler?(event, false)
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        pasteHandler?(text)
    }

    private func handleCopy() {
        copyHandler?()
    }

    // Standard `paste:` / `copy:` actions (Edit menu, services, scripted
    // invocations). Route to the same handlers as Cmd-V / Cmd-C keyDown.
    @objc public func paste(_ sender: Any?) { handlePaste() }
    @objc public func copy(_ sender: Any?)  { handleCopy() }

    public override func mouseDown(with event: NSEvent)        { dispatchMouse(event, button: 1, isDown: true) }
    public override func mouseUp(with event: NSEvent)          { dispatchMouse(event, button: 1, isDown: false) }
    public override func rightMouseDown(with event: NSEvent)   { dispatchMouse(event, button: 3, isDown: true) }
    public override func rightMouseUp(with event: NSEvent)     { dispatchMouse(event, button: 3, isDown: false) }
    public override func otherMouseDown(with event: NSEvent)   { dispatchMouse(event, button: 2, isDown: true) }
    public override func otherMouseUp(with event: NSEvent)     { dispatchMouse(event, button: 2, isDown: false) }

    public override func mouseDragged(with event: NSEvent)      { dispatchDrag(event, button: 1) }
    public override func rightMouseDragged(with event: NSEvent) { dispatchDrag(event, button: 3) }
    public override func otherMouseDragged(with event: NSEvent) { dispatchDrag(event, button: 2) }

    public override func mouseMoved(with event: NSEvent) {
        guard let handler = mouseMovedHandler else { return }
        let (x, y) = logicalLocation(of: event)
        handler(x, y)
    }

    public override func mouseEntered(with event: NSEvent) {
        guard let handler = mouseEnteredHandler else { return }
        let (x, y) = logicalLocation(of: event)
        handler(x, y)
    }

    public override func mouseExited(with event: NSEvent) {
        guard let handler = mouseExitedHandler else { return }
        let (x, y) = logicalLocation(of: event)
        handler(x, y)
    }

    /// AppKit calls this whenever the view's frame changes (initial layout,
    /// live resize, etc.) and asks us to install / replace tracking areas.
    /// We want one tracking area covering the whole view that delivers
    /// mouseMoved + mouseEntered + mouseExited even when the NSWindow
    /// isn't key — `.activeAlways` is the right option for an X server
    /// (the X client wants Crossing events regardless of macOS focus).
    /// `.inVisibleRect` lets AppKit auto-update bounds on resize.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func dispatchMouse(_ event: NSEvent, button: UInt8, isDown: Bool) {
        guard let handler = mouseHandler else { return }
        let (x, y) = logicalLocation(of: event)
        handler(x, y, button, isDown)
    }

    private func dispatchDrag(_ event: NSEvent, button: UInt8) {
        guard let handler = mouseDraggedHandler else { return }
        let (x, y) = logicalLocation(of: event)
        handler(x, y, button)
    }

    /// Convert an NSEvent's locationInWindow (window-points, bottom-left
    /// origin) to top-level X-logical coordinates (top-left origin). The
    /// view is `isFlipped`, so view-local points already use top-left;
    /// we just need points → device px (× backingScale) → logical px
    /// (÷ scaleFactor).
    ///
    /// `.rounded()` (round-half-to-even) is used instead of truncation
    /// so subpixel cursor movement crosses each logical-pixel boundary
    /// at the midpoint between integer values, matching how a real X
    /// server reports coords. Before 2026-05-21 this used `Int(Double)`,
    /// which truncates toward zero — at boundaries (e.g. the cursor
    /// brushing the upper edge of Motif's safe-triangle in a cascade
    /// menu) the truncation produced stair-step transitions that
    /// Motif's algorithm reads as the cursor jumping across the safe
    /// zone, dismissing the submenu unreliably.
    private func logicalLocation(of event: NSEvent) -> (Int16, Int16) {
        let pointsLocal = convert(event.locationInWindow, from: nil)
        let backingScale = window?.backingScaleFactor ?? 2.0
        let logicalX = Int16(clamping: Int((pointsLocal.x * backingScale / CGFloat(scaleFactor)).rounded()))
        let logicalY = Int16(clamping: Int((pointsLocal.y * backingScale / CGFloat(scaleFactor)).rounded()))
        return (logicalX, logicalY)
    }

    /// Allocate (or re-allocate) the backing CGBitmapContext at
    /// `logicalWidth * scale × logicalHeight * scale` device pixels and
    /// install the logical-to-device transform. Old backing contents are
    /// discarded — caller is responsible for issuing Expose so the client
    /// repaints.
    public func resizeBacking(logicalWidth: Int, logicalHeight: Int, scale: Double) {
        guard logicalWidth > 0, logicalHeight > 0, scale > 0 else { return }
        let deviceWidth = Int((Double(logicalWidth) * scale).rounded())
        let deviceHeight = Int((Double(logicalHeight) * scale).rounded())

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = deviceWidth * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: deviceWidth, height: deviceHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return }

        // Default fill: white. A proper implementation reads BackPixel from
        // the X window's CWBackPixel attribute. M3 polish.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: deviceWidth, height: deviceHeight))

        // [Y-FLIP #1 of 3] Backing CTM y-flip + logical→device scale.
        //
        // Three operations applied to the backing CGContext:
        //   1. translate origin to (0, deviceHeight)
        //   2. scale(1, -1) — flip y so X-style y-down works
        //   3. scale(scaleFactor, scaleFactor) — logical→device pixels
        //
        // Order matters: CG transforms compose so the LAST call applies
        // FIRST to user-space coordinates. So drawing at user (x, y) gets
        // scaled first, then y-flipped, then translated up. Net effect:
        // user (x, y) → device (x*scale, h - y*scale).
        //
        // Why y-flipped: X11 uses top-left origin (y-down); CG default is
        // bottom-left (y-up). With this flip, dispatch handlers pass X
        // coords directly into draw calls without per-call arithmetic.
        //
        // This flip is one of three (see the other two in
        // FlippedXView.draw and CocoaWindowBridge.drawImageText8). All
        // three are necessary; none is redundant. See the comment in
        // FlippedXView.draw for how they compose.
        ctx.translateBy(x: 0, y: CGFloat(deviceHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        self.backing = ctx
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingWidth = deviceWidth
        self.backingHeight = deviceHeight
        self.scaleFactor = scale
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = backing, let cg = NSGraphicsContext.current?.cgContext else { return }
        guard let img = ctx.makeImage() else { return }

        // Image rect: the native points-size that corresponds to the
        // bitmap's logical dimensions. During a live resize the view's
        // bounds grow but the bitmap (and hence imgRect) stays put — drawing
        // into bounds would stretch the image, so we pin it to top-left at
        // its native size and let the layer's backgroundColor fill the rest.
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let imgPointsW = CGFloat(logicalWidth) * CGFloat(scaleFactor) / backingScale
        let imgPointsH = CGFloat(logicalHeight) * CGFloat(scaleFactor) / backingScale
        let imgRect = NSRect(x: 0, y: 0, width: imgPointsW, height: imgPointsH)

        // [Y-FLIP #2 of 3] Blit y-flip in the NSView's draw context.
        //
        // Why this y-flip is necessary, and not redundant with the backing
        // CTM's y-flip (#1) or the glyph local-flip (#3):
        //
        // Our backing CGBitmapContext has a y-flipped CTM (`translate(0, h)`
        // + `scaleBy(1, -1)`) so dispatch handlers can use X-style top-left
        // origin coords. That CTM affects DRAWING into the bitmap; it does
        // NOT change how pixels are stored in memory or how the bitmap is
        // interpreted as a CGImage.
        //
        // CGBitmapContext's user-space origin is at the lower-left (CG
        // natural y-up). So drawing at user-coord (0, 0) with our CTM
        // applied lands at CG-natural (0, h) — the upper edge of the bitmap
        // — which the rasterizer writes into "bottom of memory" because
        // that's what represents the image's TOP visually in CG's y-up
        // model. (Apple's CGBitmapContext stores bottom-of-image first in
        // memory by convention, even though `CGImage` interprets row 0 as
        // top of image.)
        //
        // Net effect: the CGImage from `makeImage()` represents the bitmap
        // with its rows in CG-natural order (row 0 = bottom of image). When
        // drawn into a flipped NSView's CGContext via `cg.draw(img, in:)`,
        // CG renders the image WITHOUT auto-flipping for the view's
        // flippedness — image row 0 ends up at the top of `bounds` in CG
        // user space, which is the BOTTOM of the view visually (since the
        // NSView is flipped). Result: image appears upside-down, drawn at
        // the bottom of the visible area.
        //
        // The explicit `translateBy + scaleBy(1, -1)` here counter-flips
        // before `cg.draw`, so the CGImage's natural-bottom maps to the
        // top of `bounds` in the flipped NSView's coords, which is the top
        // of the view visually. Now the image renders right-side-up at the
        // top.
        //
        // This is the ONLY transform applied at blit time. The other two
        // y-flips (backing CTM, text local-flip in drawImageText8) serve
        // separate purposes — none cancels another.
        cg.saveGState()
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        // Drawing at imgRect (origin 0,0 in transformed coords, native size)
        // lands at the TOP of the view in flipped screen coords. Anything
        // outside imgRect in the view's bounds shows the layer's bg color.
        cg.draw(img, in: imgRect)
        cg.restoreGState()
    }
}
