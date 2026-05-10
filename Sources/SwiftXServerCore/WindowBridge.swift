import Framer

// Platform-agnostic hooks for window lifecycle. The Cocoa implementation
// creates NSWindows on the main thread; the test implementation just records.
// The session calls these from the read thread; bridges that touch AppKit
// must dispatch to the main queue internally.

public struct TopLevelGeometry: Equatable, Sendable {
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public init(x: Int16, y: Int16, width: UInt16, height: UInt16, borderWidth: UInt16) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.borderWidth = borderWidth
    }
}

/// One line segment in PolySegment, in top-level pixel coordinates.
public struct LineSegment: Equatable, Sendable {
    public var x1: Int16
    public var y1: Int16
    public var x2: Int16
    public var y2: Int16
    public init(x1: Int16, y1: Int16, x2: Int16, y2: Int16) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }
}

/// One point in PolyLine / FillPoly, in top-level pixel coordinates.
public struct DrawPoint: Equatable, Sendable {
    public var x: Int16
    public var y: Int16
    public init(x: Int16, y: Int16) { self.x = x; self.y = y }
}

/// Snapshot of a descendant window the bridge needs when emitting events
/// after a top-level becomes viewable. Carries enough info to send
/// MapNotify and Expose to the right window.
public struct DescendantSnapshot: Equatable, Sendable {
    public var id: UInt32
    public var eventMask: UInt32
    public var width: UInt16
    public var height: UInt16
    public init(id: UInt32, eventMask: UInt32, width: UInt16, height: UInt16) {
        self.id = id; self.eventMask = eventMask
        self.width = width; self.height = height
    }
}

public protocol WindowBridge: AnyObject, Sendable {
    /// The client created a new top-level window (parent = root). The bridge
    /// records geometry; the actual NSWindow is created lazily on map.
    func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32)

    /// The client mapped a top-level window. The bridge brings the NSWindow
    /// on screen at the supplied current geometry (which may differ from
    /// what was registered at CreateWindow time — many clients create a
    /// top-level at 1×1 and ConfigureWindow it to its real size before
    /// mapping). It emits ReparentNotify / ConfigureNotify / MapNotify on
    /// the top-level, plus Expose on the top-level and each descendant whose
    /// event mask includes ExposureMask (the X11 spec's "newly viewable"
    /// rule). `eventMask` is the top-level's event mask; descendants is a
    /// snapshot of all already-mapped descendants of the top-level.
    func mapTopLevel(
        id: UInt32,
        geometry: TopLevelGeometry,
        eventMask: UInt32,
        descendants: [DescendantSnapshot],
        overrideRedirect: Bool,
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    )

    /// The client mapped a non-top-level descendant. We don't create anything
    /// new on screen but we still emit MapNotify + Expose if the descendant is
    /// already viewable (its top-level ancestor is mapped).
    func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue)

    /// The client unmapped a top-level window.
    func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue)

    /// The client destroyed a top-level window.
    func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue)

    /// WM_NAME or WM_ICON_NAME changed; bridge updates the NSWindow title.
    func setTopLevelTitle(id: UInt32, title: String)

    /// ConfigureWindow on a non-top-level window resized it. Bridge marks the
    /// affected drawing region dirty. Used in M3 for the post-resize redraw.
    func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry)

    /// M3 hook: a drawing request is about to write to `drawable` — bridge
    /// returns the CGContext / target. Default impl can be no-op for M2.
    func drawingTarget(for drawable: UInt32) -> Any?

    /// Called by the session at startup. The bridge stores the closure and
    /// invokes it whenever the user resizes a top-level NSWindow. Args:
    /// (top-level X window id, new width, new height). The session uses this
    /// to update its WindowTable and emit ConfigureNotify back to the client.
    /// Always invoked on the main thread.
    func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void)

    /// Called by the session at startup. The bridge stores the closure and
    /// invokes it on every keyDown / keyUp NSEvent in any of its NSWindows.
    /// Args: (top-level X window id, macOS virtual keyCode, raw modifierFlags,
    /// isDown). The session translates to an X KeyPress / KeyRelease event,
    /// resolves the key target via the X subtree, and queues the event.
    /// Always invoked on the main thread.
    func setOnKey(_ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void)

    /// Called by the session at startup. The bridge invokes this whenever an
    /// NSWindow becomes key (gained=true) or resigns key (gained=false). The
    /// session emits a FocusIn / FocusOut event to the X client. xterm uses
    /// this to switch its cursor between filled (focused) and hollow outline
    /// (unfocused). Args: (top-level X window id, gained).
    func setOnFocus(_ handler: @escaping @Sendable (UInt32, Bool) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseDown / mouseUp inside one of its NSWindows. Args: (top-level X
    /// window id, X-logical x, X-logical y in top-level coords, X button
    /// number 1..3, isDown). The session resolves which X subwindow should
    /// receive the event and emits ButtonPress / ButtonRelease.
    /// Always invoked on the main thread.
    func setOnMouse(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseDragged event (mouse moved while a button is held). Args:
    /// (top-level X window id, X-logical x, X-logical y in top-level coords,
    /// X button number 1..3 of the held button). The session emits
    /// MotionNotify so clients can track a drag — xterm needs this to
    /// render the inverse-video selection highlight as the user drags.
    /// Always invoked on the main thread.
    func setOnMouseDragged(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseMoved (pointer moved with NO button held). Args: (top-level X
    /// window id, X-logical x, X-logical y in top-level coords). The
    /// session tracks which X subwindow currently contains the pointer and
    /// emits EnterNotify / LeaveNotify when the containing window changes.
    /// Always invoked on the main thread. Mouse-with-button-held is
    /// `setOnMouseDragged` — the protocol distinguishes the two.
    func setOnPointerMoved(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the
    /// pointer crosses INTO an NSWindow's content area (from outside our
    /// X subtree entirely — e.g. mouse moves over the window from another
    /// app or from off-screen). Args: (top-level X window id, X-logical x,
    /// y in top-level coords). The session emits the EnterNotify chain
    /// from top-level down to the deepest window currently under the
    /// pointer.
    func setOnPointerEnteredView(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the
    /// pointer leaves an NSWindow's content area (mouse moves off the
    /// window edge or to another app). Args: (top-level X window id). The
    /// session emits the LeaveNotify chain from the current pointer
    /// window up to the top-level.
    func setOnPointerExitedView(_ handler: @escaping @Sendable (UInt32) -> Void)

    /// Called by the session at startup. Bridge invokes this when the user
    /// pastes (Cmd-V or Edit > Paste) into one of its NSWindows. Args:
    /// (top-level X window id, pasteboard text). The session synthesises
    /// a KeyPress/KeyRelease pair per character so the running X client
    /// receives the paste as typed input.
    func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void)

    /// Called by the session at startup. Bridge invokes this when the user
    /// asks to copy the X selection into the Mac clipboard (Cmd-C or
    /// Edit > Copy in one of our NSWindows). Args: (top-level X window id).
    /// The session looks up the current selection owner and runs the
    /// ConvertSelection roundtrip, eventually calling writeClipboard with
    /// the resulting text.
    func setOnCopy(_ handler: @escaping @Sendable (UInt32) -> Void)

    /// Push text to the Mac clipboard. Called from the session after a
    /// successful copy roundtrip — the bridge writes it to NSPasteboard.
    func writeClipboard(text: String)

    /// Called by the session at startup. The bridge invokes this when the
    /// user asks to close one of its NSWindows (red traffic-light button,
    /// Window > Close, ⌘W). The session sends the X client a polite
    /// `WM_DELETE_WINDOW` ClientMessage; well-behaved clients (xterm,
    /// xcalc, xclock, …) take that as their cue to exit. The NSWindow is
    /// closed by AppKit independently, so the visual feedback is immediate.
    /// Args: (top-level X window id).
    func setOnCloseRequest(_ handler: @escaping @Sendable (UInt32) -> Void)

    // MARK: - Drawing (M3)
    //
    // Coordinates are already translated to the top-level NSWindow's view
    // frame by the session before these are called.

    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment])
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint])
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool)
    /// PolyFillRectangle. `function` is the X GC drawing function — primarily
    /// 3 (GXcopy, overwrite) or 6 (GXxor, toggle). XOR is what Athena/Motif
    /// menu-item highlights use; non-XOR fills destroy text underneath.
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, function: UInt8, rectangles: [Rectangle])
    /// PolyRectangle: stroke the perimeter of each rect (vs PolyFillRectangle
    /// which fills). Used by Athena Command for the highlight border that
    /// appears when the pointer enters the widget.
    func drawPolyRectangle(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, rectangles: [Rectangle])
    /// PolyArc: stroke the outline of each elliptical arc. Each arc's bounding
    /// box is (x, y, width, height) in top-level coords, with angles in 64ths
    /// of a degree (angle1 = start, angle2 = extent; positive = counterclockwise).
    /// xclock uses this for the clock face; xeyes for eye outlines.
    func drawPolyArc(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, arcs: [Arc])
    /// PolyFillArc: fill the interior of each elliptical arc. Same arc geometry
    /// as drawPolyArc; the filled region is the pie slice from arc center
    /// (default arc-mode=PieSlice; chord mode unhandled per OPCODE_STATUS).
    /// xeyes fills the white sclera of each eye via this opcode.
    func drawPolyFillArc(topLevel: UInt32, foreground: RGB16, arcs: [Arc])
    func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16)
    /// In-window CopyArea: copies a rectangular region of pixels from
    /// (srcX, srcY, w, h) to (dstX, dstY, w, h) within the same top-level
    /// X window's backing context. Used by xterm for scrolling.
    func copyArea(
        topLevel: UInt32,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16
    )

    /// ImageText8: fill bg rect, then draw text. `(x, y)` is the baseline of
    /// the first glyph in top-level logical pixel coords. The bridge owns
    /// CTFont instantiation per the resolved font's macFontName + pointSize.
    func drawImageText8(
        topLevel: UInt32,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8]
    )

    /// PolyText8: draw glyphs without filling the cell background. `items` is
    /// the raw TEXTITEM8 stream from the X request (font-shift sentinel 0xFF
    /// followed by 4-byte FontID, OR 1-byte length + 1-byte signed delta +
    /// `length` glyph bytes). The bridge parses + renders. Used by Athena
    /// widget apps (xcalc) which never use ImageText8.
    func drawPolyText8(
        topLevel: UInt32,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8]
    )

    /// Paint a list of solid-color rects on the top-level's backing context.
    /// Used to honor X11 "newly viewable" semantics: when a window is mapped
    /// or exposed, the server fills its region with the configured background
    /// pixel BEFORE the client draws on top.
    func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect])

    /// Audible alert. Mapped to NSBeep. Called on Bell with positive
    /// percent (per spec, zero/negative percent requests a softer bell;
    /// macOS has no volume control so we just stay silent on those).
    func bell()

    /// Called by the session when an X-protocol pointer grab is installed
    /// (explicit GrabPointer, passive grab activation, or implicit grab on
    /// first ButtonPress). Lets the bridge install an NSEvent local monitor
    /// so drag/up events route to whichever NSWindow the pointer is over —
    /// not just the one where mouseDown originated. Without this, AppKit's
    /// drag-event-stickiness keeps menu drag-tracking confined to the origin
    /// NSWindow and the popup never sees pointer motion.
    /// Idempotent — multiple grabs nest safely; only the first call installs
    /// the monitor, subsequent calls are no-ops until matched stop.
    func startCrossWindowDragTracking()

    /// Called by the session when the X-protocol pointer grab releases.
    /// Removes the NSEvent monitor.
    func stopCrossWindowDragTracking()

    /// Push a cursor to display when the pointer is inside the given
    /// top-level NSWindow's content area. `glyph` is the X cursor-font
    /// source-char index (XC_xterm = 152, XC_left_ptr = 68, etc.) — the
    /// bridge maps it to an `NSCursor` per the substitution table. nil
    /// means "use the default" (macOS arrow). Called from the session on
    /// every pointer-window transition.
    func setCursor(topLevel: UInt32, glyph: UInt16?)

    /// Set the AppKit NSWindow's `backgroundColor` for a top-level X window.
    /// This is distinct from the X bg pixel (which paints into the backing
    /// bitmap): NSWindow.backgroundColor shows during live-resize before our
    /// next draw cycle runs, so without this an `xterm -bg black` flashes
    /// white as the user drags the window corner. Called at top-level map
    /// time and whenever ChangeWindowAttributes flips CWBackPixel on a
    /// top-level.
    func setTopLevelWindowBackground(id: UInt32, color: RGB16)
}

/// A single window-background paint: an absolute rect in top-level pixel
/// coordinates plus the resolved RGB16 to fill it with.
public struct WindowBackgroundRect: Equatable, Sendable {
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var color: RGB16
    public init(x: Int16, y: Int16, width: UInt16, height: UInt16, color: RGB16) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
    }
}

public extension WindowBridge {
    func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {}
    func drawingTarget(for drawable: UInt32) -> Any? { nil }
    func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {}
    func setOnKey(_ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void) {}
    func setOnFocus(_ handler: @escaping @Sendable (UInt32, Bool) -> Void) {}
    func setOnMouse(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void) {}
    func setOnMouseDragged(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8) -> Void) {}
    func setOnPointerMoved(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnPointerEnteredView(_ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnPointerExitedView(_ handler: @escaping @Sendable (UInt32) -> Void) {}
    func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void) {}
    func setOnCopy(_ handler: @escaping @Sendable (UInt32) -> Void) {}
    func writeClipboard(text: String) {}
    func setOnCloseRequest(_ handler: @escaping @Sendable (UInt32) -> Void) {}
    // Default no-ops so unit-test bridges don't have to implement every method.
    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {}
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {}
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {}
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, function: UInt8, rectangles: [Rectangle]) {}
    func drawPolyRectangle(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, rectangles: [Rectangle]) {}
    func drawPolyArc(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, arcs: [Arc]) {}
    func drawPolyFillArc(topLevel: UInt32, foreground: RGB16, arcs: [Arc]) {}
    func bell() {}
    func startCrossWindowDragTracking() {}
    func stopCrossWindowDragTracking() {}
    func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {}
    func copyArea(
        topLevel: UInt32,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16
    ) {}
    func drawImageText8(
        topLevel: UInt32,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8]
    ) {}
    func drawPolyText8(
        topLevel: UInt32,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8]
    ) {}
    func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect]) {}
    func setCursor(topLevel: UInt32, glyph: UInt16?) {}
    func setTopLevelWindowBackground(id: UInt32, color: RGB16) {}
}
