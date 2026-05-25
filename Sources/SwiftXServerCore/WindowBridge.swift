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
/// MapNotify and Expose to the right window. `exposeRects` are the
/// visible portions of the window in WINDOW-LOCAL coordinates (the same
/// coord space Expose's x/y/width/height live in); typically a single
/// rect (0, 0, width, height) for a leaf with no obscuring children,
/// shrinks to zero for fully-covered windows.
public struct DescendantSnapshot: Equatable, Sendable {
    public var id: UInt32
    public var eventMask: UInt32
    public var width: UInt16
    public var height: UInt16
    public var exposeRects: [BoxRec]
    public init(id: UInt32, eventMask: UInt32, width: UInt16, height: UInt16,
                exposeRects: [BoxRec] = []) {
        self.id = id; self.eventMask = eventMask
        self.width = width; self.height = height
        self.exposeRects = exposeRects
    }
}

public protocol WindowBridge: AnyObject, Sendable {
    /// Logical-to-device scale of the window backings the bridge owns.
    /// 1 X-logical pixel = `scaleFactor` device pixels. PixmapTable
    /// allocates pixmap backings at this same scale so CopyArea round
    /// trips between window and pixmap stay pixel-lossless.
    var scaleFactor: Double { get }

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
    /// `topLevelExposeRects` are the visible portions of the top-level
    /// (clipList) in window-local coords; Step E1 forward, this drives
    /// Expose emission for the top-level itself.
    func mapTopLevel(
        id: UInt32,
        geometry: TopLevelGeometry,
        eventMask: UInt32,
        topLevelExposeRects: [BoxRec],
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

    /// The X client reconfigured an already-mapped top-level via
    /// ConfigureWindow. Bridge moves and/or resizes the NSWindow to match
    /// the new geometry. Used heavily by Motif's menubar trick: a single
    /// popup shell gets dragged sideways across menubar items, with the
    /// shell repeatedly reconfigured to each menu's position+size and a
    /// different inner form swapped in. Without this, the popup stays at
    /// the original position/size and subsequent menus render into the
    /// wrong place. Default no-op for non-Cocoa bridges (mocks).
    func reconfigureTopLevel(id: UInt32, geometry: TopLevelGeometry)

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
    func setOnTopLevelResize(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the user
    /// drags a top-level NSWindow to a new screen position. Args: (top-level
    /// X window id, new X-root x, new X-root y). The session updates its
    /// WindowTable and emits a SYNTHETIC ConfigureNotify per ICCCM 4.1.5 so
    /// toolkits (Xt, Motif) update their cached widget root coords — without
    /// it, menu popups and similar root-coord-sensitive geometry stays at
    /// the original placement. Always invoked on the main thread.
    func setOnTopLevelMove(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. The bridge stores the closure and
    /// invokes it on every keyDown / keyUp NSEvent in any of its NSWindows.
    /// Args: (top-level X window id, macOS virtual keyCode, raw modifierFlags,
    /// isDown). The session translates to an X KeyPress / KeyRelease event,
    /// resolves the key target via the X subtree, and queues the event.
    /// Always invoked on the main thread.
    func setOnKey(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void)

    /// Called by the session at startup. The bridge invokes this whenever an
    /// NSWindow becomes key (gained=true) or resigns key (gained=false). The
    /// session emits a FocusIn / FocusOut event to the X client. xterm uses
    /// this to switch its cursor between filled (focused) and hollow outline
    /// (unfocused). Args: (top-level X window id, gained).
    func setOnFocus(token: UInt64, _ handler: @escaping @Sendable (UInt32, Bool) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseDown / mouseUp inside one of its NSWindows. Args: (top-level X
    /// window id, X-logical x, X-logical y in top-level coords, X button
    /// number 1..3, isDown). The session resolves which X subwindow should
    /// receive the event and emits ButtonPress / ButtonRelease.
    /// Always invoked on the main thread.
    func setOnMouse(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseDragged event (mouse moved while a button is held). Args:
    /// (top-level X window id, X-logical x, X-logical y in top-level coords,
    /// X button number 1..3 of the held button). The session emits
    /// MotionNotify so clients can track a drag — xterm needs this to
    /// render the inverse-video selection highlight as the user drags.
    /// Always invoked on the main thread.
    func setOnMouseDragged(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8) -> Void)

    /// Called by the session at startup. Bridge invokes this on every
    /// mouseMoved (pointer moved with NO button held). Args: (top-level X
    /// window id, X-logical x, X-logical y in top-level coords). The
    /// session tracks which X subwindow currently contains the pointer and
    /// emits EnterNotify / LeaveNotify when the containing window changes.
    /// Always invoked on the main thread. Mouse-with-button-held is
    /// `setOnMouseDragged` — the protocol distinguishes the two.
    func setOnPointerMoved(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the
    /// pointer crosses INTO an NSWindow's content area (from outside our
    /// X subtree entirely — e.g. mouse moves over the window from another
    /// app or from off-screen). Args: (top-level X window id, X-logical x,
    /// y in top-level coords). The session emits the EnterNotify chain
    /// from top-level down to the deepest window currently under the
    /// pointer.
    func setOnPointerEnteredView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the
    /// pointer leaves an NSWindow's content area (mouse moves off the
    /// window edge or to another app). Args: (top-level X window id, X-logical
    /// cursor coords at exit time, in top-level local space — may be outside
    /// the window's bounds since the exit IS the cursor leaving). The session
    /// emits the LeaveNotify chain with the actual exit-point coords; matches
    /// how a real X server reports the cursor's position at the moment of the
    /// crossing (verified against Sun's quickplot capture — Sun's Leave coords
    /// describe the same root pixel as the corresponding Enter on the sibling
    /// popup, not the prior motion event's coords).
    func setOnPointerExitedView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void)

    /// Called by the session at startup. Bridge invokes this when the user
    /// pastes (Cmd-V or Edit > Paste) into one of its NSWindows. Args:
    /// (top-level X window id, pasteboard text). The session synthesises
    /// a KeyPress/KeyRelease pair per character so the running X client
    /// receives the paste as typed input.
    func setOnPaste(token: UInt64, _ handler: @escaping @Sendable (UInt32, String) -> Void)

    /// Called by the session at startup. Bridge invokes this when the user
    /// asks to copy the X selection into the Mac clipboard (Cmd-C or
    /// Edit > Copy in one of our NSWindows). Args: (top-level X window id).
    /// The session looks up the current selection owner and runs the
    /// ConvertSelection roundtrip, eventually calling writeClipboard with
    /// the resulting text.
    func setOnCopy(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void)

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
    func setOnCloseRequest(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void)

    /// Remove every handler previously registered with `token`. Called by
    /// the session in `cleanupOnDisconnect` so dead-session closures stop
    /// firing on every AppKit event. Idempotent. The default implementation
    /// is a no-op for mock/test bridges that don't actually store handlers.
    func removeHandlers(token: UInt64)

    // MARK: - Drawing (M3)
    //
    // Coordinates are already translated to the top-level NSWindow's view
    // frame by the session before these are called.

    // `clipRectangles` reflects the GC's SetClipRectangles state, already
    // translated into top-level coordinates by GCState.materialise. nil =
    // unclipped (the common case); empty array = clip-everything (per X spec,
    // skip the entire draw); non-empty = clip to the union of rectangles.
    // Pre-existing clip on the CGContext (set by AppKit / our own layout
    // pipeline) is preserved: each impl wraps the clip-apply + draw in
    // saveGState/restoreGState.

    // For stroke methods, `dashes` is the GC's SetDashes byte pattern (each
    // byte = a run length in pixels, alternating on/off, first byte = on);
    // nil or empty = solid line. `dashOffset` is the phase offset along the
    // path in pixels. Applied via CGContext.setLineDash inside the clip
    // scope.

    func drawPolySegment(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32)
    func drawPolyLine(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32)
    func drawFillPoly(target: DrawTarget, foreground: RGB16, points: [DrawPoint], evenOdd: Bool, clipRectangles: [Rectangle]?)
    /// PolyFillRectangle. `function` is the X GC drawing function — primarily
    /// 3 (GXcopy, overwrite) or 6 (GXxor, toggle). XOR is what Athena/Motif
    /// menu-item highlights use; non-XOR fills destroy text underneath.
    /// `fillStyle` selects FillSolid (0) / FillTiled (1) / FillStippled (2) /
    /// FillOpaqueStippled (3). Solid uses only `foreground`; stippled paths
    /// read the `stipple` pixmap (1-bit pattern) and mask the fill to its
    /// set bits — Motif's XmText caret needs this or it draws a solid block.
    /// Tiled paths read `tile` (depth-N pixmap, currently unimplemented).
    func drawPolyFillRectangle(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        function: UInt8,
        fillStyle: UInt8,
        stipple: UInt32, tile: UInt32,
        stippleOriginX: Int16, stippleOriginY: Int16,
        rectangles: [Rectangle], clipRectangles: [Rectangle]?
    )
    /// PolyRectangle: stroke the perimeter of each rect (vs PolyFillRectangle
    /// which fills). Used by Athena Command for the highlight border that
    /// appears when the pointer enters the widget.
    func drawPolyRectangle(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, rectangles: [Rectangle], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32)
    /// PolyArc: stroke the outline of each elliptical arc. Each arc's bounding
    /// box is (x, y, width, height) in top-level coords, with angles in 64ths
    /// of a degree (angle1 = start, angle2 = extent; positive = counterclockwise).
    /// xclock uses this for the clock face; xeyes for eye outlines.
    func drawPolyArc(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, arcs: [Arc], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32)
    /// PolyFillArc: fill the interior of each elliptical arc. Same arc geometry
    /// as drawPolyArc; the filled region is the pie slice from arc center
    /// (default arc-mode=PieSlice; chord mode unhandled per OPCODE_STATUS).
    /// xeyes fills the white sclera of each eye via this opcode.
    func drawPolyFillArc(target: DrawTarget, foreground: RGB16, arcs: [Arc], clipRectangles: [Rectangle]?)
    /// ClearArea: fill the rectangles (in top-level coords) with the window's
    /// background pixel. Per X11 spec the X server clips to the window's
    /// visible region (clipList) before painting; the session performs that
    /// intersection and passes the surviving sub-rects here. Empty `rects` =
    /// no-op (window fully obscured or request fully outside visible region).
    /// Spec ref: mi/miwindow.c:miClearToBackground.
    func clearArea(topLevel: UInt32, rects: [Rectangle], background: RGB16)

    /// Register a closure that maps a window id → its clipList rects (visible
    /// region in top-level coords). The bridge consults this in
    /// `withDrawContext` for window targets to set CGContext.clip to the
    /// composite clip = window clipList ∩ GC user clip. Spec ref:
    /// mi/migc.c:miComputeCompositeClip. Session registers once on init.
    /// Legacy single-set entry; production code uses
    /// `registerWindowClipLookup(token:_:)` so multiple sessions can
    /// coexist (pre-2026-05-23 this was last-write-wins, which silently
    /// broke draws on session A's windows once session B connected).
    func setWindowClipLookup(_ lookup: @escaping @Sendable (UInt32) -> [Rectangle])

    /// Register a per-session window-clip lookup. The closure should
    /// return nil when this session doesn't own the window (lets the
    /// bridge consult other sessions), and `[]` when the window IS
    /// owned but fully obscured (withDrawContext short-circuits on
    /// empty). On disconnect, call `unregisterWindowClipLookup(token:)`.
    func registerWindowClipLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> [Rectangle]?)
    func unregisterWindowClipLookup(token: UInt64)

    /// CopyArea: copies a rectangular region of pixels from `src` to `dst`.
    /// All five spec-supported variants resolve via DrawTarget: window→window
    /// (same NSWindow uses a bitmap memmove fast path that xterm scroll
    /// depends on; cross-NSWindow snapshots src as CGImage and blits via
    /// CGContext.draw(image:in:)), window→pixmap, pixmap→window,
    /// pixmap→pixmap (all four non-fast-path cases go through the CGImage
    /// path). Coordinates are in each target's local coord space — for
    /// window targets the caller has already added the windowOffset; for
    /// pixmap targets coords ARE pixmap-local. GC clip honored on every
    /// path except the same-window memmove (xterm doesn't set clip there).
    func copyArea(
        src: DrawTarget,
        dst: DrawTarget,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16,
        clipRectangles: [Rectangle]?
    )

    /// PutImage: blit a bitmap into the target drawable at `(dstX, dstY)`.
    /// Today only `format=bitmap` (X depth-1, packed 1bpp scanlines) is
    /// implemented. Other formats (XYPixmap, ZPixmap) get silent-dropped
    /// at the session layer so the bridge doesn't need to know them yet.
    /// `sourceWidth` / `sourceHeight` are the image's pixel dims. `leftPad`
    /// is the number of bits of pad at the start of each scanline (used
    /// by Xlib when the request had non-byte-aligned width). `foreground`
    /// replaces 1-bits, `background` replaces 0-bits in the depth-1 source.
    /// Scanlines are 32-bit-aligned and MSB-first per our setup-reply
    /// advertisement (ServerConfig: bitmapFormatBitOrder=mostSignificant,
    /// bitmapFormatScanlinePad=32).
    func drawPutImage(
        target: DrawTarget,
        sourceData: [UInt8],
        sourceWidth: UInt16, sourceHeight: UInt16,
        dstX: Int16, dstY: Int16,
        leftPad: UInt8,
        foreground: RGB16, background: RGB16,
        clipRectangles: [Rectangle]?
    )

    /// Read drawable contents back as UInt32 pixels at LOGICAL X-coord
    /// scale. One UInt32 per logical pixel; in-memory layout is BGRA per
    /// the Mac CGBitmapContext format (byteOrder32Little + premultipliedFirst).
    /// On a little-endian host that reads as 0xAARRGGBB. Used by GetImage.
    func readDrawablePixels(
        from src: DrawTarget,
        srcX: Int16, srcY: Int16,
        width: Int, height: Int
    ) -> [UInt32]

    /// ImageText8: fill bg rect, then draw text. `(x, y)` is the baseline of
    /// the first glyph in top-level logical pixel coords. The bridge owns
    /// CTFont instantiation per the resolved font's macFontName + pointSize.
    func drawImageText8(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8],
        clipRectangles: [Rectangle]?
    )

    /// PolyText8: draw glyphs without filling the cell background. `items` is
    /// the raw TEXTITEM8 stream from the X request (font-shift sentinel 0xFF
    /// followed by 4-byte FontID, OR 1-byte length + 1-byte signed delta +
    /// `length` glyph bytes). The bridge parses + renders. Used by Athena
    /// widget apps (xcalc) which never use ImageText8.
    func drawPolyText8(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Rectangle]?
    )

    /// ImageText16: same as drawImageText8 but with CHAR2B characters
    /// (`row<<8 | column` per UniChar, already decoded by the dispatcher).
    /// For Latin-1 char with row=0 this is identical to the 8-bit path.
    /// For CJK fonts (k14, k24 in x11perf) the row carries the kanji block;
    /// Core Text's missing-glyph fallback handles the cases where the
    /// resolved Mac font has no glyph at that codepoint.
    func drawImageText16(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        characters: [UInt16],
        clipRectangles: [Rectangle]?
    )

    /// PolyText16: same as drawPolyText8 but with TEXTITEM16 items
    /// (CHAR2B characters big-endian). Each text run inside `items` has the
    /// CHAR2B byte pairs in MSB-first order regardless of connection byte
    /// order; the bridge converts them to UniChar at draw time.
    func drawPolyText16(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Rectangle]?
    )

    /// Paint a list of solid-color rects on the top-level's backing context.
    /// Used to honor X11 "newly viewable" semantics: when a window is mapped
    /// or exposed, the server fills its region with the configured background
    /// pixel BEFORE the client draws on top.
    func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect])

    /// Move a `width × height` rect from `(fromX, fromY)` to `(toX, toY)` in
    /// the top-level's backing context, with fallback bg-paint for any
    /// portion of the source that's out-of-bounds. All coords in X-logical
    /// top-level space (same coord system as paintWindowRects).
    ///
    /// Implements NorthWest bit-gravity preservation when a descendant
    /// window pure-moves (position changes, size unchanged): X11R6 server's
    /// miCopyWindow equivalent. Without it, a widget that slides into a
    /// region of the bitmap previously occupied by other content (e.g.
    /// quickplot's XmText command line moving up into the plot area when
    /// the window y-shrinks) renders text over the wrong pixels because
    /// the toolkit assumes its content bits move with the window.
    ///
    /// `fallbackBgRects` are painted at the dest BEFORE the blit. If the
    /// source rect is in-bounds, the subsequent blit overwrites the
    /// fallback with the widget's actual old content. If the source is
    /// out-of-bounds (e.g. the old position was below the top-level's new
    /// shrunken bitmap height — the quickplot case), the blit no-ops and
    /// the fallback stands. The order is enforced atomically inside the
    /// bridge: snapshot first (captures source before the paint), then
    /// paint, then blit-from-snapshot.
    func blitWindowRegion(
        topLevel: UInt32,
        fromX: Int32, fromY: Int32,
        width: UInt32, height: UInt32,
        toX: Int32, toY: Int32,
        fallbackBgRects: [WindowBackgroundRect]
    )

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

    /// Called by the session at startup. The bridge stores the closure and
    /// invokes it from withDrawContext when a draw target resolves to a
    /// pixmap, getting the per-pixmap CGBitmapContext that backs the draw.
    /// Default no-op for test/mock bridges that don't render into pixmaps
    /// (their pixmap draws silent-drop). With multiple sessions sharing a
    /// bridge, the most-recently-set lookup wins. Pre-2026-05-23 this
    /// was the only entry point and broke multi-session apps; now also
    /// have `registerPixmapBufferLookup(token:_:)` for per-session use.
    func setPixmapBufferLookup(_ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?)

    /// Register a per-session pixmap-buffer lookup. Returns the buffer
    /// if this session owns the pixmap id, else nil so the bridge can
    /// fall through to other sessions' lookups.
    func registerPixmapBufferLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?)
    func unregisterPixmapBufferLookup(token: UInt64)

    /// Install the server's ColorTable for reverse-mapping ARGB pixels to
    /// X pixel indices. Required by the GXxor true-pixel-value path in
    /// PolyFillRectangle (dtterm's invert-cell cursor) — without it the
    /// path falls back to a CGBlendMode.difference approximation that
    /// fails when src and dst RGB are equal (black-on-black = invisible).
    /// Server-global object — multi-registration is harmless.
    func setColorTableLookup(_ lookup: @escaping @Sendable () -> ColorTable?)
    func registerColorTableLookup(token: UInt64, _ lookup: @escaping @Sendable () -> ColorTable?)
    func unregisterColorTableLookup(token: UInt64)

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
    /// Default scale factor for bridges that don't override (test mocks,
    /// stubs). Real bridges (`CocoaWindowBridge`) provide a stored value.
    var scaleFactor: Double { 1 }
    func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {}
    func drawingTarget(for drawable: UInt32) -> Any? { nil }
    func setOnTopLevelResize(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {}
    func setOnTopLevelMove(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnKey(token: UInt64, _ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void) {}
    func setOnFocus(token: UInt64, _ handler: @escaping @Sendable (UInt32, Bool) -> Void) {}
    func setOnMouse(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void) {}
    func setOnMouseDragged(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8) -> Void) {}
    func setOnPointerMoved(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnPointerEnteredView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnPointerExitedView(token: UInt64, _ handler: @escaping @Sendable (UInt32, Int16, Int16) -> Void) {}
    func setOnPaste(token: UInt64, _ handler: @escaping @Sendable (UInt32, String) -> Void) {}
    func setOnCopy(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void) {}
    func writeClipboard(text: String) {}
    func setOnCloseRequest(token: UInt64, _ handler: @escaping @Sendable (UInt32) -> Void) {}
    func removeHandlers(token: UInt64) {}
    func setPixmapBufferLookup(_ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?) {}
    func registerPixmapBufferLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> PixelBuffer?) {}
    func unregisterPixmapBufferLookup(token: UInt64) {}
    func setColorTableLookup(_ lookup: @escaping @Sendable () -> ColorTable?) {}
    func registerColorTableLookup(token: UInt64, _ lookup: @escaping @Sendable () -> ColorTable?) {}
    func unregisterColorTableLookup(token: UInt64) {}
    // Default no-ops so unit-test bridges don't have to implement every method.
    func drawPolySegment(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {}
    func drawPolyLine(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {}
    func drawFillPoly(target: DrawTarget, foreground: RGB16, points: [DrawPoint], evenOdd: Bool, clipRectangles: [Rectangle]?) {}
    func drawPolyFillRectangle(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        function: UInt8,
        fillStyle: UInt8,
        stipple: UInt32, tile: UInt32,
        stippleOriginX: Int16, stippleOriginY: Int16,
        rectangles: [Rectangle], clipRectangles: [Rectangle]?
    ) {}
    func drawPolyRectangle(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, rectangles: [Rectangle], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {}
    func drawPolyArc(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, arcs: [Arc], clipRectangles: [Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {}
    func drawPolyFillArc(target: DrawTarget, foreground: RGB16, arcs: [Arc], clipRectangles: [Rectangle]?) {}
    func bell() {}
    func startCrossWindowDragTracking() {}
    func stopCrossWindowDragTracking() {}
    func clearArea(topLevel: UInt32, rects: [Rectangle], background: RGB16) {}
    func setWindowClipLookup(_ lookup: @escaping @Sendable (UInt32) -> [Rectangle]) {}
    func registerWindowClipLookup(token: UInt64, _ lookup: @escaping @Sendable (UInt32) -> [Rectangle]?) {}
    func unregisterWindowClipLookup(token: UInt64) {}
    func copyArea(
        src: DrawTarget,
        dst: DrawTarget,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16,
        clipRectangles: [Rectangle]?
    ) {}
    func drawPutImage(
        target: DrawTarget,
        sourceData: [UInt8],
        sourceWidth: UInt16, sourceHeight: UInt16,
        dstX: Int16, dstY: Int16,
        leftPad: UInt8,
        foreground: RGB16, background: RGB16,
        clipRectangles: [Rectangle]?
    ) {}
    func readDrawablePixels(
        from src: DrawTarget,
        srcX: Int16, srcY: Int16,
        width: Int, height: Int
    ) -> [UInt32] { [] }
    func drawImageText8(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8],
        clipRectangles: [Rectangle]?
    ) {}
    func drawPolyText8(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Rectangle]?
    ) {}
    func drawImageText16(
        target: DrawTarget,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        characters: [UInt16],
        clipRectangles: [Rectangle]?
    ) {}
    func drawPolyText16(
        target: DrawTarget,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8],
        clipRectangles: [Rectangle]?
    ) {}
    func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect]) {}
    func blitWindowRegion(
        topLevel: UInt32,
        fromX: Int32, fromY: Int32,
        width: UInt32, height: UInt32,
        toX: Int32, toY: Int32,
        fallbackBgRects: [WindowBackgroundRect]
    ) {}
    func setCursor(topLevel: UInt32, glyph: UInt16?) {}
    func setTopLevelWindowBackground(id: UInt32, color: RGB16) {}
    func reconfigureTopLevel(id: UInt32, geometry: TopLevelGeometry) {}
}
