import Foundation
import AppKit
import CoreText
import Framer

// Cocoa-side WindowBridge. Owns an NSWindow per top-level X window. AppKit
// calls always dispatch to the main thread; protocol events queue back to
// the OutboundQueue from the same main-thread block once the NSWindow is on
// screen.
//
// Per DECISIONS.md 2026-05-05 and RENDERING_DESIGN.md: rootless mode is
// primary — each top-level X window becomes a real NSWindow with native
// macOS chrome. The X subtree below the top-level is internal; drawing
// targets the single FlippedXView per top-level.

public final class CocoaWindowBridge: WindowBridge, @unchecked Sendable {

    private struct Slot: @unchecked Sendable {
        var geometry: TopLevelGeometry
        var eventMask: UInt32
        var pendingTitle: String?
        var window: NSWindow?
        var view: FlippedXView?
        var delegate: XWindowDelegate?
    }

    private var slots: [UInt32: Slot] = [:]
    private let lock = NSLock()

    /// Cross-NSWindow drag tracking state. See startCrossWindowDragTracking
    /// for the rationale; all access on main thread.
    var dragMonitor: Any?
    var dragGrabDepth: Int = 0
    var dragLastWindowId: UInt32?
    // Multi-client: every connected session registers its own handlers via
    // setOnX. We store them as lists, not single closures, so a newly
    // accepted xcalc session doesn't replace the already-running xterm
    // session's handlers. Events fire all registered handlers; each
    // session's handler filters by `windows.get(topLevel) != nil` and
    // no-ops for windows it doesn't own. Mutations of the lists happen on
    // the listener accept thread; reads happen on the main thread —
    // `handlerLock` covers both.
    private let handlerLock = NSLock()
    private var resizeHandlers: [@Sendable (UInt32, UInt16, UInt16) -> Void] = []
    private var keyHandlers: [@Sendable (UInt32, UInt8, UInt, Bool) -> Void] = []
    private var focusHandlers: [@Sendable (UInt32, Bool) -> Void] = []
    private var mouseHandlers: [@Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void] = []
    private var mouseDraggedHandlers: [@Sendable (UInt32, Int16, Int16, UInt8) -> Void] = []
    private var pointerMovedHandlers: [@Sendable (UInt32, Int16, Int16) -> Void] = []
    private var pointerEnteredViewHandlers: [@Sendable (UInt32, Int16, Int16) -> Void] = []
    private var pointerExitedViewHandlers: [@Sendable (UInt32) -> Void] = []
    private var pasteHandlers: [@Sendable (UInt32, String) -> Void] = []
    private var copyHandlers: [@Sendable (UInt32) -> Void] = []
    private var closeHandlers: [@Sendable (UInt32) -> Void] = []
    private weak var log: ServerLogSink?

    /// Scale factor: 1 X-logical pixel = `scaleFactor` device pixels.
    /// Pulled from `DisplayConfig.scale` at startup. Integer values are
    /// the Phase-1 happy path; fractional values (e.g. 2.5) are supported
    /// with AA edges at cell boundaries.
    public let scaleFactor: Double

    public init(scaleFactor: Double = 1, log: ServerLogSink? = nil) {
        self.scaleFactor = scaleFactor
        self.log = log
    }

    public func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
        handlerLock.lock(); resizeHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnKey(_ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void) {
        handlerLock.lock(); keyHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnFocus(_ handler: @escaping @Sendable (UInt32, Bool) -> Void) {
        handlerLock.lock(); focusHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnMouse(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void) {
        handlerLock.lock(); mouseHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnMouseDragged(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8) -> Void) {
        handlerLock.lock(); mouseDraggedHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnPointerMoved(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {
        handlerLock.lock(); pointerMovedHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnPointerEnteredView(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {
        handlerLock.lock(); pointerEnteredViewHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnPointerExitedView(_ handler: @escaping @Sendable (UInt32) -> Void) {
        handlerLock.lock(); pointerExitedViewHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void) {
        handlerLock.lock(); pasteHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnCopy(_ handler: @escaping @Sendable (UInt32) -> Void) {
        handlerLock.lock(); copyHandlers.append(handler); handlerLock.unlock()
    }

    public func setOnCloseRequest(_ handler: @escaping @Sendable (UInt32) -> Void) {
        handlerLock.lock(); closeHandlers.append(handler); handlerLock.unlock()
    }

    // MARK: - Handler fan-out

    /// Snapshot the named handler list under the lock and fire each in turn.
    /// Snapshotting (rather than holding the lock through the fan-out) so
    /// a handler can safely append/register new handlers without deadlocking.
    private func fireResize(id: UInt32, w: UInt16, h: UInt16) {
        handlerLock.lock(); let snap = resizeHandlers; handlerLock.unlock()
        for handler in snap { handler(id, w, h) }
    }
    private func fireKey(id: UInt32, code: UInt8, mods: UInt, isDown: Bool) {
        handlerLock.lock(); let snap = keyHandlers; handlerLock.unlock()
        for h in snap { h(id, code, mods, isDown) }
    }
    private func fireFocus(id: UInt32, gained: Bool) {
        handlerLock.lock(); let snap = focusHandlers; handlerLock.unlock()
        for h in snap { h(id, gained) }
    }
    private func fireMouse(id: UInt32, x: Int16, y: Int16, button: UInt8, isDown: Bool) {
        handlerLock.lock(); let snap = mouseHandlers; handlerLock.unlock()
        for h in snap { h(id, x, y, button, isDown) }
    }
    private func fireMouseDragged(id: UInt32, x: Int16, y: Int16, button: UInt8) {
        handlerLock.lock(); let snap = mouseDraggedHandlers; handlerLock.unlock()
        for h in snap { h(id, x, y, button) }
    }
    private func firePointerMoved(id: UInt32, x: Int16, y: Int16) {
        handlerLock.lock(); let snap = pointerMovedHandlers; handlerLock.unlock()
        for h in snap { h(id, x, y) }
    }
    private func firePointerEnteredView(id: UInt32, x: Int16, y: Int16) {
        handlerLock.lock(); let snap = pointerEnteredViewHandlers; handlerLock.unlock()
        for h in snap { h(id, x, y) }
    }
    private func firePointerExitedView(id: UInt32) {
        handlerLock.lock(); let snap = pointerExitedViewHandlers; handlerLock.unlock()
        for h in snap { h(id) }
    }
    private func firePaste(id: UInt32, text: String) {
        handlerLock.lock(); let snap = pasteHandlers; handlerLock.unlock()
        for h in snap { h(id, text) }
    }
    private func fireCopy(id: UInt32) {
        handlerLock.lock(); let snap = copyHandlers; handlerLock.unlock()
        for h in snap { h(id) }
    }
    private func fireCloseRequest(id: UInt32) {
        handlerLock.lock(); let snap = closeHandlers; handlerLock.unlock()
        for h in snap { h(id) }
    }

    /// Called by the NSWindowDelegate when the user clicks the red close
    /// button or invokes Window > Close / ⌘W. Fans out to every registered
    /// session — non-owners see the unknown id and no-op.
    func handleNSWindowCloseRequest(id: UInt32) {
        fireCloseRequest(id: id)
    }

    public func writeClipboard(text: String) {
        // Pasteboard writes happen on main; we can be called from the read
        // thread when SelectionNotify lands. Keep it simple and dispatch.
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    /// Per-window pending focus state, last-emitted state, and pending task.
    /// Used by the debounce: when AppKit activates two windows in quick
    /// succession (window A becomes key → A resigns key → B becomes key,
    /// all within ~40ms — common at app startup with multiple top-levels),
    /// emitting all three FocusIn/Out events to the client destabilises
    /// Motif's translation engine. Gold (Sun→Sun) emits ONE FocusIn at
    /// startup; we mirror that by debouncing rapid changes per-window so
    /// only the SETTLED final state lands on the wire.
    /// All access is from the main thread (NSWindow delegate callbacks +
    /// our own scheduled tasks targeting `.main`).
    private nonisolated(unsafe) static var pendingFocusState: [UInt32: Bool] = [:]
    private nonisolated(unsafe) static var lastEmittedFocusState: [UInt32: Bool] = [:]
    private nonisolated(unsafe) static var pendingFocusTask: [UInt32: DispatchWorkItem] = [:]
    private static let focusDebounceMs = 80

    func handleNSWindowFocusChange(id: UInt32, gained: Bool) {
        // Cancel any pending emit for this window.
        Self.pendingFocusTask[id]?.cancel()
        Self.pendingFocusState[id] = gained
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let pending = Self.pendingFocusState[id] else { return }
            let last = Self.lastEmittedFocusState[id] ?? false
            Self.pendingFocusTask[id] = nil
            // Suppress if state didn't actually change since last emit
            // (e.g. gain → lose → gain settles back to gain — same as
            // last_emitted, no event needed).
            if pending != last {
                Self.lastEmittedFocusState[id] = pending
                self.fireFocus(id: id, gained: pending)
            }
        }
        Self.pendingFocusTask[id] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.focusDebounceMs),
            execute: item
        )
    }

    // MARK: - WindowBridge

    public func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        lock.lock()
        slots[id] = Slot(geometry: geometry, eventMask: eventMask, pendingTitle: nil, window: nil, view: nil)
        lock.unlock()
    }

    public func mapTopLevel(
        id: UInt32,
        geometry: TopLevelGeometry,
        eventMask: UInt32,
        descendants: [DescendantSnapshot],
        overrideRedirect: Bool,
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        lock.lock()
        if slots[id] != nil {
            slots[id]?.geometry = geometry            // sync to current
        }
        let pendingTitle = slots[id]?.pendingTitle ?? "swift-x"
        lock.unlock()

        // Emit ReparentNotify / ConfigureNotify / MapNotify / Expose
        // synchronously from the caller's thread (the read thread). Doing
        // this on the read thread keeps outbound order monotonic with the
        // sequence counter — if we hopped to main first, subsequent inline
        // replies on the read thread would race past these events and
        // Xlib would see "sequence lost" as the wire goes backwards.
        // (Motif's quickplot tripped this, reply type 0x15 = ReparentNotify.)
        // The actual NSWindow creation still happens on main below.
        MockWindowBridge.emitMapSequence(
            window: id, geometry: geometry,
            topLevelEventMask: eventMask,
            descendants: descendants,
            byteOrder: byteOrder, sequence: sequence,
            outbound: outbound
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.log?.log("  bridge: bringing up NSWindow for 0x\(String(id, radix: 16)) \(geometry.width)x\(geometry.height) (logical)")
            let scale = self.scaleFactor

            // NSWindow content rect is in points. Convert from logical:
            // points = logical * scale / backingScale (typically 2.0 on Retina).
            // The result: 1 X-logical pixel = `scale` device pixels regardless of
            // the macOS backing factor.
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let pointsW = CGFloat(geometry.width) * CGFloat(scale) / backingScale
            let pointsH = CGFloat(geometry.height) * CGFloat(scale) / backingScale

            let view = FlippedXView(frame: NSRect(x: 0, y: 0, width: pointsW, height: pointsH))
            view.topLevelXWindowId = id
            view.resizeBacking(logicalWidth: Int(geometry.width),
                               logicalHeight: Int(geometry.height),
                               scale: scale)
            view.autoresizingMask = [.width, .height]
            // Route NSEvent keyDown / keyUp into the session via the
            // bridge-level keyHandler closure (set by ServerSession at init).
            // The view captures a snapshot of the closure; on each keystroke
            // it invokes with (topLevelXWindowId, macOS keyCode, modifierFlags
            // raw value, isDown).
            // The view's installed closures fan out to every registered
            // session via fireX(...), which snapshots the bridge's handler
            // list at fire time. That way a session that registers AFTER
            // this top-level was mapped still receives events for it.
            view.keyHandler = { [weak self] event, isDown in
                self?.fireKey(
                    id: id, code: UInt8(event.keyCode & 0xFF),
                    mods: event.modifierFlags.rawValue, isDown: isDown
                )
            }
            view.mouseHandler = { [weak self] x, y, button, isDown in
                self?.fireMouse(id: id, x: x, y: y, button: button, isDown: isDown)
            }
            view.mouseDraggedHandler = { [weak self] x, y, button in
                self?.fireMouseDragged(id: id, x: x, y: y, button: button)
            }
            view.mouseMovedHandler = { [weak self] x, y in
                self?.firePointerMoved(id: id, x: x, y: y)
            }
            view.mouseEnteredHandler = { [weak self] x, y in
                self?.firePointerEnteredView(id: id, x: x, y: y)
            }
            view.mouseExitedHandler = { [weak self] in
                self?.firePointerExitedView(id: id)
            }
            view.pasteHandler = { [weak self] text in
                self?.firePaste(id: id, text: text)
            }
            view.copyHandler = { [weak self] in
                self?.fireCopy(id: id)
            }

            // Override-redirect popups (menus, tooltips, drag indicators)
            // need different NSWindow styling than regular top-levels:
            //   - borderless (no title bar / chrome)
            //   - non-activating panel (clicks don't steal key from main)
            //   - level=popUpMenu (floats above regular windows)
            // Use NSPanel for the non-activating + window-level behavior;
            // regular NSWindow for normal top-levels.
            let style: NSWindow.StyleMask = overrideRedirect
                ? [.borderless, .nonactivatingPanel]
                : [.titled, .closable, .miniaturizable, .resizable]
            // Position: regular top-levels go at (100, 100) by convention.
            // Override-redirect popups need to land where the X client
            // asked, in screen coords:
            //   - x: parent NSWindow's screen-x + geometry.x (X-root is
            //     parent-relative under our (0,0)-per-top-level convention)
            //   - y: parent's screen-y-top - geometry.y - pointsH
            //     (X is top-left origin, macOS is bottom-left, so flip)
            // The "parent" for popup positioning is whichever top-level the
            // user is currently interacting with — NSApp.keyWindow when
            // available; fall back to (100,100) for headless / pre-key cases.
            let contentRect: NSRect
            if overrideRedirect, let parent = NSApp.keyWindow {
                let parentFrame = parent.frame
                let originX = parentFrame.origin.x + CGFloat(geometry.x) * CGFloat(scale) / backingScale
                let parentTop = parentFrame.origin.y + parentFrame.size.height
                let originY = parentTop - CGFloat(geometry.y) * CGFloat(scale) / backingScale - pointsH
                contentRect = NSRect(x: originX, y: originY, width: pointsW, height: pointsH)
            } else {
                contentRect = NSRect(x: 100, y: 100, width: pointsW, height: pointsH)
            }
            let win: NSWindow
            if overrideRedirect {
                let panel = NSPanel(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
                panel.level = .popUpMenu
                panel.hidesOnDeactivate = false
                panel.becomesKeyOnlyIfNeeded = true
                win = panel
            } else {
                win = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
            }
            win.contentView = view
            if !overrideRedirect { win.title = pendingTitle }
            win.isReleasedWhenClosed = false
            // Tracking-area-driven mouseMoved is reliable on its own, but this
            // is the legacy switch the Cocoa docs still call out — set it true
            // so the path is the most-permissive even if Apple ever changes
            // the tracking-area defaults.
            win.acceptsMouseMovedEvents = true

            let delegate = XWindowDelegate(windowId: id, bridge: self)
            win.delegate = delegate

            self.lock.lock()
            self.slots[id]?.window = win
            self.slots[id]?.view = view
            self.slots[id]?.delegate = delegate
            self.lock.unlock()

            // Map-sequence events were already emitted synchronously above
            // on the read thread to keep wire order monotonic. Here we just
            // bring the NSWindow on screen. The natural ordering — MapNotify
            // before FocusIn — still holds because makeKeyAndOrderFront
            // triggers windowDidBecomeKey → focus handler → FocusIn AFTER
            // the map events have already landed in outbound.
            //
            // Override-redirect popups: orderFrontRegardless instead of
            // makeKeyAndOrderFront — they should NOT steal key focus from
            // whatever main window the user was interacting with. Skips
            // the windowDidBecomeKey → FocusIn synth, which is correct
            // because the X server doesn't emit FocusIn on popup mapping
            // either.
            if overrideRedirect {
                win.orderFrontRegardless()
            } else {
                win.makeKeyAndOrderFront(nil)
            }
            // Make the FlippedXView the first responder so keyDown / keyUp
            // route to it. Without this, NSWindow swallows key events.
            // Override-redirect popups don't take key focus, so skip the
            // app-activate step too.
            if !overrideRedirect {
                win.makeFirstResponder(view)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    public func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let event = MapNotifyEvent(
            sequenceNumber: sequence, event: id, window: id,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: byteOrder))
        // The session passes ExposureMask + size info via the descendant
        // entry it just stored; we ask the bridge owner to emit Expose
        // through the higher-level mapWindow path. mapDescendant by itself
        // doesn't know event masks. See ServerSession.mapWindow for the
        // Expose-emit (it now follows mapDescendant for non-top-level maps).
    }

    public func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        // Emit UnmapNotify SYNCHRONOUSLY on the caller's (protocol) thread
        // so the event lands in `outbound` with the correct sequence number
        // at the right point in wire order. Earlier we were doing this
        // inside the DispatchQueue.main.async block — by the time main ran,
        // the session had advanced sequenceNumber and the wire saw a
        // backwards seq dip. Xlib then reported "sequence lost in reply
        // type 0x12" (= UnmapNotify code 18). Verified 2026-05-10 against
        // xfontsel font-menu post/dismiss flow.
        let event = UnmapNotifyEvent(
            sequenceNumber: sequence, event: id, window: id, fromConfigure: false
        )
        outbound.append(event.encode(byteOrder: byteOrder))
        let win = slot(id)?.window
        DispatchQueue.main.async {
            win?.orderOut(nil)
        }
    }

    public func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        // Same pattern as unmapTopLevel: emit DestroyNotify synchronously
        // on the protocol thread for correct wire-order seq stamping.
        let event = DestroyNotifyEvent(
            sequenceNumber: sequence, event: id, window: id
        )
        outbound.append(event.encode(byteOrder: byteOrder))
        let win = slot(id)?.window
        lock.lock()
        slots.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async {
            win?.close()
        }
    }

    public func setTopLevelTitle(id: UInt32, title: String) {
        lock.lock()
        let win = slots[id]?.window
        if win == nil {
            slots[id]?.pendingTitle = title
        }
        lock.unlock()
        if let win = win {
            DispatchQueue.main.async { win.title = title }
        }
    }

    public func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {
        // M3 hook — mark the NSView's region for that descendant as needing
        // redraw. M2 doesn't do anything visible.
    }

    public func drawingTarget(for drawable: UInt32) -> Any? {
        slot(drawable)?.view
    }

    // MARK: - Drawing

    public func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            self.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            for s in segments {
                ctx.move(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                ctx.addLine(to: CGPoint(x: CGFloat(s.x2), y: CGFloat(s.y2)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            self.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// X11→CG pixel-address adapter for stroke paths, plus integer line
    /// width. X11 uses pixel-center addressing: a path at integer (x, y)
    /// means the center of pixel (x, y), and a thin-line stroke from (x, y)
    /// to (x+w-1, y) hits w pixels (both endpoints inclusive). CG uses
    /// grid-line addressing: integer y means the boundary between pixel
    /// rows y-1 and y, and a stroke centered there straddles two rows.
    ///
    /// To bridge: translate the CTM by +0.5 user-pixel so X11 integer
    /// coordinates land at CG pixel centers. After that, stroking a path
    /// from (x, y) to (x+w-1, y) at line-width 1 covers exactly the pixels
    /// X11 would have covered — w device-aligned pixels along the top row,
    /// regardless of integer scale factor.
    ///
    /// This subsumes the doc's "+0.5 device px for odd widths" recipe and
    /// fixes a subtle case the doc's version missed: at integer scales the
    /// device-pixel offset gives crisp strokes but lands them half a
    /// logical pixel off from where xterm expects (cell rows 3y-1..3y+1
    /// instead of 3y..3y+2 for the cursor outline). Result: half-pixel
    /// remnants outside the cell that ImageText8 fills couldn't cover —
    /// the visible "cursor fragments" Todd flagged. The +0.5 user-pixel
    /// shift puts every X11 pixel-address stroke entirely inside its
    /// nominal cell rect.
    ///
    /// AA stays on; the alignment is enough to get crisp strokes without
    /// giving up CG's diagonal-line smoothing (xclock's hands).
    private func applyStrokePlane(_ ctx: CGContext, clientLineWidth: UInt32) {
        let cw = max(Int(clientLineWidth), 1)
        ctx.translateBy(x: 0.5, y: 0.5)
        ctx.setLineWidth(CGFloat(cw))
    }

    public func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyFill(ctx, foreground)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.closePath()
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyFill(ctx, background)
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func copyArea(
        topLevel: UInt32,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view,
                  let ctx = view.backing,
                  let dataPtr = ctx.data else { return }

            // Logical X-coords (y-down) translate to memory pixel coords
            // (top-down) via `mem = round(logical * scale)`. Memory is
            // row-major with byte 0 = top-left pixel. At fractional scale
            // we lose at most 0.5 device pixel of source/dest position;
            // for terminal scrolling that's invisible.
            let scale = view.scaleFactor
            let bpr = ctx.bytesPerRow
            let bmpW = ctx.width
            let bmpH = ctx.height
            let bytesPerPixel = 4

            let srcMemX = Int((Double(srcX) * scale).rounded())
            let srcMemY = Int((Double(srcY) * scale).rounded())
            let dstMemX = Int((Double(dstX) * scale).rounded())
            let dstMemY = Int((Double(dstY) * scale).rounded())
            let copyW = Int((Double(width) * scale).rounded())
            let copyH = Int((Double(height) * scale).rounded())

            // Bounds-check both rects. CopyArea outside the bitmap is a
            // silent no-op rather than a crash.
            guard srcMemX >= 0, srcMemY >= 0, copyW > 0, copyH > 0,
                  srcMemX + copyW <= bmpW, srcMemY + copyH <= bmpH,
                  dstMemX >= 0, dstMemY >= 0,
                  dstMemX + copyW <= bmpW, dstMemY + copyH <= bmpH else { return }

            let bytes = dataPtr.assumingMemoryBound(to: UInt8.self)
            let copyByteWidth = copyW * bytesPerPixel

            // Direction matters with overlap: copy rows from the side
            // farthest from overlap inward. memmove handles within-row.
            if dstMemY < srcMemY {
                // Moving content UP in memory (typical xterm scroll-up).
                // Iterate top-down so we read src rows before they're
                // overwritten as dst rows.
                for i in 0..<copyH {
                    let srcOffset = (srcMemY + i) * bpr + srcMemX * bytesPerPixel
                    let dstOffset = (dstMemY + i) * bpr + dstMemX * bytesPerPixel
                    memmove(bytes.advanced(by: dstOffset),
                            bytes.advanced(by: srcOffset),
                            copyByteWidth)
                }
            } else {
                // Moving content DOWN (or same row). Iterate bottom-up.
                for i in (0..<copyH).reversed() {
                    let srcOffset = (srcMemY + i) * bpr + srcMemX * bytesPerPixel
                    let dstOffset = (dstMemY + i) * bpr + dstMemX * bytesPerPixel
                    memmove(bytes.advanced(by: dstOffset),
                            bytes.advanced(by: srcOffset),
                            copyByteWidth)
                }
            }

            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyRectangle(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, rectangles: [Framer.Rectangle]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            self.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            // CGContext.stroke(rect) draws a 1-line-width-wide outline of the
            // rect using the current stroke color + line width. PolyRectangle
            // batches multiple rects in one request; iterate and stroke each.
            for r in rectangles {
                ctx.stroke(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                  width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, function: UInt8, rectangles: [Framer.Rectangle]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            // X GC function = 6 (GXxor): XOR fill toggles destination pixels.
            // Athena's menu-item highlight relies on this — first XOR-fill
            // highlights, second XOR-fill on the same area un-highlights,
            // text preserved because XOR-then-XOR is identity. CG's
            // .difference blend mode is XOR-equivalent for binary colors
            // (|D - S|: black↔white inverts, intermediate values don't
            // perfectly reverse but Athena only uses solid colors here).
            // Function 3 (GXcopy) is the spec default — overwrite.
            if function == 6 {  // GXxor
                ctx.setBlendMode(.difference)
            }
            applyFill(ctx, foreground)
            for r in rectangles {
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// X11 arc geometry: bounding box (x, y, width, height) defines the
    /// ellipse; angle1 is the start angle in 64ths of a degree (0 = east);
    /// angle2 is the extent (positive = counterclockwise per X spec).
    /// Implementation: parametric ellipse sampling in device coords —
    /// build the arc as a polyline of N segments, where N scales with the
    /// arc extent so a 360° arc gets ~64 segments. Avoids CTM-vs-stroke-
    /// pen-width interaction (a scaled CGContext.addArc would also scale
    /// the pen, distorting line width on non-circular arcs).
    public func drawPolyArc(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, arcs: [Arc]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            self.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            for a in arcs {
                let path = ellipseArcPath(arc: a, includePieCenter: false)
                ctx.beginPath()
                ctx.addPath(path)
                ctx.strokePath()
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// PolyFillArc: fill the pie slice (default arc-mode=PieSlice; chord mode
    /// is unhandled — see OPCODE_STATUS). Path moves to the ellipse center,
    /// out to the arc start, sweeps the arc, closes back to center.
    public func drawPolyFillArc(topLevel: UInt32, foreground: RGB16, arcs: [Arc]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyFill(ctx, foreground)
            for a in arcs {
                let path = ellipseArcPath(arc: a, includePieCenter: true)
                ctx.beginPath()
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawImageText8(
        topLevel: UInt32,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8]
    ) {
        let printable = String(decoding: string.prefix(40), as: UTF8.self)
        log?.log("  drawImageText8 top=0x\(String(topLevel, radix: 16)) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) str=\"\(printable)\" len=\(string.count)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }

            // Per X11 ImageText8 spec: fill bg rect under the text first,
            // then draw glyphs. Rect spans (x, y-ascent) to
            // (x + n*cellWidth, y+descent) where (x, y) is the baseline of
            // the first glyph. We use the cell-snapped metrics so the bg
            // exactly covers what xterm expects.
            let cellW = font.cellWidth
            let n = string.count
            let bgRect = CGRect(
                x: CGFloat(x),
                y: CGFloat(Int(y) - font.ascent),
                width: CGFloat(cellW * n),
                height: CGFloat(font.cellHeight)
            )

            ctx.saveGState()
            applyFill(ctx, background)
            ctx.fill(bgRect)

            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            // Font smoothing OFF. macOS smoothing adds a half-step of stem
            // weight to compensate for sub-pixel LCD rendering — useful for
            // reading prose at 1× backing scale, but in our 3× X-server
            // bitmap it just makes Monaco look "bolder than it is" to the
            // user. Disabling gets us the geometric font without the
            // LCD-compensation fattening. AA stays on so diagonals stay
            // smooth. (See Todd's "feels bold" feedback 2026-05-08; we
            // explored Core Text weight traits but Monaco has no lighter
            // face for CT to substitute, so this is the lever that
            // actually moves the needle.)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            // [Y-FLIP #3 of 3] Glyph local y-flip.
            //
            // CTFontDrawGlyphs renders glyph art in CG's default orientation
            // — ascent extends in +y user space, descent in -y — same as
            // any text drawing. Our backing CTM (Y-FLIP #1) has user-space
            // y-axis flipped (so X coords pass through). Drawing glyphs
            // straight into that context puts ascent visually DOWN — text
            // appears upside-down.
            //
            // We translate to the glyph BASELINE first, then apply a local
            // scale(1, -1) inside saveGState/restoreGState. Inside that
            // scope, the local user-space has y running in CG's natural
            // direction relative to the baseline. Glyph art (which CG
            // draws +y from origin) now extends "up" relative to the
            // local origin, which is "up" visually because we're inside
            // the backing's flipped space.
            //
            // Glyph positions are relative to the local (post-translate,
            // post-flip) origin — `(i*cellW, 0)` per glyph for monospace.
            //
            // This y-flip is one of three (see Y-FLIP #1 in
            // FlippedXView.resizeBacking and Y-FLIP #2 in FlippedXView.draw).
            // Each addresses a separate concern.
            ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            ctx.scaleBy(x: 1, y: -1)

            let ctFont = ctFont(for: font)

            // Decode bytes as Latin-1 → UniChar (each byte is its codepoint).
            // Phase 4 adds proper iso8859-1 / iso10646-1 handling.
            var unichars = [UniChar](repeating: 0, count: n)
            for i in 0..<n { unichars[i] = UniChar(string[i]) }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

            var positions = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                positions[i] = CGPoint(x: CGFloat(i * cellW), y: 0)
            }

            CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)

            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyText8(
        topLevel: UInt32,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }

            ctx.saveGState()
            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            // Font smoothing OFF. macOS smoothing adds a half-step of stem
            // weight to compensate for sub-pixel LCD rendering — useful for
            // reading prose at 1× backing scale, but in our 3× X-server
            // bitmap it just makes Monaco look "bolder than it is" to the
            // user. Disabling gets us the geometric font without the
            // LCD-compensation fattening. AA stays on so diagonals stay
            // smooth. (See Todd's "feels bold" feedback 2026-05-08; we
            // explored Core Text weight traits but Monaco has no lighter
            // face for CT to substitute, so this is the lever that
            // actually moves the needle.)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            // Walk TEXTITEM8 items: 0xFF marks a 5-byte font shift we ignore
            // (we use the GC font for the whole request — Athena widget apps
            // like xcalc don't issue font shifts). Otherwise each item is
            // length(1) + delta(1 signed) + length glyph bytes. Pen advances
            // by delta + sum-of-glyph-advances after each run.
            //
            // Position glyphs by the CTFont's actual advances rather than
            // the resolved-font cellWidth: PolyText8 has no bg fill, so
            // there's no benefit to cell-snapping, and using true advances
            // closes the visible gaps that show up when our reported cell
            // width is wider than the substituted Mac font's glyph box.
            // (The Phase-1.5 metrics-tightening work in CHATGPT_REVIEW.md
            // covers the principled fix; this is the local minimum.)
            let baseX = Int(x)
            var penX: CGFloat = CGFloat(baseX)
            let baseY = Int(y)

            let ctFont = ctFont(for: font)

            var i = 0
            while i < items.count {
                let b = items[i]
                if b == 0xFF {
                    // Font shift sentinel: skip 5 bytes total (sentinel + 4
                    // bytes of font ID). xcalc never sends these.
                    i += 5
                    continue
                }
                let n = Int(b)
                if n == 0 { i += 1; continue }
                guard i + 2 + n <= items.count else { break }
                let delta = Int8(bitPattern: items[i + 1])
                penX += CGFloat(delta)

                var unichars = [UniChar](repeating: 0, count: n)
                for j in 0..<n { unichars[j] = UniChar(items[i + 2 + j]) }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

                var advances = [CGSize](repeating: .zero, count: n)
                CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advances, n)

                var positions = [CGPoint](repeating: .zero, count: n)
                var localX: CGFloat = 0
                for j in 0..<n {
                    positions[j] = CGPoint(x: localX, y: 0)
                    localX += advances[j].width
                }

                ctx.saveGState()
                ctx.translateBy(x: penX, y: CGFloat(baseY))
                ctx.scaleBy(x: 1, y: -1)
                CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)
                ctx.restoreGState()

                penX += localX
                i += 2 + n
            }

            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func setCursor(topLevel: UInt32, glyph: UInt16?) {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.slot(topLevel)?.view else { return }
            view.currentCursor = nsCursor(forXCursorGlyph: glyph)
        }
    }

    public func setTopLevelWindowBackground(id: UInt32, color: RGB16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let slot = self.slot(id) else { return }
            // RGB16 stores values in the high byte (e.g., 0xFFFF for max).
            // NSColor takes 0..1 floats, so divide by 0xFFFF.
            let r = CGFloat(color.red)   / 65535.0
            let g = CGFloat(color.green) / 65535.0
            let b = CGFloat(color.blue)  / 65535.0
            slot.window?.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
            // The view's layer.backgroundColor is what actually shows during
            // a live-resize drag (since the FlippedXView fully covers the
            // window's content area, NSWindow.backgroundColor is hidden).
            slot.view?.liveResizeBackground = CGColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }

    public func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            for r in rects {
                applyFill(ctx, r.color)
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// Cache of CTFont instances keyed by (macFontName, pointSize). Avoids
    /// re-instantiating the same font on every ImageText8 dispatch.
    nonisolated(unsafe) private static let ctFontCache = NSCache<NSString, CTFont>()

    /// Resolve to a CTFont, caching by name+size key. Falls back to system
    /// monospace if the named font fails to load (very rare on macOS for
    /// the substitutes in our table).
    fileprivate func ctFont(for font: ResolvedFont) -> CTFont {
        let key = "\(font.macFontName)@\(font.pointSize)" as NSString
        if let cached = Self.ctFontCache.object(forKey: key) {
            return cached
        }
        let ct = CTFontCreateWithName(font.macFontName as CFString, CGFloat(font.pointSize), nil)
        Self.ctFontCache.setObject(ct, forKey: key)
        return ct
    }

    // MARK: - Helpers

    private func slot(_ id: UInt32) -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        return slots[id]
    }

    /// Called from the NSWindowDelegate after a user-driven resize. Compute
    /// the new logical (X) dimensions from the NSView's points-bounds via
    /// `points × backingScale / scaleFactor`, reallocate the FlippedXView's
    /// backing CGBitmapContext at the new logical size, then call back into
    /// the session via `resizeHandler` so it can update WindowTable + emit
    /// ConfigureNotify.
    @MainActor
    fileprivate func handleNSWindowResize(id: UInt32) {
        let view = slot(id)?.view
        guard let view = view else { return }
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = view.bounds
        let newLogicalW = Int((bounds.width * backingScale / CGFloat(scaleFactor)).rounded())
        let newLogicalH = Int((bounds.height * backingScale / CGFloat(scaleFactor)).rounded())
        log?.log("  windowDidResize id=0x\(String(id, radix: 16)) bounds=\(bounds.width)x\(bounds.height)pt → logical \(newLogicalW)x\(newLogicalH) (was \(view.logicalWidth)x\(view.logicalHeight)) liveResize=\(view.inLiveResize)")
        guard newLogicalW > 0, newLogicalH > 0 else { return }
        guard newLogicalW != view.logicalWidth || newLogicalH != view.logicalHeight else {
            // No actual size change — don't notify the session (would cause
            // xterm to react to a zero-delta resize).
            return
        }
        // During a live drag we keep the OLD bitmap. Reallocating it here
        // would fire on every pixel of mouse movement and white-flash the
        // window (FlippedXView.resizeBacking allocates a fresh white-filled
        // CGBitmapContext). The layer's backgroundColor (set in
        // setTopLevelWindowBackground) fills the newly-uncovered region in
        // the right colour while the user is dragging. The actual bitmap
        // resize + ConfigureNotify happen once when the drag ends, in
        // handleNSWindowDidEndLiveResize.
        guard !view.inLiveResize else { return }
        view.resizeBacking(logicalWidth: newLogicalW,
                           logicalHeight: newLogicalH,
                           scale: scaleFactor)
        view.setNeedsDisplay(view.bounds)
        fireResize(id: id, w: UInt16(min(newLogicalW, 65535)), h: UInt16(min(newLogicalH, 65535)))
    }

    /// Called by the NSWindowDelegate when a live-resize gesture ends. We
    /// deferred BOTH the bitmap resize and the ConfigureNotify until now;
    /// catch up here using the view's current bounds.
    @MainActor
    fileprivate func handleNSWindowDidEndLiveResize(id: UInt32) {
        guard let view = slot(id)?.view else { return }
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = view.bounds
        let newLogicalW = Int((bounds.width * backingScale / CGFloat(scaleFactor)).rounded())
        let newLogicalH = Int((bounds.height * backingScale / CGFloat(scaleFactor)).rounded())
        log?.log("  windowDidEndLiveResize id=0x\(String(id, radix: 16)) final bounds=\(bounds.width)x\(bounds.height)pt → logical \(newLogicalW)x\(newLogicalH)")
        guard newLogicalW > 0, newLogicalH > 0 else { return }
        if newLogicalW != view.logicalWidth || newLogicalH != view.logicalHeight {
            view.resizeBacking(logicalWidth: newLogicalW,
                               logicalHeight: newLogicalH,
                               scale: scaleFactor)
            view.setNeedsDisplay(view.bounds)
        }
        fireResize(id: id, w: UInt16(min(newLogicalW, 65535)), h: UInt16(min(newLogicalH, 65535)))
    }
}

/// NSWindowDelegate that catches user-driven resizes and key/resign-key focus
/// transitions and forwards them to the bridge. Stays @MainActor since
/// NSWindowDelegate is.
@MainActor
private final class XWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UInt32
    weak var bridge: CocoaWindowBridge?

    init(windowId: UInt32, bridge: CocoaWindowBridge) {
        self.windowId = windowId
        self.bridge = bridge
    }

    func windowDidResize(_ notification: Notification) {
        bridge?.handleNSWindowResize(id: windowId)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        bridge?.handleNSWindowDidEndLiveResize(id: windowId)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        bridge?.handleNSWindowFocusChange(id: windowId, gained: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        bridge?.handleNSWindowFocusChange(id: windowId, gained: false)
    }

    /// Red close button / Window > Close / ⌘W. Tell the session to send the
    /// X client a polite WM_DELETE_WINDOW so the client (xterm/xcalc/etc.)
    /// exits gracefully, then return true so AppKit closes the NSWindow
    /// immediately for snappy visual feedback. The client's natural exit
    /// drops the connection a moment later.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        bridge?.handleNSWindowCloseRequest(id: windowId)
        return true
    }
}

/// Map an X cursor-font source-glyph index to an NSCursor. The X "cursor"
/// font has ~75 named glyphs (XC_xterm = 152, XC_left_ptr = 68, etc.); we
/// substitute the closest macOS system cursor. Unmapped glyphs fall back
/// to NSCursor.arrow. nil glyph (no cursor declared on any ancestor)
/// also falls back to arrow — matches the X root window's default.
private func nsCursor(forXCursorGlyph glyph: UInt16?) -> NSCursor {
    // Constants from <X11/cursorfont.h>. Comments name the X glyph.
    switch glyph {
    case 152: return .iBeam                    // XC_xterm
    case 34, 30, 32, 90, 130, 36:              // crosshair / cross / cross_reverse / plus / tcross / diamond_cross
        return .crosshair
    case 58, 60: return .pointingHand          // XC_hand1 / XC_hand2
    case 52: return .openHand                  // XC_fleur (move)
    case 70, 96, 108, 110, 112:                // left_side / right_side / sb_h_double_arrow / sb_left_arrow / sb_right_arrow
        return .resizeLeftRight
    case 16, 138, 114, 106, 116:               // bottom_side / top_side / sb_up_arrow / sb_down_arrow / sb_v_double_arrow
        return .resizeUpDown
    case 88, 0: return .operationNotAllowed    // XC_pirate / XC_X_cursor
    default: return .arrow                     // XC_left_ptr (68), XC_arrow (2), XC_top_left_arrow (132), and everything we don't map
    }
}

private func applyForeground(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
}

private func applyFill(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
}

extension CocoaWindowBridge {
    public func bell() {
        DispatchQueue.main.async { NSSound.beep() }
    }

    /// Cross-NSWindow drag tracking via NSEvent local monitor.
    ///
    /// Why we need this: AppKit binds `mouseDragged` events to the NSView
    /// where `mouseDown` originated. Once the user clicks a menu title in
    /// the main NSWindow and drags into the popup (a separate NSPanel),
    /// AppKit keeps sending events to the menu title's view. Our X server
    /// wants those events delivered to the popup so menu items can
    /// highlight on enter / activate on release.
    ///
    /// XQuartz solves this with private `xp_*` kernel APIs — events route
    /// at a layer below NSEvent. We don't have those APIs from a regular
    /// Swift AppKit app, but `NSEvent.addLocalMonitorForEvents` is good
    /// enough: it intercepts events in our app before responder dispatch.
    /// We compute the global pointer position, look up which managed
    /// NSWindow contains it (popup-level NSPanels first per z-order),
    /// translate, and fire the X event with the correct window's id.
    /// The original FlippedXView's mouseDragged path is bypassed during
    /// the grab (we return nil from the monitor to consume the event).
    ///
    /// The monitor is only installed while an X grab is active, so the
    /// regular within-window drag path stays unmodified for non-grab
    /// scenarios. install/stop are idempotent and ref-counted via
    /// `dragGrabDepth`; nested grabs don't double-install.
    public func startCrossWindowDragTracking() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dragGrabDepth += 1
            guard self.dragGrabDepth == 1 else { return }
            let mask: NSEvent.EventTypeMask = [
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseUp, .rightMouseUp, .otherMouseUp
            ]
            self.dragMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.dispatchCrossWindowDrag(event)
                return nil   // consume — we've routed it
            }
        }
    }

    public func stopCrossWindowDragTracking() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dragGrabDepth = max(0, self.dragGrabDepth - 1)
            guard self.dragGrabDepth == 0 else { return }
            if let m = self.dragMonitor {
                NSEvent.removeMonitor(m)
                self.dragMonitor = nil
            }
            self.dragLastWindowId = nil
        }
    }

    /// Body of the local monitor: figure out which NSWindow's content
    /// area is under the pointer, route the X event there with translated
    /// coords, fire EnterView/ExitView on cross-window transitions so
    /// menu items get a clean LeaveNotify when the pointer leaves the popup.
    private func dispatchCrossWindowDrag(_ event: NSEvent) {
        // Compute global screen point. AppKit gives us window-local when
        // event.window is non-nil; convert to screen.
        let screenPt: NSPoint
        if let w = event.window {
            screenPt = w.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPt = event.locationInWindow
        }

        let button = Self.xButton(forNSEventType: event.type)
        let isUp: Bool = (event.type == .leftMouseUp
                          || event.type == .rightMouseUp
                          || event.type == .otherMouseUp)

        let target = findManagedWindow(at: screenPt)

        // Cross-window transition: emit EnterView/ExitView so the X server
        // can run its EnterNotify/LeaveNotify chains and menu items
        // un-highlight when the pointer leaves the popup.
        if let lastId = dragLastWindowId, target?.0 != lastId {
            firePointerExitedView(id: lastId)
        }

        if let (xid, view) = target, let win = view.window {
            // Convert screen → window-base → view points. NSView.convert(_:from:nil)
            // means "from window-base coords," NOT from screen — so the screen-to-window
            // step has to happen first via NSWindow.frame offset (both screen-coords,
            // both bottom-left origin in macOS, so simple subtraction).
            let windowPt = NSPoint(
                x: screenPt.x - win.frame.origin.x,
                y: screenPt.y - win.frame.origin.y
            )
            let viewPt = view.convert(windowPt, from: nil)
            // view points → X-logical pixels. The view is .flipped so viewPt.y
            // is already top-left-origin, matching X. Scale by the device-pixel
            // ratio so 1 X-logical pixel maps consistently.
            let bs = NSScreen.main?.backingScaleFactor ?? 2.0
            let logicalX = Int16(viewPt.x * bs / CGFloat(scaleFactor))
            let logicalY = Int16(viewPt.y * bs / CGFloat(scaleFactor))

            if dragLastWindowId != xid {
                firePointerEnteredView(id: xid, x: logicalX, y: logicalY)
            }
            dragLastWindowId = xid

            if isUp {
                fireMouse(id: xid, x: logicalX, y: logicalY, button: button, isDown: false)
            } else {
                fireMouseDragged(id: xid, x: logicalX, y: logicalY, button: button)
            }
        } else {
            // Pointer outside all managed NSWindows. The previous window's
            // ExitView already fired above; just clear the tracker. Don't
            // route the X event anywhere — equivalent to "drag continues
            // off-screen" in real X (no grabbed-client gets motion events
            // outside the screen anyway in our rootless model).
            dragLastWindowId = nil
        }
    }

    /// Find which managed NSWindow's content area contains the screen point.
    /// Iterates highest NSWindow.level first so popups (`.popUpMenu` level)
    /// win over regular top-levels when overlapping. Returns the X-id +
    /// FlippedXView for coordinate translation.
    private func findManagedWindow(at screenPt: NSPoint) -> (UInt32, FlippedXView)? {
        lock.lock()
        let snap = slots
        lock.unlock()
        // Sort by NSWindow.level descending (popups first per z-order)
        let sorted = snap.sorted { lhs, rhs in
            (lhs.value.window?.level.rawValue ?? 0)
                > (rhs.value.window?.level.rawValue ?? 0)
        }
        for (id, slot) in sorted {
            guard let win = slot.window, win.isVisible else { continue }
            guard win.frame.contains(screenPt) else { continue }
            guard let view = slot.view else { continue }
            return (id, view)
        }
        return nil
    }

    /// Translate an NSEvent button to the X-protocol button number.
    /// X11 convention: 1=left, 2=middle, 3=right. macOS "right" maps to X
    /// button 3 even though NSEvent's enum names it `rightMouse`.
    private static func xButton(forNSEventType type: NSEvent.EventType) -> UInt8 {
        switch type {
        case .leftMouseDragged, .leftMouseUp:    return 1
        case .otherMouseDragged, .otherMouseUp:  return 2
        case .rightMouseDragged, .rightMouseUp:  return 3
        default:                                  return 0
        }
    }
}

/// Build a CGPath for an X11 elliptical arc. `arc.x/y/width/height` give the
/// ellipse's bounding box in top-level coords; `arc.angle1` is the start
/// angle in 64ths of a degree (0 = east), `arc.angle2` is the signed extent
/// (positive = counterclockwise per X spec). When `includePieCenter` is true
/// the path is built as a closed pie slice (for PolyFillArc); otherwise it's
/// just the arc curve (for PolyArc). Sampled parametrically so stroke pen
/// width stays uniform on non-circular ellipses.
private func ellipseArcPath(arc a: Arc, includePieCenter: Bool) -> CGPath {
    let cx = CGFloat(a.x) + CGFloat(a.width) / 2
    let cy = CGFloat(a.y) + CGFloat(a.height) / 2
    let rx = CGFloat(a.width) / 2
    let ry = CGFloat(a.height) / 2
    let start = CGFloat(a.angle1) / 64.0 * .pi / 180.0
    let extent = CGFloat(a.angle2) / 64.0 * .pi / 180.0
    let steps = max(8, Int((abs(extent) / .pi) * 32))
    let path = CGMutablePath()
    if includePieCenter {
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx + rx * cos(start), y: cy + ry * sin(start)))
    }
    for i in 0...steps {
        let t = start + extent * CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        if includePieCenter || i > 0 {
            path.addLine(to: p)
        } else {
            path.move(to: p)
        }
    }
    if includePieCenter { path.closeSubpath() }
    return path
}
