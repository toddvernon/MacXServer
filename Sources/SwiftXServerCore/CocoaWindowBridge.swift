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
    //
    // Each handler is paired with a `token` (the registering session's
    // unique `bridgeHandlerToken`) so `removeHandlers(token:)` can prune
    // a session's entries on disconnect. Pre-2026-05-14 the lists grew
    // unboundedly across accept/disconnect cycles and dead-session
    // closures (weak-self no-ops) kept firing on every AppKit event.
    private let handlerLock = NSLock()
    private var resizeHandlers: [(UInt64, @Sendable (UInt32, UInt16, UInt16) -> Void)] = []
    private var moveHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16) -> Void)] = []
    private var keyHandlers: [(UInt64, @Sendable (UInt32, UInt8, UInt, Bool) -> Void)] = []
    private var focusHandlers: [(UInt64, @Sendable (UInt32, Bool) -> Void)] = []
    private var mouseHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16, UInt8, Bool, UInt) -> Void)] = []
    private var mouseDraggedHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16, UInt8, UInt) -> Void)] = []
    private var pointerMovedHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16, UInt) -> Void)] = []
    private var pointerEnteredViewHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16, UInt) -> Void)] = []
    private var pointerExitedViewHandlers: [(UInt64, @Sendable (UInt32, Int16, Int16, UInt) -> Void)] = []
    private var modifiersChangedHandlers: [(UInt64, @Sendable (UInt) -> Void)] = []
    private var pasteHandlers: [(UInt64, @Sendable (UInt32, String) -> Void)] = []
    private var copyHandlers: [(UInt64, @Sendable (UInt32) -> Void)] = []
    private var closeHandlers: [(UInt64, @Sendable (UInt32) -> Void)] = []
    private weak var log: ServerLogSink?

    /// Scale factor: 1 X-logical pixel = `scaleFactor` device pixels.
    /// Pulled from `DisplayConfig.scale` at startup. Integer values are
    /// the Phase-1 happy path; fractional values (e.g. 2.5) are supported
    /// with AA edges at cell boundaries.
    public let scaleFactor: Double

    /// Multi-session lookup registry. The bridge is a singleton shared
    /// across all connected sessions, but pixmap tables and window tables
    /// are session-local. Pre-2026-05-23 we stored a single closure per
    /// lookup type, set-last-wins; that broke as soon as two Motif apps
    /// ran concurrently — session B's closures overwrote session A's, so
    /// every draw on a session-A window asked session B's table for the
    /// window, missed, and silently dropped (visible as "second app's
    /// menu items don't render text + highlight while bg + outline do").
    ///
    /// Now: each session registers its closure under its own token
    /// (`bridgeHandlerToken`) on connect, and unregisters on disconnect.
    /// Internal `lookupX(...)` helpers walk all registered closures and
    /// return the first non-nil result. Per-session contracts:
    ///   - pixmap-buffer lookup: returns the PixelBuffer if this session
    ///     owns the pixmap id, else nil.
    ///   - window-clip lookup: returns the clipList rects (possibly
    ///     empty array = "known but fully obscured") if this session
    ///     owns the window id, else nil.
    ///   - color-table lookup: server-global ColorTable — same instance
    ///     across all sessions, so multi-registration is harmless.
    ///
    /// `setX` setters are kept for backward compat with tests that don't
    /// use a session token; internally they register under token 0.
    private let lookupLock = NSLock()
    private var pixmapBufferLookups: [UInt64: @Sendable (UInt32) -> PixelBuffer?] = [:]
    private var windowClipLookups:   [UInt64: @Sendable (UInt32) -> [Framer.Rectangle]?] = [:]
    private var colorTableLookups:   [UInt64: @Sendable () -> ColorTable?] = [:]

    public func registerPixmapBufferLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        pixmapBufferLookups[token] = lookup
    }
    public func unregisterPixmapBufferLookup(token: UInt64) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        pixmapBufferLookups.removeValue(forKey: token)
    }
    public func setPixmapBufferLookup(_ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?) {
        registerPixmapBufferLookup(token: 0, lookup)
    }
    private func lookupPixmapBuffer(_ id: UInt32) -> PixelBuffer? {
        lookupLock.lock()
        let closures = Array(pixmapBufferLookups.values)
        lookupLock.unlock()
        for lookup in closures {
            if let buf = lookup(id) { return buf }
        }
        return nil
    }

    public func registerWindowClipLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> [Framer.Rectangle]?) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        windowClipLookups[token] = lookup
    }
    public func unregisterWindowClipLookup(token: UInt64) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        windowClipLookups.removeValue(forKey: token)
    }
    /// Legacy single-set entry point. Tests that don't construct a session
    /// use this; it registers under token 0. Note the closure here returns
    /// non-optional `[Framer.Rectangle]` (the pre-2026-05-23 contract);
    /// we wrap it to match the new optional contract by returning the
    /// array even when empty (the legacy behavior — empty = fully
    /// obscured, which `withDrawContext` short-circuits on).
    public func setWindowClipLookup(_ lookup: @escaping @Sendable (UInt32) -> [Framer.Rectangle]) {
        registerWindowClipLookup(token: 0) { id in lookup(id) }
    }
    private func lookupWindowClip(_ id: UInt32) -> [Framer.Rectangle]? {
        lookupLock.lock()
        let closures = Array(windowClipLookups.values)
        lookupLock.unlock()
        for lookup in closures {
            if let clip = lookup(id) { return clip }
        }
        return nil
    }

    public func registerColorTableLookup(token: UInt64, _ lookup: @escaping @Sendable () -> ColorTable?) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        colorTableLookups[token] = lookup
    }
    public func unregisterColorTableLookup(token: UInt64) {
        lookupLock.lock(); defer { lookupLock.unlock() }
        colorTableLookups.removeValue(forKey: token)
    }
    public func setColorTableLookup(_ lookup: @escaping @Sendable () -> ColorTable?) {
        registerColorTableLookup(token: 0, lookup)
    }
    private func lookupColorTable() -> ColorTable? {
        lookupLock.lock()
        let closures = Array(colorTableLookups.values)
        lookupLock.unlock()
        for lookup in closures {
            if let ct = lookup() { return ct }
        }
        return nil
    }


    /// Optional Motif-frame preference provider. Bridge snapshots the
    /// current value at mapTopLevel time and uses it to decide whether the
    /// NSWindow gets the optional mwm-style chrome instead of native macOS
    /// chrome. Default: native chrome for everyone (nil provider == off).
    public var motifFramePrefs: MotifFramePreferencesProvider?

    public init(scaleFactor: Double = 1,
                log: ServerLogSink? = nil,
                motifFramePrefs: MotifFramePreferencesProvider? = nil) {
        self.scaleFactor = scaleFactor
        self.log = log
        self.motifFramePrefs = motifFramePrefs
    }

    // MARK: - Draw target routing
    //
    // withDrawContext resolves a DrawTarget to a CGContext + clip stack
    // and runs `body` inside it. Window targets dispatch to the main
    // thread (AppKit constraint on view backing access) and trigger a
    // setNeedsDisplay after the body returns. Pixmap targets run the
    // body inline on the calling queue (the session's protocolQueue
    // serializes access to PixelBuffer.context, so no dispatch needed).
    //
    // The `body` sees a CGContext in the right coord space for the
    // target — drawable-local for pixmaps, top-level for windows
    // (caller is responsible for the dx/dy translation of geometry
    // before calling; see DrawTarget.windowOffset). withClip applies
    // clip rectangles, AA-off, and saveGState/restoreGState the same
    // way as the original private withClip helper.

    func withDrawContext(
        _ target: DrawTarget,
        clipRectangles: [Framer.Rectangle]?,
        body: @escaping @Sendable (CGContext) -> Void
    ) {
        switch target {
        case .window(let windowId, let topLevel, let dx, let dy):
            // Translate clip rectangles from widget-local to top-level coords.
            // Per X11 spec, SetClipRectangles rects are in the GC's clip-
            // coordinate system (relative to the drawable the GC draws to).
            // We draw into the top-level NSWindow's backing using top-level
            // coords (handlers already add (dx, dy) to draw positions), so the
            // clip rects need the same translation or they end up in the
            // wrong place — visible as "LCD widget text gets clipped to the
            // top-left corner of the calculator window and disappears."
            // 2026-05-19: this was the dtcalc LCD invisible-text bug. The
            // comment in GCState.materialise at the time claimed the rects
            // were already top-level coords but only clipXOrigin/Yorigin
            // were folded in.
            let translatedClip = clipRectangles?.map { r in
                Framer.Rectangle(
                    x: r.x &+ dx, y: r.y &+ dy,
                    width: r.width, height: r.height
                )
            }
            // Composite clip = window clipList ∩ GC user clip. Per X.org
            // mi/migc.c:miComputeCompositeClip, every per-op draw on a
            // window drawable is clipped to the window's visible region
            // BEFORE the GC's user clip applies. We look up the clipList
            // (in top-level coords) once here and pass it through to
            // withClip alongside the translated GC clip. Empty clipList =
            // window fully obscured — withClip short-circuits and the
            // body never runs. Lookup nil = no session knows the window
            // (test/bring-up path, or cross-session lookup miss that
            // pre-2026-05-23 silently dropped draws); degrade to
            // GC-clip-only so legacy tests still pass and so a draw on
            // a window the bridge doesn't know about still happens.
            let windowClip = self.lookupWindowClip(windowId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let view = self.slot(topLevel)?.view,
                      let ctx = view.backing else { return }
                self.withClip(ctx, windowClip: windowClip, gcClip: translatedClip) {
                    body(ctx)
                }
                view.setNeedsDisplay(view.bounds)
            }
        case .pixmap(let id, let depth):
            guard let buffer = self.lookupPixmapBuffer(id) else { return }
            self.withClip(buffer.context, clipRectangles) {
                if depth == 1 {
                    // Depth-1 pixmaps are usually stipple sources.
                    // FillStippled's bit reader treats a pixel as "set"
                    // only when it's fully black; AA-soft edges between
                    // PolySegment carves would shrink the readable set
                    // bits to nothing, leaving Motif's caret looking
                    // like dots rather than a proper I-beam.
                    buffer.context.saveGState()
                    buffer.context.setShouldAntialias(false)
                    buffer.context.setAllowsAntialiasing(false)
                    body(buffer.context)
                    buffer.context.restoreGState()
                } else {
                    body(buffer.context)
                }
            }
        }
    }

    public func setOnTopLevelResize(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
        handlerLock.lock(); resizeHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnTopLevelMove(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {
        handlerLock.lock(); moveHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnKey(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void) {
        handlerLock.lock(); keyHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnFocus(token: UInt64, _ handler: @escaping @Sendable (UInt32, Bool) -> Void) {
        handlerLock.lock(); focusHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnMouse(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool, UInt) -> Void) {
        handlerLock.lock(); mouseHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnMouseDragged(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, UInt) -> Void) {
        handlerLock.lock(); mouseDraggedHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnPointerMoved(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt) -> Void) {
        handlerLock.lock(); pointerMovedHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnPointerEnteredView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt) -> Void) {
        handlerLock.lock(); pointerEnteredViewHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnPointerExitedView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt) -> Void) {
        handlerLock.lock(); pointerExitedViewHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnModifiersChanged(token: UInt64, _ handler: @escaping @Sendable (UInt) -> Void) {
        handlerLock.lock(); modifiersChangedHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnPaste(token: UInt64, _ handler: @escaping @Sendable (UInt32, String) -> Void) {
        handlerLock.lock(); pasteHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnCopy(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void) {
        handlerLock.lock(); copyHandlers.append((token, handler)); handlerLock.unlock()
    }

    public func setOnCloseRequest(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void) {
        handlerLock.lock(); closeHandlers.append((token, handler)); handlerLock.unlock()
    }

    /// Remove every handler this session previously registered. Called from
    /// the session's cleanupOnDisconnect path. Idempotent — second call is
    /// a no-op once the lists no longer contain that token.
    public func removeHandlers(token: UInt64) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        resizeHandlers.removeAll              { $0.0 == token }
        moveHandlers.removeAll                { $0.0 == token }
        keyHandlers.removeAll                 { $0.0 == token }
        focusHandlers.removeAll               { $0.0 == token }
        mouseHandlers.removeAll               { $0.0 == token }
        mouseDraggedHandlers.removeAll        { $0.0 == token }
        pointerMovedHandlers.removeAll        { $0.0 == token }
        pointerEnteredViewHandlers.removeAll  { $0.0 == token }
        pointerExitedViewHandlers.removeAll   { $0.0 == token }
        modifiersChangedHandlers.removeAll    { $0.0 == token }
        pasteHandlers.removeAll               { $0.0 == token }
        copyHandlers.removeAll                { $0.0 == token }
        closeHandlers.removeAll               { $0.0 == token }
    }

    /// Total registered handler count across every list. Test affordance.
    public var totalHandlerCount: Int {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return resizeHandlers.count + moveHandlers.count + keyHandlers.count
             + focusHandlers.count + mouseHandlers.count + mouseDraggedHandlers.count
             + pointerMovedHandlers.count + pointerEnteredViewHandlers.count
             + pointerExitedViewHandlers.count + modifiersChangedHandlers.count
             + pasteHandlers.count + copyHandlers.count + closeHandlers.count
    }

    // MARK: - Handler fan-out

    /// Snapshot the named handler list under the lock and fire each in turn.
    /// Snapshotting (rather than holding the lock through the fan-out) so
    /// a handler can safely append/register new handlers without deadlocking.
    private func fireResize(id: UInt32, w: UInt16, h: UInt16) {
        handlerLock.lock(); let snap = resizeHandlers; handlerLock.unlock()
        for (_, handler) in snap { handler(id, w, h) }
    }
    private func fireMove(id: UInt32, x: Int16, y: Int16) {
        handlerLock.lock(); let snap = moveHandlers; handlerLock.unlock()
        for (_, handler) in snap { handler(id, x, y) }
    }
    private func fireKey(id: UInt32, code: UInt8, mods: UInt, isDown: Bool) {
        handlerLock.lock(); let snap = keyHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, code, mods, isDown) }
    }
    private func fireFocus(id: UInt32, gained: Bool) {
        handlerLock.lock(); let snap = focusHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, gained) }
    }
    private func fireMouse(id: UInt32, x: Int16, y: Int16, button: UInt8, isDown: Bool, mods: UInt) {
        handlerLock.lock(); let snap = mouseHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, x, y, button, isDown, mods) }
    }
    private func fireMouseDragged(id: UInt32, x: Int16, y: Int16, button: UInt8, mods: UInt) {
        handlerLock.lock(); let snap = mouseDraggedHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, x, y, button, mods) }
    }
    private func firePointerMoved(id: UInt32, x: Int16, y: Int16, mods: UInt) {
        handlerLock.lock(); let snap = pointerMovedHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, x, y, mods) }
    }
    private func firePointerEnteredView(id: UInt32, x: Int16, y: Int16, mods: UInt) {
        handlerLock.lock(); let snap = pointerEnteredViewHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, x, y, mods) }
    }
    private func firePointerExitedView(id: UInt32, x: Int16, y: Int16, mods: UInt) {
        handlerLock.lock(); let snap = pointerExitedViewHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, x, y, mods) }
    }
    private func fireModifiersChanged(mods: UInt) {
        handlerLock.lock(); let snap = modifiersChangedHandlers; handlerLock.unlock()
        for (_, h) in snap { h(mods) }
    }
    private func firePaste(id: UInt32, text: String) {
        handlerLock.lock(); let snap = pasteHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id, text) }
    }
    private func fireCopy(id: UInt32) {
        handlerLock.lock(); let snap = copyHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id) }
    }
    private func fireCloseRequest(id: UInt32) {
        handlerLock.lock(); let snap = closeHandlers; handlerLock.unlock()
        for (_, h) in snap { h(id) }
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
        topLevelExposeRects: [BoxRec],
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
            topLevelExposeRects: topLevelExposeRects,
            descendants: descendants,
            overrideRedirect: overrideRedirect,
            byteOrder: byteOrder, sequence: sequence,
            outbound: outbound
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Race guard: if the session torn down (cleanupOnDisconnect →
            // destroyTopLevel) ran between this mapTopLevel's protocol-thread
            // dispatch and our turn on main, the slot is already gone and any
            // NSWindow we create here would be orphaned — no slot to look it
            // up from for a later destroy, no reference from us, but visible
            // on screen at popUpMenu level for override-redirect panels.
            // That's the "rogue popup that survives" pattern from the xterm
            // 2026-05-31 capture audit. Detect and bail. Same shape as the
            // protocol-thread `if slots[id] != nil` check above; this is the
            // main-thread bookend.
            self.lock.lock()
            let stillRegistered = self.slots[id] != nil
            self.lock.unlock()
            guard stillRegistered else {
                self.log?.log("  bridge: skip NSWindow create for 0x\(String(id, radix: 16)) — slot removed before main thread serviced (likely disconnect race)")
                return
            }
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
            view.mouseHandler = { [weak self] x, y, button, isDown, mods in
                self?.fireMouse(id: id, x: x, y: y, button: button, isDown: isDown, mods: mods)
            }
            view.mouseDraggedHandler = { [weak self] x, y, button, mods in
                self?.fireMouseDragged(id: id, x: x, y: y, button: button, mods: mods)
            }
            view.mouseMovedHandler = { [weak self] x, y, mods in
                self?.firePointerMoved(id: id, x: x, y: y, mods: mods)
            }
            view.mouseEnteredHandler = { [weak self] x, y, mods in
                self?.firePointerEnteredView(id: id, x: x, y: y, mods: mods)
            }
            view.mouseExitedHandler = { [weak self] x, y, mods in
                self?.firePointerExitedView(id: id, x: x, y: y, mods: mods)
            }
            view.flagsChangedHandler = { [weak self] mods in
                self?.fireModifiersChanged(mods: mods)
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
            //
            // Motif frame opt-in: when the user has the Motif-frame pref on
            // (and we're not a popup), wrap the X client in a MotifWindow
            // (.closable/.miniaturizable/.resizable, no .titled — that mask
            // gives square corners and working close/min/zoom). The NSWindow
            // content rect grows by `MotifTheme.current.horizontalPadding` /
            // `verticalPadding` so the X client area inside the frame is
            // still exactly its requested geometry, matching what a
            // reparenting WM does in real X (ICCCM §4.2.1).
            let style: NSWindow.StyleMask = overrideRedirect
                ? [.borderless, .nonactivatingPanel]
                : [.titled, .closable, .miniaturizable, .resizable]
            let motifEnabled = !overrideRedirect && (self.motifFramePrefs?.current.enabled ?? false)
            let motifButtonStyle = self.motifFramePrefs?.current.buttonStyle ?? .motif

            // Identity-map X-root coords → NSScreen coords. The session
            // already wrote each top-level's X-root position to its
            // WindowEntry on first map (see ServerSession.placeTopLevelIfNeeded
            // for regular top-levels; override-redirect popups bring their
            // own root coords via ConfigureWindow before MapWindow). So
            // geometry.x / geometry.y are the X-root position in X logical
            // pixels, and we map them straight to NSScreen with a Y flip
            // against the main screen height (X is top-left origin, Cocoa
            // is bottom-left). This is the invariant the popup-placement
            // bug needed: same conversion for regular windows and popups,
            // every "where am I in root" query the client can issue gives
            // an answer that matches what's actually on screen.
            let screenH = NSScreen.main?.frame.size.height ?? 1080
            let xClientOriginX = CGFloat(geometry.x) * CGFloat(scale) / backingScale
            let topOffset = CGFloat(geometry.y) * CGFloat(scale) / backingScale
            let xClientOriginY = screenH - topOffset - pointsH

            // NSWindow content rect: when motifEnabled, grow by the frame
            // insets and shift origin so the inner X-client area lands at the
            // same on-screen position it would have had with native chrome.
            let contentRect: NSRect
            if motifEnabled {
                let leftPad = MotifTheme.current.clientLeftInset
                let bottomPad = MotifTheme.current.clientBottomInset
                contentRect = NSRect(
                    x: xClientOriginX - leftPad,
                    y: xClientOriginY - bottomPad,
                    width: pointsW + MotifTheme.current.horizontalPadding,
                    height: pointsH + MotifTheme.current.verticalPadding
                )
            } else {
                contentRect = NSRect(
                    x: xClientOriginX, y: xClientOriginY,
                    width: pointsW, height: pointsH
                )
            }
            self.log?.log("  bridge: NSWindow 0x\(String(id, radix: 16)) at NSScreen=\(contentRect) (X-root=(\(geometry.x),\(geometry.y)) \(geometry.width)x\(geometry.height) override=\(overrideRedirect) motif=\(motifEnabled))")
            let win: NSWindow
            if overrideRedirect {
                let panel = NSPanel(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
                panel.level = .popUpMenu
                panel.hidesOnDeactivate = false
                panel.becomesKeyOnlyIfNeeded = true
                win = panel
                win.contentView = view
            } else if motifEnabled {
                let motif = MotifWindow(contentRect: contentRect, clientView: view)
                motif.buttonStyle = motifButtonStyle
                motif.windowTitle = pendingTitle
                win = motif
            } else {
                win = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
                win.contentView = view
            }
            if !overrideRedirect && !motifEnabled { win.title = pendingTitle }
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
            // orderOut THEN close. NSWindow.close() does call orderOut
            // internally, but for NSPanels at popUpMenu level with
            // hidesOnDeactivate=false (our override-redirect popup path —
            // mapTopLevel L627-633), explicit orderOut ensures the
            // visual disappears before any close-side asynchrony in
            // AppKit's window-list pruning. Belt-and-suspenders aimed
            // at the "rogue popup persists" symptom.
            win?.orderOut(nil)
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
            DispatchQueue.main.async {
                win.title = title
                // MotifWindow paints its title text from `windowTitle` on the
                // MotifFrameView, not the standard NSWindow.title (the .titled
                // mask is intentionally absent so there's no native title bar
                // to display win.title in).
                (win as? MotifWindow)?.windowTitle = title
            }
        }
    }

    public func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {
        // M3 hook — mark the NSView's region for that descendant as needing
        // redraw. M2 doesn't do anything visible.
    }

    /// X client reconfigured an already-mapped top-level. Push the new
    /// geometry to the NSWindow's frame. Mirrors the placement formula
    /// used at createWindow / mapTopLevel time: X-root (x, y, w, h) →
    /// NSScreen content rect with backing-scale + Y-flip-against-main-
    /// screen-height. If the slot's NSWindow isn't created yet (e.g.,
    /// ConfigureWindow arrived before MapWindow's main-thread setup
    /// completed), just update the stored geometry — mapTopLevel reads
    /// the latest slot.geometry when it creates the NSWindow.
    public func reconfigureTopLevel(id: UInt32, geometry: TopLevelGeometry) {
        lock.lock()
        slots[id]?.geometry = geometry
        let win = slots[id]?.window
        let view = slots[id]?.view
        lock.unlock()
        let scale = self.scaleFactor
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let win = win else { return }
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let screenH = NSScreen.main?.frame.size.height ?? 1080
            let pointsW = CGFloat(geometry.width) * CGFloat(scale) / backingScale
            let pointsH = CGFloat(geometry.height) * CGFloat(scale) / backingScale
            let xClientOriginX = CGFloat(geometry.x) * CGFloat(scale) / backingScale
            let topOffset = CGFloat(geometry.y) * CGFloat(scale) / backingScale
            let xClientOriginY = screenH - topOffset - pointsH
            // For a titled (regular) NSWindow, frame includes the title bar;
            // we want the CONTENT to be at (xClientOriginX, xClientOriginY)
            // with the requested size. For a MotifWindow, the NSWindow content
            // rect is larger than the X-client area by the frame insets, so
            // grow the rect to wrap the X geometry from the outside.
            let contentRect: NSRect
            if win is MotifWindow {
                let leftPad = MotifTheme.current.clientLeftInset
                let bottomPad = MotifTheme.current.clientBottomInset
                contentRect = NSRect(
                    x: xClientOriginX - leftPad,
                    y: xClientOriginY - bottomPad,
                    width: pointsW + MotifTheme.current.horizontalPadding,
                    height: pointsH + MotifTheme.current.verticalPadding
                )
            } else {
                contentRect = NSRect(x: xClientOriginX, y: xClientOriginY,
                                     width: pointsW, height: pointsH)
            }
            let frameRect = win.frameRect(forContentRect: contentRect)
            self.log?.log("  bridge: reconfigure 0x\(String(id, radix: 16)) → X-root (\(geometry.x),\(geometry.y)) \(geometry.width)x\(geometry.height) → NSScreen frame=\(frameRect)")
            win.setFrame(frameRect, display: true, animate: false)
            // Resize the FlippedXView's backing bitmap to the new logical
            // dimensions so subsequent draws aren't clipped to the prior
            // size. autoresizingMask=[.width,.height] keeps the view's
            // point-frame in sync with the NSWindow content rect; the
            // backing bitmap is a separate buffer that needs the explicit
            // resize call.
            if let view = view {
                view.resizeBacking(
                    logicalWidth: Int(geometry.width),
                    logicalHeight: Int(geometry.height),
                    scale: scale
                )
                view.setNeedsDisplay(view.bounds)
            }
        }
    }

    public func drawingTarget(for drawable: UInt32) -> Any? {
        slot(drawable)?.view
    }

    // MARK: - Drawing

    public func drawPolySegment(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, capStyle: UInt8, segments: [LineSegment], clipRectangles: [Framer.Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {
        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyForeground(ctx, foreground)
            self?.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            self?.applyLineCap(ctx, capStyle)
            self?.applyDashes(ctx, dashes, dashOffset: dashOffset)
            for s in segments {
                ctx.move(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                ctx.addLine(to: CGPoint(x: CGFloat(s.x2), y: CGFloat(s.y2)))
            }
            ctx.strokePath()
        }
    }

    public func drawPolyLine(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, capStyle: UInt8, points: [DrawPoint], clipRectangles: [Framer.Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {
        guard !points.isEmpty else { return }
        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyForeground(ctx, foreground)
            self?.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            self?.applyLineCap(ctx, capStyle)
            self?.applyDashes(ctx, dashes, dashOffset: dashOffset)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.strokePath()
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
    /// AA is off (set by `withClip`); the +0.5 alignment is still required
    /// because without it, CG with AA off picks an adjacent pixel row
    /// arbitrarily — flips between runs and produces inconsistent stroke
    /// position. With AA off + the +0.5 offset, every horizontal/vertical
    /// X-pixel-address stroke lands deterministically on its nominal row/
    /// column. Diagonals stair-step rather than smooth, which is the
    /// correct X11 behavior — see DECISIONS for the rationale on
    /// AA-off-everywhere-except-text.
    /// Run `body` with X11-protocol-correct rendering settings:
    ///   - AA off (X11 is a pixel-aligned protocol; clients send integer
    ///     coords and expect crisp output; AA produces halo artifacts on
    ///     erase-then-redraw loops like xclock hands, xeyes pupils, and
    ///     the quickplot y=50 seam)
    ///   - Image interpolation .none (belt and suspenders against any
    ///     CG-internal resampling at the backing-context layer)
    ///   - GC clip rectangles applied
    ///
    /// All non-text drawing primitives use this wrapper. Text-glyph
    /// rendering (ImageText8 / PolyText8) calls `ctx.setShouldAntialias(true)`
    /// inside the body to re-enable AA just for glyph rasterization —
    /// we render scalable Core Text fonts and pixelated glyphs would
    /// look worse than the Sun bitmap fonts they're substituting for.
    ///
    /// Clip semantics: nil = no clip (unbounded draw); empty array =
    /// clip-everything (skip the body entirely per X spec); non-empty =
    /// clip to the union of the rectangles. Wraps in saveGState /
    /// restoreGState so nothing leaks.
    /// Two-clip overload used by the window-target draw path. Applies the
    /// window's clipList FIRST (matches X.org's miComputeCompositeClip
    /// order: window region then GC user clip), then the GC user clip.
    /// CGContext.clip(to:) intersects with the current clip path so the
    /// composite is the intersection of both. Either may be nil (no clip
    /// from that side); both empty arrays short-circuit the body per X
    /// spec ("clip-to-nothing skips the op entirely").
    private func withClip(
        _ ctx: CGContext,
        windowClip: [Framer.Rectangle]?,
        gcClip: [Framer.Rectangle]?,
        _ body: () -> Void
    ) {
        if let r = windowClip, r.isEmpty { return }
        if let r = gcClip, r.isEmpty { return }
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        // The window clipList is device-coord (DEVICE_COORDS_REFACTOR.md).
        // To make CG rasterize it at exact device pixels, swap to identity
        // CTM for the clip-path build, apply the clip, then concat back to
        // the original CTM for the drawing body. The clip is stored in
        // absolute device coords in the gstate, so the CTM swap doesn't
        // disturb it. Restoring the CTM also lets the body draw at logical
        // X coords as before — the CTM scales them to device, where they
        // get checked against the (already-device) clip.
        if let rects = windowClip {
            let savedCTM = ctx.ctm
            ctx.concatenate(savedCTM.inverted())
            ctx.clip(to: rects.map {
                CGRect(x: CGFloat($0.x), y: CGFloat($0.y),
                       width: CGFloat($0.width), height: CGFloat($0.height))
            })
            ctx.concatenate(savedCTM)
        }
        if let rects = gcClip {
            // GC clip rectangles are at logical X coords (drawable-local
            // translated to top-level-logical by withDrawContext). They go
            // through the current (scaled) CTM at clip() time, so they
            // produce a device-pixel clip aligned to whole logical pixels.
            // That matches X11 semantics: SetClipRectangles is defined at
            // logical pixel granularity.
            ctx.clip(to: rects.map {
                CGRect(x: CGFloat($0.x), y: CGFloat($0.y),
                       width: CGFloat($0.width), height: CGFloat($0.height))
            })
        }
        body()
        ctx.restoreGState()
    }

    /// GC-clip-only overload — pixmap drawing (no window region) and the
    /// ClearArea path (window region already intersected by the session)
    /// route here. Equivalent to the pre-2026-05-20 `withClip` shape.
    private func withClip(_ ctx: CGContext, _ clipRects: [Framer.Rectangle]?, _ body: () -> Void) {
        withClip(ctx, windowClip: nil, gcClip: clipRects, body)
    }

    /// Apply the GC's SetDashes pattern to the context. nil / empty pattern =
    /// solid (no-op). Pattern bytes are run lengths in pixels, alternating
    /// on/off starting with on; phase offset is in pixels along the path.
    /// Per X spec a pattern of [N] (single byte) is equivalent to [N, N] —
    /// equal on/off runs. CGContext.setLineDash with one length applies it
    /// as a uniform on-period, so we duplicate single-byte patterns for
    /// spec-compliant behavior.
    private func applyDashes(_ ctx: CGContext, _ dashes: [UInt8]?, dashOffset: UInt32) {
        guard let dashes = dashes, !dashes.isEmpty else {
            ctx.setLineDash(phase: 0, lengths: [])
            return
        }
        let lengths: [CGFloat]
        if dashes.count == 1 {
            let v = CGFloat(dashes[0])
            lengths = [v, v]
        } else {
            lengths = dashes.map { CGFloat($0) }
        }
        ctx.setLineDash(phase: CGFloat(dashOffset), lengths: lengths)
    }

    private func applyStrokePlane(_ ctx: CGContext, clientLineWidth: UInt32) {
        let cw = max(Int(clientLineWidth), 1)
        ctx.translateBy(x: 0.5, y: 0.5)
        ctx.setLineWidth(CGFloat(cw))
    }

    /// Map the X11 cap-style byte to CG. X11: 0 NotLast (treat as Butt at
    /// stroke-end level — the "don't draw last point" semantics only matter
    /// for chained thin lines), 1 Butt, 2 Round, 3 Projecting (= square,
    /// extends half a line-width past the endpoint).
    private func applyLineCap(_ ctx: CGContext, _ capStyle: UInt8) {
        switch capStyle {
        case 2: ctx.setLineCap(.round)
        case 3: ctx.setLineCap(.square)
        default: ctx.setLineCap(.butt)
        }
    }

    public func drawFillPoly(target: DrawTarget, foreground: RGB16, points: [DrawPoint], evenOdd: Bool, clipRectangles: [Framer.Rectangle]?) {
        guard !points.isEmpty else { return }
        withDrawContext(target, clipRectangles: clipRectangles) { ctx in
            applyFill(ctx, foreground)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.closePath()
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
    }

    public func clearArea(topLevel: UInt32, rects: [Framer.Rectangle], background: RGB16) {
        if rects.isEmpty { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            // Caller passes device-coord rects (handleClearArea intersects
            // the request rect with the device-coord clipList). Fill under
            // identity CTM so each rect lands at exact device pixels.
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.interpolationQuality = .none
            let savedCTM = ctx.ctm
            ctx.concatenate(savedCTM.inverted())
            applyFill(ctx, background)
            for r in rects {
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// Read pixels out of a drawable as 32-bit BGRA at LOGICAL X-coord scale.
    /// `src` is a resolved DrawTarget; (srcX, srcY) is in drawable-local
    /// X-protocol coords (top-left of the rectangle); width / height are
    /// logical pixels.
    ///
    /// Returns one UInt32 per logical pixel — row-major top-to-bottom, left-
    /// to-right. The UInt32 is the device-pixel's raw 32-bit memory word as
    /// CGBitmapContext stored it (premultiplied-first, byteOrder32Little) so
    /// in memory that's B G R A. Callers extract channels accordingly.
    ///
    /// For window targets the backing is at device-scale (`scaleFactor` 1×/
    /// 2×/3×); we sample the top-left device pixel of each logical block.
    /// For pixmap targets we read at the pixmap's own stored scale (usually
    /// 1, except Motif-XmText save-under pixmaps allocated at device scale).
    ///
    /// Returns an empty array if the target can't be resolved (window not
    /// yet mapped, pixmap freed mid-request). Callers should emit BadDrawable
    /// in that case via the normal validator path; this helper is best-
    /// effort and trusts the caller's prior validation.
    public func readDrawablePixels(
        from src: DrawTarget,
        srcX: Int16, srcY: Int16,
        width: Int, height: Int
    ) -> [UInt32] {
        guard width > 0, height > 0 else { return [] }
        let total = width * height
        var out = [UInt32](repeating: 0, count: total)

        switch src {
        case .window(_, let topLevel, let dx, let dy):
            // (srcX, srcY) is drawable-local; the backing is in top-level coords.
            let topX = Int(srcX) + Int(dx)
            let topY = Int(srcY) + Int(dy)
            let scale = self.scaleFactor
            DispatchQueue.main.sync { [weak self] in
                guard let self = self,
                      let view = self.slot(topLevel)?.view,
                      let ctx = view.backing,
                      let data = ctx.data else { return }
                sampleBGRA(
                    data: data,
                    bytesPerRow: ctx.bytesPerRow,
                    contextWidth: ctx.width,
                    contextHeight: ctx.height,
                    originX: topX, originY: topY,
                    width: width, height: height,
                    scale: scale,
                    out: &out
                )
            }

        case .pixmap(let id, _):
            guard let buf = lookupPixmapBuffer(id),
                  let data = buf.context.data else { return [] }
            sampleBGRA(
                data: data,
                bytesPerRow: buf.context.bytesPerRow,
                contextWidth: buf.context.width,
                contextHeight: buf.context.height,
                originX: Int(srcX), originY: Int(srcY),
                width: width, height: height,
                scale: buf.scaleFactor,
                out: &out
            )
        }

        return out
    }

    public func copyArea(
        src: DrawTarget,
        dst: DrawTarget,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        // Same-NSWindow fast path: bitmap memmove. xterm scroll lives here;
        // skipping the CGImage snapshot+blit keeps the hot path tight.
        // Clip is NOT honored on this path — the memmove can't easily
        // scissor — but the only client that exercises same-window CopyArea
        // (xterm) doesn't set clip. Logged when it does so future divergence
        // is visible.
        if case .window(_, let srcTop, _, _) = src,
           case .window(_, let dstTop, _, _) = dst,
           srcTop == dstTop {
            if let rects = clipRectangles, !rects.isEmpty {
                log?.log("  CopyArea: ignoring \(rects.count) clip rect(s) — bitmap memmove path doesn't honor clip")
            }
            sameWindowMemmoveCopyArea(topLevel: srcTop,
                                      srcX: srcX, srcY: srcY,
                                      dstX: dstX, dstY: dstY,
                                      width: width, height: height)
            return
        }

        // All other cases (cross-NSWindow, pixmap↔window, pixmap↔pixmap):
        // snapshot the source as a CGImage cropped to the source rect, then
        // blit via CGContext.draw(image:in:) into dst's context. The image
        // path handles overlap automatically (the snapshot is independent of
        // the source memory) and honors GC clip for free via withDrawContext.
        //
        // Pixmap src: snapshot inline (no AppKit, no dispatch needed —
        // protocolQueue serializes access to the pixmap CGBitmapContext).
        // Window src: hop to main first (view.backing access must be on the
        // main thread). withDrawContext handles its own main-dispatch when
        // dst is a window.
        switch src {
        case .pixmap(let srcId, _):
            guard let buffer = self.lookupPixmapBuffer(srcId),
                  let srcImage = buffer.context.makeImage() else { return }
            // Pixmap backings are stored at device scale (see PixelBuffer);
            // the resulting CGImage is `width*scaleFactor × height*scaleFactor`
            // device pixels, not the logical X dimensions. Pass the buffer's
            // scale so blitCroppedImage's crop math reads at the right rect.
            blitCroppedImage(
                srcImage, srcImageScale: buffer.scaleFactor,
                srcX: srcX, srcY: srcY, dst: dst,
                dstX: dstX, dstY: dstY,
                width: width, height: height,
                clipRectangles: clipRectangles
            )
        case .window(_, let srcTopLevel, _, _):
            // SYNCHRONOUS to main: window→pixmap CopyArea is Motif's
            // save-under for the XmText caret. Snapshotting the window
            // backing must happen on main (view.backing lives there) AND
            // the pixmap write must complete before the protocol queue
            // processes the next request — otherwise a subsequent
            // pixmap→window restore (req N+1) reads the save pixmap on
            // the protocol thread while main is still writing into it,
            // producing the classic cursor-bleed artifact (fragments of
            // the previous character carried into the new cursor area).
            //
            // XQuartz solves the same race with xp_lock_window (kernel-
            // private, see hw/xquartz/xpr/xprFrame.c:xprStartDrawing) so
            // its server-thread can safely read AND write the window
            // bytes. We don't have xp_lock_window; dispatch_sync is the
            // cheapest equivalent — protocol queue blocks until main
            // completes the read+write, mirroring the lock-bounded
            // exclusive-access window.
            //
            // No deadlock risk: bridge→protocolQueue callbacks (mouse,
            // key, focus) all use queue.async, so main never sync-waits
            // on the protocol queue.
            let scaleFactor = self.scaleFactor
            DispatchQueue.main.sync { [weak self] in
                guard let self = self,
                      let srcImage = self.slot(srcTopLevel)?.view?.backing?.makeImage() else { return }
                self.blitCroppedImage(
                    srcImage, srcImageScale: scaleFactor,
                    srcX: srcX, srcY: srcY, dst: dst,
                    dstX: dstX, dstY: dstY,
                    width: width, height: height,
                    clipRectangles: clipRectangles
                )
            }
        }
    }

    /// Shared blit body for the non-same-NSWindow CopyArea paths. Crops the
    /// source image to (srcX,srcY,width,height) in IMAGE-pixel coords
    /// (window: device-scaled; pixmap: 1:1 logical), then draws into dst's
    /// CGContext via withDrawContext at the (dstX,dstY,width,height) rect
    /// in dst's user-space coords (always LOGICAL — dst's CTM handles any
    /// upscale for window targets).
    private func blitCroppedImage(
        _ srcImage: CGImage,
        srcImageScale: Double,
        srcX: Int16, srcY: Int16,
        dst: DrawTarget,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        let cropRect = CGRect(
            x: CGFloat(Double(srcX) * srcImageScale),
            y: CGFloat(Double(srcY) * srcImageScale),
            width: CGFloat(Double(width) * srcImageScale),
            height: CGFloat(Double(height) * srcImageScale)
        )
        guard let subImage = srcImage.cropping(to: cropRect) else { return }
        let dstRect = CGRect(
            x: CGFloat(dstX), y: CGFloat(dstY),
            width: CGFloat(width), height: CGFloat(height)
        )
        withDrawContext(dst, clipRectangles: clipRectangles) { ctx in
            // See GRAPHICS_Y_FLIP.md. The helper compensates for the
            // y-flipped backing CTM so image rows land top-down in memory.
            ctx.drawImageRespectingYFlip(subImage, in: dstRect)
        }
    }

    /// Same-NSWindow CopyArea: copies pixels in the bitmap directly via
    /// memmove. Used by xterm's scroll. No clip honor (memmove can't scissor
    /// per row without becoming much slower). Caller handles clip-logging.
    private func sameWindowMemmoveCopyArea(
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

    public func drawPolyRectangle(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, rectangles: [Framer.Rectangle], clipRectangles: [Framer.Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {
        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyForeground(ctx, foreground)
            self?.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            self?.applyDashes(ctx, dashes, dashOffset: dashOffset)
            // CGContext.stroke(rect) draws a 1-line-width-wide outline of
            // the rect using the current stroke color + line width.
            // PolyRectangle batches multiple rects in one request;
            // iterate and stroke each.
            for r in rectangles {
                ctx.stroke(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                  width: CGFloat(r.width), height: CGFloat(r.height)))
            }
        }
    }

    public func drawPolyFillRectangle(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        function: UInt8,
        fillStyle: UInt8,
        stipple: UInt32, tile: UInt32,
        stippleOriginX: Int16, stippleOriginY: Int16,
        rectangles: [Framer.Rectangle], clipRectangles: [Framer.Rectangle]?
    ) {
        if let r = rectangles.first {
            log?.log("  drawPolyFillRectangle target=\(target) fn=\(function) fillStyle=\(fillStyle) stipple=0x\(String(stipple, radix: 16)) stipOrig=(\(stippleOriginX),\(stippleOriginY)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) n=\(rectangles.count) first=(\(r.x),\(r.y),\(r.width)x\(r.height))")
        }

        // Stippled / opaque-stippled: rasterise the fill against the bit
        // pattern in the 1-bit stipple pixmap. Without this, Motif's
        // XmText caret (a tiny pixmap with an I-beam carved into a solid
        // block) renders as the solid block and obscures the character
        // under the cursor.
        if (fillStyle == 2 || fillStyle == 3), stipple != 0,
           let stippleBuf = lookupPixmapBuffer(stipple),
           let stippleBitGrid = StippleBitGrid(buffer: stippleBuf) {
            let opaque = (fillStyle == 3)
            withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
                self?.fillStippled(
                    ctx: ctx, rects: rectangles,
                    foreground: foreground, background: background,
                    opaque: opaque,
                    stipple: stippleBitGrid,
                    originX: Int(stippleOriginX), originY: Int(stippleOriginY),
                    function: function
                )
            }
            return
        }

        // FillTiled with function=GXand on a depth-1 destination. Motif's
        // XmScale builds the slider's value-indicator stipple by carving
        // an I-beam into a 5×13 depth-1 pixmap (PolySegment), then
        // ANDing it with a 16×16 checkerboard tile to produce a dotted
        // I-beam. Without honoring this, the carved I-beam stays solid
        // and the slider thumb visually reads as "pressed/etched" rather
        // than the raised dotted highlight Motif intends.
        //
        // dst' = dst AND tile (depth-1, BLACK=1=set, WHITE=0=clear):
        //   tile bit 1 (BLACK) → keep dst unchanged
        //   tile bit 0 (WHITE) → clear dst to WHITE
        // So we only need to paint white where the tile is clear.
        if fillStyle == 1, function == 1, tile != 0,
           case .pixmap(_, let dstDepth) = target, dstDepth == 1,
           let tileBuf = lookupPixmapBuffer(tile),
           let tileBitGrid = StippleBitGrid(buffer: tileBuf) {
            withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
                self?.fillTiledAndDepth1(
                    ctx: ctx, rects: rectangles,
                    tile: tileBitGrid,
                    originX: Int(stippleOriginX), originY: Int(stippleOriginY)
                )
            }
            return
        }

        // True pixel-value XOR for GXxor on depth-8 destinations. dtterm's
        // text cursor uses `cursorGC.foreground = fg ^ bg` (pixel-value
        // XOR) drawn with function=GXxor — relying on the server to do
        // per-pixel index-space XOR so the cursor visibly inverts the
        // cells under it. Our default CGBlendMode.difference is RGB-space
        // and produces invisible cursors when src and dst RGB match
        // (black-on-black, e.g. with our dtterm bg=Black + fg=White
        // setup). The path below reads each device pixel, reverse-maps
        // its ARGB to an X pixel index via ColorTable, XORs in pixel-value
        // space, forward-maps the result back to ARGB, and writes. Falls
        // back to .difference for tests without a ColorTable or when the
        // GXxor case doesn't apply.
        if function == 6, let colorTable = lookupColorTable() {
            let srcRGB = foreground
            // Reverse-map the source RGB to its pixel index. dtterm sets
            // cursorGC.foreground to a pure pixel index (no AllocColor),
            // so the value should always be in our table for the pixels
            // dtterm actually uses (0 and 1).
            let srcPixel = colorTable.pixel(for: srcRGB) ?? 0
            let scale = max(1, Int(self.scaleFactor.rounded()))
            withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
                self?.fillGXxorPixelValue(
                    ctx: ctx, rects: rectangles,
                    srcPixel: srcPixel, colorTable: colorTable,
                    scale: scale
                )
            }
            return
        }

        withDrawContext(target, clipRectangles: clipRectangles) { ctx in
            // GXxor fallback (no ColorTable available, e.g., tests): use
            // CG difference blend. Correct only for binary-color pairs;
            // dtterm's cursor relies on pixel-XOR semantics and needs the
            // path above. Function 3 (GXcopy) is the spec default —
            // overwrite.
            if function == 6 {
                ctx.setBlendMode(.difference)
            }
            applyFill(ctx, foreground)
            for r in rectangles {
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
        }
    }

    /// True pixel-value XOR fill for a depth-8 destination. Walks every
    /// device pixel inside each rect, reads its stored ARGB, reverse-maps
    /// to an X pixel index via ColorTable, XORs with srcPixel, forward-
    /// maps the result to an ARGB, and writes it back. Unallocated
    /// destination pixels (AA edges that don't round-trip cleanly) fall
    /// back to pixel 0 (white) for the reverse map. Unallocated result
    /// pixels (XOR landing in an unallocated slot) render as black —
    /// X spec lets us pick since the colormap entry is undefined.
    ///
    /// Built for dtterm's invert-cell cursor (a single small rect per
    /// blink), so per-device-pixel work is fine.
    private func fillGXxorPixelValue(
        ctx: CGContext,
        rects: [Framer.Rectangle],
        srcPixel: UInt32,
        colorTable: ColorTable,
        scale: Int
    ) {
        guard let raw = ctx.data else { return }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let ctxW = ctx.width
        let ctxH = ctx.height

        for r in rects {
            let x0 = max(0, Int(r.x) * scale)
            let y0 = max(0, Int(r.y) * scale)
            let x1 = min(ctxW, (Int(r.x) + Int(r.width)) * scale)
            let y1 = min(ctxH, (Int(r.y) + Int(r.height)) * scale)
            for dy in y0..<y1 {
                let rowBase = dy * bpr
                for dx in x0..<x1 {
                    let off = rowBase + dx * 4
                    // BGRA in memory: [B][G][R][A]. Build RGB16 by byte
                    // replication so the ColorTable lookup matches the
                    // form ColorTable.pin stored.
                    let b = bytes[off]
                    let g = bytes[off + 1]
                    let r2 = bytes[off + 2]
                    let dstRGB = RGB16(
                        red:   UInt16(r2) << 8 | UInt16(r2),
                        green: UInt16(g)  << 8 | UInt16(g),
                        blue:  UInt16(b)  << 8 | UInt16(b)
                    )
                    let dstPixel = colorTable.pixel(for: dstRGB) ?? 0
                    let outPixel = dstPixel ^ srcPixel
                    let outRGB = colorTable.rgb(for: outPixel) ?? RGB16(red: 0, green: 0, blue: 0)
                    bytes[off]     = UInt8(outRGB.blue  >> 8)
                    bytes[off + 1] = UInt8(outRGB.green >> 8)
                    bytes[off + 2] = UInt8(outRGB.red   >> 8)
                    // Leave alpha alone — keeps premultiplied invariant.
                }
            }
        }
    }

    /// FillTiled + GXand on a depth-1 destination. Treats both pixmaps as
    /// bitmaps (BLACK=1=set, WHITE=0=clear, the X11 paper/ink convention
    /// we mirror in storage) and writes WHITE to every dst pixel where the
    /// tile is clear; bits where the tile is set stay unchanged. That's
    /// exactly `dst AND tile` for binary values. Built for Motif's
    /// XmScale slider-stipple construction (5×13 dst, 16×16 tile) — tiny
    /// inputs, run-length write the white spans so we're not making one
    /// fill call per pixel.
    private func fillTiledAndDepth1(
        ctx: CGContext, rects: [Framer.Rectangle],
        tile: StippleBitGrid,
        originX: Int, originY: Int
    ) {
        let tw = tile.width
        let th = tile.height
        let bits = tile.bits

        @inline(__always) func tileBit(_ x: Int, _ y: Int) -> Bool {
            let tx = ((x - originX) % tw + tw) % tw
            let ty = ((y - originY) % th + th) % th
            return bits[ty * tw + tx]
        }

        // White = pixel value 0 = clear bit, matching PixelBuffer/StippleBitGrid.
        applyFill(ctx, RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
        for r in rects {
            let x0 = Int(r.x), x1 = Int(r.x) + Int(r.width)
            let y0 = Int(r.y), y1 = Int(r.y) + Int(r.height)
            for y in y0..<y1 {
                var x = x0
                while x < x1 {
                    if !tileBit(x, y) {
                        // Run-length the contiguous "tile clear" span.
                        let start = x
                        x += 1
                        while x < x1, !tileBit(x, y) { x += 1 }
                        ctx.fill(CGRect(x: CGFloat(start), y: CGFloat(y),
                                        width: CGFloat(x - start), height: 1))
                    } else {
                        x += 1
                    }
                }
            }
        }
    }

    /// Sendable snapshot of a stipple pixmap's bit pattern, lifted out
    /// of `PixelBuffer` (which can't cross @Sendable closure boundaries
    /// because CGContext isn't Sendable) before drawing begins. Cheap:
    /// stipples are small (Motif's caret is 5×14 = 70 bytes copied).
    private struct StippleBitGrid: Sendable {
        let width: Int
        let height: Int
        let bits: [Bool]      // row-major; bits[y*width + x]
        init?(buffer: PixelBuffer) {
            let w = buffer.width
            let h = buffer.height
            guard w > 0, h > 0, let raw = buffer.context.data else { return nil }
            let bpr = buffer.context.bytesPerRow
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            var bits = [Bool](repeating: false, count: w * h)
            // ARGB premultipliedFirst + byteOrder32Little = BGRA in
            // memory. For a depth-1 stipple, a SET bit (pixel value 1)
            // = blackPixel = RGB(0,0,0) in our 32-bit storage; a CLEAR
            // bit (pixel value 0) = whitePixel = RGB(255,255,255). This
            // is the X11 paper/ink convention also reflected in our
            // ServerConfig (whitePixel=0, blackPixel=1, matching real
            // u5 Xsun). Motif builds caret stipples by filling white
            // (= clear) and then drawing the I-beam with PolySegment in
            // black (= set), so the carved line shape is what gets
            // painted by FillStippled.
            //
            // Pixmaps store at the bridge's device scale (see
            // PixelBuffer.scaleFactor), so each logical pixel covers a
            // scale×scale block of device pixels. We sample the centre
            // of each block; for the 1-logical-pixel-wide I-beam strokes
            // Motif carves, the centre device pixel always falls within
            // the rasterised line, so the resulting bit pattern matches
            // the logical I-beam shape.
            let scale = max(1, Int(buffer.scaleFactor.rounded()))
            let centerOffset = scale / 2
            for y in 0..<h {
                let deviceRow = y * scale + centerOffset
                let rowBase = deviceRow * bpr
                for x in 0..<w {
                    let deviceCol = x * scale + centerOffset
                    bits[y * w + x] = bytes[rowBase + deviceCol * 4 + 2] == 0
                }
            }
            self.width = w
            self.height = h
            self.bits = bits
        }
    }

    /// Rasterise a stippled fill: for each destination pixel inside
    /// `rects`, look up the corresponding stipple bit (with toroidal
    /// tiling from `originX, originY`). Set bits paint `foreground`;
    /// clear bits leave the destination alone (FillStippled) or paint
    /// `background` (FillOpaqueStippled). Built for small stipples
    /// (Motif's text caret is 5×14); fine for those, slow if anything
    /// ever asks us to stipple-fill a window-sized rect — revisit when
    /// that case shows up.
    private func fillStippled(
        ctx: CGContext, rects: [Framer.Rectangle],
        foreground: RGB16, background: RGB16,
        opaque: Bool,
        stipple: StippleBitGrid,
        originX: Int, originY: Int,
        function: UInt8
    ) {
        let sw = stipple.width
        let sh = stipple.height
        let bits = stipple.bits

        @inline(__always) func stippleBit(_ x: Int, _ y: Int) -> Bool {
            let sx = ((x - originX) % sw + sw) % sw
            let sy = ((y - originY) % sh + sh) % sh
            return bits[sy * sw + sx]
        }

        if function == 6 {  // GXxor
            ctx.setBlendMode(.difference)
        }

        for r in rects {
            let x0 = Int(r.x), x1 = Int(r.x) + Int(r.width)
            let y0 = Int(r.y), y1 = Int(r.y) + Int(r.height)
            for y in y0..<y1 {
                var runStart = x0
                var runForeground = stippleBit(x0, y)
                for x in (x0 + 1)...x1 {
                    let set = (x < x1) ? stippleBit(x, y) : !runForeground
                    if set != runForeground {
                        if runForeground || opaque {
                            applyFill(ctx, runForeground ? foreground : background)
                            ctx.fill(CGRect(x: CGFloat(runStart), y: CGFloat(y),
                                            width: CGFloat(x - runStart), height: 1))
                        }
                        runStart = x
                        runForeground = set
                    }
                }
            }
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
    public func drawPolyArc(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, arcs: [Arc], clipRectangles: [Framer.Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {
        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyForeground(ctx, foreground)
            self?.applyStrokePlane(ctx, clientLineWidth: lineWidth)
            self?.applyDashes(ctx, dashes, dashOffset: dashOffset)
            for a in arcs {
                let path = ellipseArcPath(arc: a, includePieCenter: false)
                ctx.beginPath()
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
    }

    /// PolyFillArc: fill the pie slice (default arc-mode=PieSlice; chord mode
    /// is unhandled — see OPCODE_STATUS). Path moves to the ellipse center,
    /// out to the arc start, sweeps the arc, closes back to center.
    public func drawPolyFillArc(target: DrawTarget, foreground: RGB16, arcs: [Arc], clipRectangles: [Framer.Rectangle]?) {
        withDrawContext(target, clipRectangles: clipRectangles) { ctx in
            applyFill(ctx, foreground)
            for a in arcs {
                let path = ellipseArcPath(arc: a, includePieCenter: true)
                ctx.beginPath()
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }

    /// PutImage with format=Bitmap (depth-1 source). Builds a 32-bit ARGB
    /// CGImage from the bit-packed source — each 1-bit pixel → foreground
    /// color, each 0-bit → background — and draws it into the target via
    /// withDrawContext.
    ///
    /// Source-data layout per our SetupAccepted (ServerConfig):
    ///   bitmapFormatBitOrder = mostSignificant — MSB-first within each byte
    ///   bitmapFormatScanlinePad = 32 — each scanline padded to 32-bit boundary
    ///   leftPad — bits of pad at the start of each scanline (before image bits)
    ///
    /// Used by quickplot's icon-button bitmap path (XCreatePixmapFromBitmapData
    /// → XPutImage format=Bitmap into a depth-N pixmap, then XCopyArea pixmap
    /// → button window). Without this, button bitmaps don't display.
    public func drawPutImage(
        target: DrawTarget,
        sourceData: [UInt8],
        sourceWidth: UInt16, sourceHeight: UInt16,
        dstX: Int16, dstY: Int16,
        leftPad: UInt8,
        foreground: RGB16, background: RGB16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        log?.log("  drawPutImage target=\(target) src=\(sourceWidth)x\(sourceHeight) dst=(\(dstX),\(dstY)) leftPad=\(leftPad) data=\(sourceData.count)b fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) bg=(\(background.red >> 8),\(background.green >> 8),\(background.blue >> 8))")

        let w = Int(sourceWidth), h = Int(sourceHeight)
        guard w > 0, h > 0 else { return }
        let pad = Int(leftPad)

        // scanline width in bits, padded up to the 32-bit unit boundary.
        // Each scanline carries (leftPad + width) image bits plus the
        // trailing pad bits to reach a multiple of 32.
        let scanlineBits = ((pad + w + 31) / 32) * 32
        let scanlineBytes = scanlineBits / 8
        guard sourceData.count >= scanlineBytes * h else {
            log?.log("    short-data: have \(sourceData.count)b, need \(scanlineBytes * h)b — drop")
            return
        }

        // Pre-shift RGB16 (0..65535) → UInt8 (0..255). bitmapInfo on our
        // PixelBuffer is byteOrder32Little + premultipliedFirst, which lays
        // bytes out as B, G, R, A in memory.
        let fgR = UInt8(foreground.red   >> 8)
        let fgG = UInt8(foreground.green >> 8)
        let fgB = UInt8(foreground.blue  >> 8)
        let bgR = UInt8(background.red   >> 8)
        let bgG = UInt8(background.green >> 8)
        let bgB = UInt8(background.blue  >> 8)

        var argb = [UInt8](repeating: 0, count: w * h * 4)
        argb.withUnsafeMutableBufferPointer { dst in
            sourceData.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    let scanlineStart = y * scanlineBytes
                    for x in 0..<w {
                        let bitIndex = pad + x
                        let byteOffset = scanlineStart + bitIndex / 8
                        let bitInByte = 7 - (bitIndex % 8)   // MSB-first
                        let bit = (src[byteOffset] >> bitInByte) & 1
                        let i = (y * w + x) * 4
                        if bit == 1 {
                            dst[i + 0] = fgB
                            dst[i + 1] = fgG
                            dst[i + 2] = fgR
                            dst[i + 3] = 255
                        } else {
                            dst[i + 0] = bgB
                            dst[i + 1] = bgG
                            dst[i + 2] = bgR
                            dst[i + 3] = 255
                        }
                    }
                }
            }
        }

        blitARGB(argb, width: w, height: h,
                 dstX: dstX, dstY: dstY,
                 target: target, clipRectangles: clipRectangles)
    }

    /// ZPixmap PutImage. Session pre-resolves the packed-pixel source
    /// (depth=1 or depth=8) through ColorTable into row-major BGRA bytes
    /// matching PixelBuffer's layout (byteOrder32Little + premultipliedFirst).
    /// Bridge just blits via the same CGImage + withDrawContext path as
    /// the Bitmap variant. ZPixmap depth=8 is what motifbur uses for its
    /// 24x20 menu icons; depth=1 is what viewres/xgas/xgc use for 6x3 and
    /// 16x16 button glyphs. Pre-2026-06-01 both were silent-dropped.
    public func drawPutImageARGB(
        target: DrawTarget,
        argb: [UInt8],
        width: UInt16, height: UInt16,
        dstX: Int16, dstY: Int16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0 else { return }
        guard argb.count == w * h * 4 else {
            log?.log("  drawPutImageARGB: argb count mismatch (have \(argb.count)b, need \(w * h * 4)b) — drop")
            return
        }
        log?.log("  drawPutImageARGB target=\(target) src=\(width)x\(height) dst=(\(dstX),\(dstY)) data=\(argb.count)b")
        blitARGB(argb, width: w, height: h,
                 dstX: dstX, dstY: dstY,
                 target: target, clipRectangles: clipRectangles)
    }

    /// Shared blit tail for both `drawPutImage` (Bitmap) and `drawPutImageARGB`
    /// (ZPixmap). Wraps the ARGB buffer in a CGImage and draws it into the
    /// destination through `withDrawContext`, which handles clipping + the
    /// y-flip dance documented in GRAPHICS_Y_FLIP.md. Nearest-neighbor
    /// interpolation keeps small icons crisp through device-scale upscaling.
    private func blitARGB(_ argb: [UInt8], width w: Int, height h: Int,
                           dstX: Int16, dstY: Int16,
                           target: DrawTarget,
                           clipRectangles: [Framer.Rectangle]?) {
        let data = Data(argb)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cgImage = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        let dstRect = CGRect(
            x: CGFloat(dstX), y: CGFloat(dstY),
            width: CGFloat(w), height: CGFloat(h)
        )
        withDrawContext(target, clipRectangles: clipRectangles) { ctx in
            ctx.interpolationQuality = .none
            ctx.drawImageRespectingYFlip(cgImage, in: dstRect)
        }
    }

    public func drawImageText8(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        let printable = String(decoding: string.prefix(40), as: UTF8.self)
        log?.log("  drawImageText8 target=\(target) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) str=\"\(printable)\" len=\(string.count)")

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

        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
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

            guard let ctFont = self?.ctFont(for: font) else { return }

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
        }
    }

    public func drawPolyText8(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        // Decode preview: TEXTITEM8 = length(1) + delta(1) + chars... runs.
        var preview: [UInt8] = []
        var pi = 0
        while pi < items.count && preview.count < 32 {
            let nb = items[pi]
            if nb == 0xFF { pi += 5; continue }
            let nn = Int(nb)
            if nn == 0 { pi += 1; continue }
            guard pi + 2 + nn <= items.count else { break }
            for k in 0..<nn { preview.append(items[pi + 2 + k]) }
            pi += 2 + nn
        }
        let pstr = String(decoding: preview, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
        let clipDesc: String = {
            guard let rs = clipRectangles else { return "nil" }
            if rs.isEmpty { return "EMPTY (no draws)" }
            return rs.map { "(\($0.x),\($0.y),\($0.width)x\($0.height))" }.joined(separator: ",")
        }()
        log?.log("  drawPolyText8 target=\(target) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) mono=\(font.isMonospace) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) clip=\(clipDesc) str=\"\(pstr)\"")

        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
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
            // Positions come from FontResolver.integerAdvances — the same
            // path that fills CHARINFO.characterWidth and answers
            // QueryTextExtents. The MOTIF_TEXT_QUALITY invariant: reported
            // advance === rendered advance, every glyph, integer pixels.
            // Motif positions runs by summing CHARINFO; we draw at exactly
            // those positions, no Core Text natural-advance drift.
            let baseX = Int(x)
            var penX: Int = baseX
            let baseY = Int(y)

            guard let ctFont = self?.ctFont(for: font) else { return }

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
                penX += Int(delta)

                var unichars = [UniChar](repeating: 0, count: n)
                for j in 0..<n { unichars[j] = UniChar(items[i + 2 + j]) }

                let (glyphsImm, advances) = FontResolver.integerAdvances(font, characters: unichars)
                var glyphs = glyphsImm

                var positions = [CGPoint](repeating: .zero, count: n)
                var localX: Int = 0
                for j in 0..<n {
                    positions[j] = CGPoint(x: CGFloat(localX), y: 0)
                    localX += advances[j]
                }
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(penX), y: CGFloat(baseY))
                ctx.scaleBy(x: 1, y: -1)
                CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)
                ctx.restoreGState()

                penX += localX
                i += 2 + n
            }
        }
    }

    public func drawImageText16(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        characters: [UInt16],
        clipRectangles: [Framer.Rectangle]?
    ) {
        let n = characters.count
        log?.log("  drawImageText16 target=\(target) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) nChars=\(n)")

        // Per X11 ImageText16 spec: fill bg rect under the text first, then
        // draw glyphs. Same cell-snapped bg-rect math as ImageText8 — the
        // cell width is constant for monospaced fonts. Apps using CHAR2B
        // typically want CJK fonts where the visual cell is double-width;
        // for x11perf benchmarking the resolved font's cellWidth is whatever
        // FontResolver picked (fallback to "fixed" if k14/k24 wasn't named)
        // and that's what we measure throughput against.
        let cellW = font.cellWidth
        let bgRect = CGRect(
            x: CGFloat(x),
            y: CGFloat(Int(y) - font.ascent),
            width: CGFloat(cellW * n),
            height: CGFloat(font.cellHeight)
        )

        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyFill(ctx, background)
            ctx.fill(bgRect)

            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            ctx.scaleBy(x: 1, y: -1)

            guard let ctFont = self?.ctFont(for: font) else { return }

            // Each CHAR2B already decoded to UniChar = row<<8 | column by the
            // framer. CoreText's missing-glyph substitution handles codepoints
            // the Mac font doesn't cover (rendered as .notdef rectangles).
            var unichars = characters
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

            var positions = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                positions[i] = CGPoint(x: CGFloat(i * cellW), y: 0)
            }

            CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)
        }
    }

    public func drawPolyText16(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        // TEXTITEM16 layout: 0xFF marks a 5-byte font shift (sentinel + 4-byte
        // FontID, ignored — we use the GC's font for the whole request like
        // PolyText8). Otherwise: length(1, CHAR2B count) + delta(INT8) +
        // 2*length bytes (CHAR2B big-endian).
        log?.log("  drawPolyText16 target=\(target) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) itemsBytes=\(items.count)")

        withDrawContext(target, clipRectangles: clipRectangles) { [weak self] ctx in
            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            let baseX = Int(x)
            var penX: Int = baseX
            let baseY = Int(y)

            guard let ctFont = self?.ctFont(for: font) else { return }

            var i = 0
            while i < items.count {
                let b = items[i]
                if b == 0xFF {
                    i += 5
                    continue
                }
                let n = Int(b)   // CHAR2B count
                if n == 0 { i += 1; continue }
                let charBytes = n * 2
                guard i + 2 + charBytes <= items.count else { break }
                let delta = Int8(bitPattern: items[i + 1])
                penX += Int(delta)

                var unichars = [UniChar](repeating: 0, count: n)
                for j in 0..<n {
                    let hi = UInt16(items[i + 2 + j * 2])
                    let lo = UInt16(items[i + 2 + j * 2 + 1])
                    unichars[j] = (hi << 8) | lo
                }

                let (glyphsImm, advances) = FontResolver.integerAdvances(font, characters: unichars)
                var glyphs = glyphsImm

                var positions = [CGPoint](repeating: .zero, count: n)
                var localX: Int = 0
                for j in 0..<n {
                    positions[j] = CGPoint(x: CGFloat(localX), y: 0)
                    localX += advances[j]
                }
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(penX), y: CGFloat(baseY))
                ctx.scaleBy(x: 1, y: -1)
                CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)
                ctx.restoreGState()

                penX += localX
                i += 2 + charBytes
            }
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

    public func setWindowBoundingShape(topLevel: UInt32, rects: [Framer.Rectangle]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let slot = self.slot(topLevel) else { return }
            // `rects` is device-coord post-DEVICE_COORDS_REFACTOR; the view's
            // clip-path build divides by backingScale to map to points.
            slot.view?.boundingShapeRects = rects
            // Motif-frame clone: tell the frame view to draw mwm-style (title
            // bar only) when the client is shaped, matching SetFrameShape.
            if let motif = slot.window as? MotifWindow {
                motif.frameView.clientIsShaped = (rects != nil)
            }
            guard let win = slot.window else { return }
            if rects != nil {
                win.isOpaque = false
                win.backgroundColor = .clear
            } else {
                win.isOpaque = true
            }
            slot.view?.needsDisplay = true
        }
    }

    public func readDepth1MaskDevicePixels(pixmapId: UInt32) -> (pixels: [UInt32], width: Int, height: Int)? {
        guard let buf = lookupPixmapBuffer(pixmapId), let data = buf.context.data else { return nil }
        let w = buf.context.width, h = buf.context.height       // device pixels
        guard w > 0, h > 0 else { return nil }
        let bpr = buf.context.bytesPerRow
        let base = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            for x in 0..<w {
                out[y * w + x] = row.advanced(by: x * 4)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }
        }
        return (out, w, h)
    }

    public func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            // Window-bg paint rects are now in device coords
            // (DEVICE_COORDS_REFACTOR.md). Fill under identity CTM so each
            // rect lands at exact device pixels rather than going through
            // CTM scaling. The save/restore symmetry keeps the CTM intact
            // for any subsequent ops on this context.
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.interpolationQuality = .none
            let savedCTM = ctx.ctm
            ctx.concatenate(savedCTM.inverted())
            for r in rects {
                applyFill(ctx, r.color)
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// (2026-05-25) Reverted. Caused widget bg colors to bleed into
    /// adjacent siblings' regions in quickplot during resize. The
    /// snapshot/paint/blit logic is plausibly correct on paper but
    /// interacts with our clipList / paintRectsForWindow output in some
    /// way that paints past the moved widget's actual visible extent.
    /// Keep the implementation around (rather than fully delete) so we
    /// can re-enable behind a config flag once we've capture-diffed the
    /// bleed source.
    private func _unused_blitWindowRegion(
        topLevel: UInt32,
        fromX: Int32, fromY: Int32,
        width: UInt32, height: UInt32,
        toX: Int32, toY: Int32,
        fallbackBgRects: [WindowBackgroundRect]
    ) {
        guard width > 0, height > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view,
                  let ctx = view.backing else { return }

            // Step 1: snapshot BEFORE any paint, so the source read sees
            // the bitmap's prior state. CGImage retains its pixel data via
            // copy-on-write against the bitmap storage; subsequent writes
            // to ctx don't affect the snapshot.
            let snapshot: CGImage? = ctx.makeImage()

            // Step 2: paint fallback bg rects. Same code shape as
            // paintWindowRects (clip-respecting), keyed off the widget's
            // bg+border colors the session computed via paintRectsForWindow.
            self.withClip(ctx, nil) {
                for r in fallbackBgRects {
                    applyFill(ctx, r.color)
                    ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                    width: CGFloat(r.width), height: CGFloat(r.height)))
                }
            }

            // Step 3: blit from snapshot. Source rect in DEVICE pixels (the
            // snapshot is the raw device-pixel buffer; the ctx CTM doesn't
            // affect it). Dest is in X-logical coords; the ctx CTM handles
            // logical → device on the draw call.
            if let snapshot = snapshot {
                let scale = view.scaleFactor
                let bw = view.backingWidth
                let bh = view.backingHeight
                let srcDevX = Int((Double(fromX) * scale).rounded())
                let srcDevY_top = Int((Double(fromY) * scale).rounded())
                let srcDevW = Int((Double(width) * scale).rounded())
                let srcDevH = Int((Double(height) * scale).rounded())
                // CGImage uses y-up coords (origin bottom-left). The bitmap
                // stores row-0 at the BOTTOM in raw memory, but the X
                // server's CTM y-flips so logical-y=0 means visual-top
                // (high device-y). Convert: source's visual-top row at
                // device-y = bh - srcDevY_top - srcDevH (i.e. the CGImage
                // row range that holds the widget content).
                let srcCGY = bh - srcDevY_top - srcDevH
                // Intersect with image bounds. cropping(to:) requires its
                // rect to be inside [0,bw]×[0,bh]; out-of-bounds returns
                // nil, no draw, fallback bg-paint stands. Partially in-
                // bounds clips to the visible portion.
                let clampedX = max(0, srcDevX)
                let clampedY = max(0, srcCGY)
                let clampedW = min(srcDevW, bw - clampedX)
                let clampedH = min(srcDevH, bh - clampedY)
                if clampedW > 0, clampedH > 0,
                   let sub = snapshot.cropping(to: CGRect(
                       x: clampedX, y: clampedY,
                       width: clampedW, height: clampedH)) {
                    // Compute the dest rect aligned with the clipped source.
                    // If we had to clamp the source on the left/top, the
                    // dest shifts by the same logical amount so the
                    // visible portion lands at the right place. The visual
                    // top-edge of the source maps to the visual top-edge
                    // of the dest at toY; if we clamped top by `clampDy`
                    // device pixels (clampedY > srcCGY), then we lost
                    // `clampDy / scale` logical pixels from the top of
                    // the source, and the dest top shifts down by the
                    // same amount.
                    let lostTopDev = clampedY - srcCGY  // device pixels lost off the top
                    let lostLeftDev = clampedX - srcDevX
                    let dstX = CGFloat(toX) + CGFloat(lostLeftDev) / CGFloat(scale)
                    // For top clamping: top device rows lost means dest's
                    // visual top shifts down (in logical coords).
                    // But also: if the original srcCGY was negative (source
                    // visual top below the bitmap), we've already lost
                    // those rows; the bottom of the visible portion lands
                    // at toY + height, which is unaffected. Hmm — need to
                    // think about top vs bottom clamping.
                    //
                    // Simplification: when both source and dest are
                    // entirely within bitmap bounds (the common case),
                    // lostTopDev = lostLeftDev = 0 and dstX/dstY are just
                    // (toX, toY). For partial clamping the math gets
                    // fiddlier; do the simple case first and accept that
                    // partial clamping might mis-align by a few pixels.
                    // The dominant cases (dtpad full in-bounds, quickplot
                    // full out-of-bounds) both land cleanly.
                    let dstY = CGFloat(toY) + CGFloat(lostTopDev) / CGFloat(scale)
                    let dstW = CGFloat(clampedW) / CGFloat(scale)
                    let dstH = CGFloat(clampedH) / CGFloat(scale)
                    ctx.saveGState()
                    ctx.draw(sub, in: CGRect(x: dstX, y: dstY, width: dstW, height: dstH))
                    ctx.restoreGState()
                }
            }

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

    /// Called by the NSWindowDelegate after the user drags an NSWindow to a
    /// new screen position. Reverses the placement formula from createWindow
    /// (X-root → NSScreen with Y-flip and scale conversion) to recover the
    /// new X-root coords, then fires the session move handler so it can
    /// update WindowEntry.x/y and emit a synthetic ConfigureNotify per
    /// ICCCM 4.1.5. Without this, Motif's cached widget root coords stay at
    /// the original placement and menu popups land where the window used
    /// to be.
    ///
    /// Skips override-redirect popups — the X client positioned those itself
    /// via ConfigureWindow and we'd loop sending back a synthetic notify it
    /// doesn't expect. We don't currently let the user drag those either
    /// (panel level=popUpMenu, no title bar), so windowDidMove on them would
    /// only fire via programmatic AppKit repositioning we don't do.
    @MainActor
    fileprivate func handleNSWindowMove(id: UInt32) {
        guard let slot = slot(id), let win = slot.window else { return }
        guard !(win is NSPanel) else { return }   // override-redirect
        let backingScale = win.backingScaleFactor
        let screenH = NSScreen.main?.frame.size.height ?? 1080
        // Window's content-rect origin in NSScreen coords. NSWindow.frame
        // includes title bar; contentRect(forFrameRect:) strips it back to
        // the inner content area, matching what we passed at createWindow
        // time. Y-flip against main screen height to get X-root y.
        var contentRect = win.contentRect(forFrameRect: win.frame)
        if win is MotifWindow {
            // The NSWindow content rect wraps the X-client area on all four
            // sides; shrink back to the inner X-client area before reporting
            // root coords so cached widget positions match what we mapped.
            contentRect.origin.x += MotifTheme.current.clientLeftInset
            contentRect.origin.y += MotifTheme.current.clientBottomInset
            contentRect.size.width  -= MotifTheme.current.horizontalPadding
            contentRect.size.height -= MotifTheme.current.verticalPadding
        }
        let originX = contentRect.origin.x
        let originY = contentRect.origin.y
        let pointsH = contentRect.size.height
        let newRootX = Int((originX * backingScale / CGFloat(scaleFactor)).rounded())
        let newRootY = Int(((screenH - originY - pointsH) * backingScale / CGFloat(scaleFactor)).rounded())
        let clampedX = Int16(max(Int(Int16.min), min(Int(Int16.max), newRootX)))
        let clampedY = Int16(max(Int(Int16.min), min(Int(Int16.max), newRootY)))
        log?.log("  windowDidMove id=0x\(String(id, radix: 16)) NSScreen origin=(\(originX),\(originY))pt → X-root=(\(clampedX),\(clampedY))")
        fireMove(id: id, x: clampedX, y: clampedY)
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

    func windowDidMove(_ notification: Notification) {
        bridge?.handleNSWindowMove(id: windowId)
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
        let mods = event.modifierFlags.rawValue

        let target = findManagedWindow(at: screenPt)

        // Cross-window transition: emit EnterView/ExitView so the X server
        // can run its EnterNotify/LeaveNotify chains and menu items
        // un-highlight when the pointer leaves the popup. Exit coords are
        // the cursor's CURRENT screen position translated into the OLD
        // window's view-local space — matches Sun's behavior of reporting
        // Leave at the precise crossing point (same root pixel as the
        // corresponding Enter on the new window), not at the prior motion
        // event's coords. Motif's submenu safe-triangle uses these coords;
        // the prior-coord shortcut produced a visible "teleport" between
        // Leave and Enter that confused the algorithm.
        if let lastId = dragLastWindowId, target?.0 != lastId {
            let bs = NSScreen.main?.backingScaleFactor ?? 2.0
            let exitX: Int16
            let exitY: Int16
            if let oldSlot = slot(lastId),
               let oldView = oldSlot.view,
               let oldWin = oldView.window {
                let oldWindowPt = NSPoint(
                    x: screenPt.x - oldWin.frame.origin.x,
                    y: screenPt.y - oldWin.frame.origin.y
                )
                let oldViewPt = oldView.convert(oldWindowPt, from: nil)
                exitX = Int16(clamping: Int((oldViewPt.x * bs / CGFloat(scaleFactor)).rounded()))
                exitY = Int16(clamping: Int((oldViewPt.y * bs / CGFloat(scaleFactor)).rounded()))
            } else {
                exitX = 0; exitY = 0     // old slot gone (rare race); fall through
            }
            firePointerExitedView(id: lastId, x: exitX, y: exitY, mods: mods)
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
            // ratio so 1 X-logical pixel maps consistently. Round-to-nearest
            // (not truncate) so subpixel cursor motion crosses each logical-
            // pixel boundary at the midpoint, matching the FlippedXView path
            // and a real X server's convention. See logicalLocation in
            // FlippedXView for the full rationale (Motif safe-triangle).
            let bs = NSScreen.main?.backingScaleFactor ?? 2.0
            let logicalX = Int16(clamping: Int((viewPt.x * bs / CGFloat(scaleFactor)).rounded()))
            let logicalY = Int16(clamping: Int((viewPt.y * bs / CGFloat(scaleFactor)).rounded()))

            let crossed = (dragLastWindowId != xid)
            if crossed {
                firePointerEnteredView(id: xid, x: logicalX, y: logicalY, mods: mods)
            }
            dragLastWindowId = xid

            if isUp {
                // Button-up always fires regardless of crossing (the press
                // started a grab, the release ends it; clients depend on
                // seeing the Release at the cursor's actual position).
                fireMouse(id: xid, x: logicalX, y: logicalY, button: button, isDown: false, mods: mods)
            } else if !crossed {
                // Within-window drag: emit Motion at the new coords as usual.
                // At a boundary crossing, the Enter we just fired already
                // conveys the new position; emitting a Motion at the same
                // coords looks to Motif's submenu state machine like
                // "cursor entered submenu but didn't actually move into
                // it" and the submenu dismisses. Sun's X server only emits
                // Enter at the boundary, with the next Motion coming when
                // the cursor truly moves further. Match that.
                fireMouseDragged(id: xid, x: logicalX, y: logicalY, button: button, mods: mods)
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
    ///
    /// Sort key, three levels:
    ///   1. NSWindow.level descending — popups at .popUpMenu beat regular
    ///      .normal windows when overlapping.
    ///   2. isKeyWindow first — at a given level, the focused window wins
    ///      over its peers. This is the principle: "the focus window gets
    ///      the action." Solves the same case orderedIndex did (the key
    ///      window is usually the visually-frontmost), and degrades
    ///      gracefully if z-order and focus ever diverge (e.g. a future
    ///      floating-panel widget).
    ///   3. NSWindow.orderedIndex ascending — fallback for the case where
    ///      neither candidate is key (rare; happens during transient
    ///      AppKit reorderings).
    /// Returns the X-id + FlippedXView for coordinate translation.
    private func findManagedWindow(at screenPt: NSPoint) -> (UInt32, FlippedXView)? {
        lock.lock()
        let snap = slots
        lock.unlock()
        let sorted = snap.sorted { lhs, rhs in
            let lvLeft = lhs.value.window?.level.rawValue ?? 0
            let lvRight = rhs.value.window?.level.rawValue ?? 0
            if lvLeft != lvRight { return lvLeft > lvRight }
            let keyLeft = lhs.value.window?.isKeyWindow ?? false
            let keyRight = rhs.value.window?.isKeyWindow ?? false
            if keyLeft != keyRight { return keyLeft }   // key first
            let zLeft = lhs.value.window?.orderedIndex ?? Int.max
            let zRight = rhs.value.window?.orderedIndex ?? Int.max
            return zLeft < zRight
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
///
/// Y-flip note: we draw into a FlippedXView, so screen-y increases DOWNWARD.
/// To keep angle1=π/2 visually "north" and positive angle2 visually CCW per
/// X spec, the sin term is subtracted from cy (not added). Mathematical
/// y-up math here would draw upside-down on screen.
internal func ellipseArcPath(arc a: Arc, includePieCenter: Bool) -> CGPath {
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
        path.addLine(to: CGPoint(x: cx + rx * cos(start), y: cy - ry * sin(start)))
    }
    for i in 0...steps {
        let t = start + extent * CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: cx + rx * cos(t), y: cy - ry * sin(t))
        if includePieCenter || i > 0 {
            path.addLine(to: p)
        } else {
            path.move(to: p)
        }
    }
    if includePieCenter { path.closeSubpath() }
    return path
}

/// Pull `width × height` logical pixels out of a CGBitmapContext stored at
/// `scale` device-pixels-per-logical, starting at logical (originX, originY)
/// and writing into `out` row-major. The bitmap is BGRA in memory
/// (CGBitmapContext with byteOrder32Little + premultipliedFirst). Logical
/// pixels outside the context's device bounds emit 0 — same as the spec's
/// "result is undefined for areas outside the drawable" but in practice the
/// caller validates the rect first.
func sampleBGRA(
    data: UnsafeMutableRawPointer,
    bytesPerRow: Int,
    contextWidth: Int,
    contextHeight: Int,
    originX: Int, originY: Int,
    width: Int, height: Int,
    scale: Double,
    out: inout [UInt32]
) {
    let base = data.assumingMemoryBound(to: UInt8.self)
    let scaleInt: Int
    let scaleIsInteger = scale == scale.rounded() && scale >= 1
    if scaleIsInteger {
        scaleInt = Int(scale)
    } else {
        scaleInt = 1   // fractional-scale fallback; uses rounded coord per pixel
    }
    for ly in 0..<height {
        let dy: Int
        if scaleIsInteger {
            dy = (originY + ly) * scaleInt
        } else {
            dy = Int((Double(originY + ly) * scale).rounded())
        }
        guard dy >= 0, dy < contextHeight else {
            for lx in 0..<width { out[ly * width + lx] = 0 }
            continue
        }
        let rowPtr = base.advanced(by: dy * bytesPerRow)
        for lx in 0..<width {
            let dx: Int
            if scaleIsInteger {
                dx = (originX + lx) * scaleInt
            } else {
                dx = Int((Double(originX + lx) * scale).rounded())
            }
            if dx < 0 || dx >= contextWidth {
                out[ly * width + lx] = 0
                continue
            }
            let p = rowPtr.advanced(by: dx * 4)
            // Load 4 bytes as a UInt32 (host byte order). Memory is BGRA;
            // on Apple Silicon (little-endian host) that becomes 0xAARRGGBB
            // when read as a UInt32. Callers extract via &0xFF shifts.
            out[ly * width + lx] = p.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        }
    }
}
