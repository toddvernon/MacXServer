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
    /// on screen and emits ReparentNotify / ConfigureNotify / MapNotify on
    /// the top-level, plus Expose on the top-level and each descendant whose
    /// event mask includes ExposureMask (the X11 spec's "newly viewable"
    /// rule). `eventMask` is the top-level's event mask; descendants is a
    /// snapshot of all already-mapped descendants of the top-level.
    func mapTopLevel(
        id: UInt32,
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

    // MARK: - Drawing (M3)
    //
    // Coordinates are already translated to the top-level NSWindow's view
    // frame by the session before these are called.

    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment])
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint])
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool)
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, rectangles: [Rectangle])
    func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16)

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
}

public extension WindowBridge {
    func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {}
    func drawingTarget(for drawable: UInt32) -> Any? { nil }
    func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {}
    // Default no-ops so unit-test bridges don't have to implement every method.
    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {}
    func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {}
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {}
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, rectangles: [Rectangle]) {}
    func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {}
    func drawImageText8(
        topLevel: UInt32,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8]
    ) {}
}
