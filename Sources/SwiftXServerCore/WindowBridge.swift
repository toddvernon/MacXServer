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

    /// Called by the session at startup. Bridge invokes this when the user
    /// pastes (Cmd-V or Edit > Paste) into one of its NSWindows. Args:
    /// (top-level X window id, pasteboard text). The session synthesises
    /// a KeyPress/KeyRelease pair per character so the running X client
    /// receives the paste as typed input.
    func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void)

    // MARK: - Drawing (M3)
    //
    // Coordinates are already translated to the top-level NSWindow's view
    // frame by the session before these are called.

    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment])
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint])
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool)
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, rectangles: [Rectangle])
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
    func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void) {}
    // Default no-ops so unit-test bridges don't have to implement every method.
    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {}
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {}
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {}
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, rectangles: [Rectangle]) {}
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
}
