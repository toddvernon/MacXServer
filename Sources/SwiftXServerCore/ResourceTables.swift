import Foundation
import Framer

// Lightweight resource tables for windows, GCs, pixmaps, fonts, and properties.
// M1 just records what the client created — nothing rendering-related.

public struct WindowEntry: Equatable, Sendable {
    public var id: UInt32
    public var parent: UInt32
    public var depth: UInt8
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var windowClass: WindowClass
    public var visual: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]
    public var mapped: Bool
    public var eventMask: UInt32
    /// Effective CWBackPixel for the window. nil = no explicit background
    /// (windowBackground() falls back to white). Seeded from CreateWindow's
    /// valueList; ChangeWindowAttributes updates it.
    public var backPixel: UInt32?
    /// Effective CWBorderPixel. nil = no explicit border color (default black
    /// on real X servers). Drives the 1px-or-N-px ring painted around the
    /// window's content area.
    public var borderPixel: UInt32?
    /// CWCursor: cursor resource id this window declares. nil (or cid=0 /
    /// "None") means inherit from parent. The cursor table maps the id to
    /// an X cursor-font glyph, which we substitute with an NSCursor at
    /// pointer-crossing time.
    public var cursor: UInt32?
    /// CWOverrideRedirect bit. true = "window manager should not decorate
    /// this window." In rootless mode that means: don't create an NSWindow
    /// for it. Used by toolkits for helper windows (selection management,
    /// atom registration, IPC) and for popup elements (menus, tooltips).
    /// Default false.
    public var overrideRedirect: Bool

    // CW* attributes that we accept-and-store but don't (yet) drive any
    // rendering pipeline. Round-tripped via GetWindowAttributes so clients
    // that read back what they set see the correct values. Pre-2026-05-15
    // these were silently dropped on the write side AND returned as zeros
    // on the read side — an XError-honesty violation flagged by the
    // comparison study (synthesis #6).

    /// CWBitGravity: where existing pixels go when the window resizes
    /// (Forget=0, NorthWest=1, North=2, NorthEast=3, West=4, Center=5,
    /// East=6, SouthWest=7, South=8, SouthEast=9, Static=10).
    /// Spec default ForgetGravity = 0.
    public var bitGravity: UInt8
    /// CWWinGravity: where this window moves when its parent resizes.
    /// Same enum as bitGravity, plus Unmap=0. Spec default
    /// NorthWestGravity = 1.
    public var winGravity: UInt8
    /// CWBackingStore: NotUseful=0 / WhenMapped=1 / Always=2. We don't
    /// actually implement backing-store (see DECISIONS 2026-05-14); the
    /// value is stored only so reads echo writes.
    public var backingStore: UInt8
    /// CWBackingPlanes. Spec default ~0 (all planes).
    public var backingPlanes: UInt32
    /// CWBackingPixel. Spec default 0.
    public var backingPixel: UInt32
    /// CWSaveUnder. Spec default false; not honored by our backing store.
    public var saveUnder: Bool
    /// CWColormap. Per-window colormap selection. nil = inherit from
    /// parent (CopyFromParent sentinel handled at read time by walking up
    /// or falling back to the screen's default colormap).
    public var colormap: UInt32?
    /// CWDontPropagate. 16-bit subset of event-mask bits. Spec default 0.
    public var doNotPropagateMask: UInt16

    /// Visible region of the window's *interior* (excluding border) in
    /// top-level-local coordinates. Computed by ClipList.recomputeClips
    /// whenever the window tree mutates. Empty when the window is unmapped
    /// or unviewable. Step B+ field — written but not yet consulted by
    /// rendering or event paths (see WHAT_TO_DO_THIS_WEEK.md).
    public var clipList: Region
    /// Visible region of the window including its border ring, in
    /// top-level-local coordinates. Drives the parent's "stale pixels
    /// under moved descendant" repaint once Step E lands.
    public var borderClip: Region

    // MARK: - SHAPE extension state
    //
    // Per-window bounding and clip shapes set via the SHAPE extension. Both
    // are in window-local coordinates. nil == unshaped: the window keeps its
    // default rectangular bounding (border-inclusive) / clip (interior)
    // region. This matches the `wBoundingShape(pWin) == 0` convention in
    // reference/X11R6/xc/programs/Xserver/Xext/shape.c — a nil region means
    // "no shape set," NOT "empty shape." An explicitly-empty Region means the
    // window is shaped down to nothing (fully clipped away).
    public var boundingShape: Region?
    public var clipShape: Region?

    /// High-fidelity visual mask for the bounding shape, in window-local
    /// DEVICE pixels (one band per device row). Captured from the source
    /// pixmap at device resolution when a ShapeMask op=Set/Bounding lands, so
    /// the NSWindow clip can follow the curve at full backing resolution
    /// instead of the 1-logical-pixel stair-steps the protocol `boundingShape`
    /// region carries. nil = no device mask cached (use the logical region
    /// scaled up). Invalidated on any non-mask bounding mutation. Purely a
    /// rendering aid — the X-protocol shape is `boundingShape`.
    public var boundingShapeDeviceRects: [Rectangle]?

    /// Last VisibilityNotify state emitted for this window (raw value of
    /// VisibilityState: 0=Unobscured, 1=PartiallyObscured, 2=FullyObscured).
    /// nil = no state yet (initial, or window is currently unmapped). Used
    /// to detect transitions in `emitVisibilityChanges` so we only emit
    /// VisibilityNotify when the state actually changed.
    public var lastVisibilityState: UInt8?

    // MARK: - Sibling chain
    //
    // R6-style doubly-linked sibling chain per parent. The chain order IS
    // the Z-order. `firstChild` is the topmost child; `lastChild` is the
    // bottommost. `prevSib` points up (toward firstChild); `nextSib` points
    // down (toward lastChild). Convention matches `windowstr.h:101-104` so
    // future reads of R6/xorg/XQuartz source line up cleanly.
    //
    // The chain is maintained only for windows whose parent is in the
    // WindowTable — i.e. non-top-levels. Top-levels (parent == root) are
    // not chained because the root has no WindowEntry to anchor
    // firstChild/lastChild on; AppKit handles inter-top-level stacking
    // via NSWindow ordering in rootless mode, mirroring what XQuartz does.

    /// Sibling above this one in stack order (closer to the top). nil = this
    /// IS the topmost child (i.e. equals parent.firstChild).
    public var prevSib: UInt32?
    /// Sibling below this one in stack order (closer to the bottom). nil =
    /// this IS the bottommost child (equals parent.lastChild).
    public var nextSib: UInt32?
    /// Topmost (front-most, on top) child of this window. nil = no children.
    public var firstChild: UInt32?
    /// Bottommost (back-most, behind everything) child. nil = no children.
    public var lastChild: UInt32?

    public init(
        id: UInt32, parent: UInt32, depth: UInt8,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        borderWidth: UInt16, windowClass: WindowClass, visual: UInt32,
        valueMask: UInt32, valueList: [UInt8],
        mapped: Bool = false, eventMask: UInt32 = 0,
        backPixel: UInt32? = nil,
        borderPixel: UInt32? = nil,
        cursor: UInt32? = nil,
        overrideRedirect: Bool = false,
        bitGravity: UInt8 = 0,                 // ForgetGravity
        winGravity: UInt8 = 1,                 // NorthWestGravity
        backingStore: UInt8 = 0,               // NotUseful
        backingPlanes: UInt32 = ~UInt32(0),    // all planes
        backingPixel: UInt32 = 0,
        saveUnder: Bool = false,
        colormap: UInt32? = nil,
        doNotPropagateMask: UInt16 = 0,
        clipList: Region = .empty,
        borderClip: Region = .empty,
        boundingShape: Region? = nil,
        clipShape: Region? = nil,
        boundingShapeDeviceRects: [Rectangle]? = nil,
        lastVisibilityState: UInt8? = nil,
        prevSib: UInt32? = nil,
        nextSib: UInt32? = nil,
        firstChild: UInt32? = nil,
        lastChild: UInt32? = nil
    ) {
        self.id = id; self.parent = parent; self.depth = depth
        self.x = x; self.y = y; self.width = width; self.height = height
        self.borderWidth = borderWidth; self.windowClass = windowClass
        self.visual = visual; self.valueMask = valueMask; self.valueList = valueList
        self.mapped = mapped; self.eventMask = eventMask
        self.backPixel = backPixel
        self.borderPixel = borderPixel
        self.cursor = cursor
        self.overrideRedirect = overrideRedirect
        self.bitGravity = bitGravity
        self.winGravity = winGravity
        self.backingStore = backingStore
        self.backingPlanes = backingPlanes
        self.backingPixel = backingPixel
        self.saveUnder = saveUnder
        self.colormap = colormap
        self.doNotPropagateMask = doNotPropagateMask
        self.clipList = clipList
        self.borderClip = borderClip
        self.boundingShape = boundingShape
        self.clipShape = clipShape
        self.boundingShapeDeviceRects = boundingShapeDeviceRects
        self.lastVisibilityState = lastVisibilityState
        self.prevSib = prevSib
        self.nextSib = nextSib
        self.firstChild = firstChild
        self.lastChild = lastChild
    }
}

public final class WindowTable: @unchecked Sendable {
    // Thread-safety: read thread and the Cocoa main thread (resize handler)
    // both touch this table. NSLock keeps the underlying dictionary safe.
    private let lock = NSLock()
    private var _windows: [UInt32: WindowEntry] = [:]

    public init() {}

    public var windows: [UInt32: WindowEntry] {
        lock.lock(); defer { lock.unlock() }
        return _windows
    }
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _windows.count
    }

    public func insert(_ window: WindowEntry) {
        lock.lock(); _windows[window.id] = window; lock.unlock()
    }
    public func remove(_ id: UInt32) {
        lock.lock(); _windows.removeValue(forKey: id); lock.unlock()
    }
    public func get(_ id: UInt32) -> WindowEntry? {
        lock.lock(); defer { lock.unlock() }
        return _windows[id]
    }

    public func setMapped(_ id: UInt32, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.mapped = value
        _windows[id] = w
    }

    public func setEventMask(_ id: UInt32, _ mask: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.eventMask = mask
        _windows[id] = w
    }

    public func setBackPixel(_ id: UInt32, _ pixel: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.backPixel = pixel
        _windows[id] = w
    }

    public func setBorderPixel(_ id: UInt32, _ pixel: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.borderPixel = pixel
        _windows[id] = w
    }

    public func setCursor(_ id: UInt32, _ cursor: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.cursor = cursor
        _windows[id] = w
    }

    // MARK: - CW* attribute setters (added 2026-05-15)

    public func setOverrideRedirect(_ id: UInt32, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.overrideRedirect = value
        _windows[id] = w
    }

    public func setBitGravity(_ id: UInt32, _ value: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.bitGravity = value
        _windows[id] = w
    }

    public func setWinGravity(_ id: UInt32, _ value: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.winGravity = value
        _windows[id] = w
    }

    public func setBackingStore(_ id: UInt32, _ value: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.backingStore = value
        _windows[id] = w
    }

    public func setBackingPlanes(_ id: UInt32, _ value: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.backingPlanes = value
        _windows[id] = w
    }

    public func setBackingPixel(_ id: UInt32, _ value: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.backingPixel = value
        _windows[id] = w
    }

    public func setSaveUnder(_ id: UInt32, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.saveUnder = value
        _windows[id] = w
    }

    public func setColormap(_ id: UInt32, _ value: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.colormap = value
        _windows[id] = w
    }

    public func setDoNotPropagateMask(_ id: UInt32, _ value: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.doNotPropagateMask = value
        _windows[id] = w
    }

    public func setClipList(_ id: UInt32, _ region: Region) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.clipList = region
        _windows[id] = w
    }

    public func setBorderClip(_ id: UInt32, _ region: Region) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.borderClip = region
        _windows[id] = w
    }

    /// Set (or clear, with nil) a window's SHAPE bounding region.
    public func setBoundingShape(_ id: UInt32, _ region: Region?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.boundingShape = region
        _windows[id] = w
    }

    /// Set (or clear, with nil) a window's SHAPE clip region.
    public func setClipShape(_ id: UInt32, _ region: Region?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.clipShape = region
        _windows[id] = w
    }

    /// Set (or clear, with nil) the device-resolution visual mask for the
    /// bounding shape (see WindowEntry.boundingShapeDeviceRects).
    public func setBoundingShapeDeviceRects(_ id: UInt32, _ rects: [Rectangle]?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.boundingShapeDeviceRects = rects
        _windows[id] = w
    }

    public func setLastVisibilityState(_ id: UInt32, _ state: UInt8?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.lastVisibilityState = state
        _windows[id] = w
    }

    // MARK: - Sibling chain mutators
    //
    // Each modifies one window's chain field. The sibling-chain helper code
    // in ServerSession composes these into the higher-level operations
    // (link-at-top, unlink, move-above) and is responsible for keeping the
    // chain consistent. Callers that touch these directly must maintain
    // both ends of every link.

    public func setPrevSib(_ id: UInt32, _ value: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.prevSib = value
        _windows[id] = w
    }

    public func setNextSib(_ id: UInt32, _ value: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.nextSib = value
        _windows[id] = w
    }

    public func setFirstChild(_ id: UInt32, _ value: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.firstChild = value
        _windows[id] = w
    }

    public func setLastChild(_ id: UInt32, _ value: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard var w = _windows[id] else { return }
        w.lastChild = value
        _windows[id] = w
    }

    /// Returns `(oldEntry, newEntry)` so callers can decide whether the size
    /// actually changed (and thus whether to emit Expose / regrow backing).
    @discardableResult
    public func resize(_ id: UInt32, width: UInt16?, height: UInt16?, x: Int16?, y: Int16?) -> (WindowEntry, WindowEntry)? {
        lock.lock(); defer { lock.unlock() }
        guard let old = _windows[id] else { return nil }
        var w = old
        if let width = width   { w.width = width }
        if let height = height { w.height = height }
        if let x = x           { w.x = x }
        if let y = y           { w.y = y }
        _windows[id] = w
        return (old, w)
    }
}

public struct GCEntry: Equatable, Sendable {
    public var id: UInt32
    public var drawable: UInt32
    /// Parsed GC attribute values keyed by bit. Built from CreateGC's
    /// (valueMask, valueList) and updated incrementally on every ChangeGC.
    /// Storing parsed values rather than concatenating raw bytes avoids the
    /// "set foreground twice" trap: xterm sets it in CreateGC, then resets
    /// it via ChangeGC for every ANSI color switch — a raw-bytes append
    /// would leave the materialiser reading the original CreateGC value.
    public var values: [UInt32: UInt32]

    /// Clip rectangles set by SetClipRectangles. nil = no clip set (drawing
    /// is unclipped). Empty array = "clip everything" (per spec, draws
    /// should produce no output). ClipXOrigin / ClipYOrigin live in `values`
    /// under their attribute bits and offset every rect.
    public var clipRectangles: [Rectangle]?

    /// Dashes set by SetDashes. nil = solid lines. Bytes are alternating
    /// on/off lengths (first is on). DashOffset lives in `values` under
    /// its attribute bit. Per X spec the byte values must all be ≥ 1.
    public var dashes: [UInt8]?

    public init(id: UInt32, drawable: UInt32, values: [UInt32: UInt32] = [:]) {
        self.id = id; self.drawable = drawable
        self.values = values
    }
}

public final class GCTable {
    private(set) public var gcs: [UInt32: GCEntry] = [:]
    public init() {}

    /// Create a GC by parsing the CreateGC (valueMask, valueList) into the
    /// per-bit values dict. The byte order comes from the session.
    public func insert(id: UInt32, drawable: UInt32, valueMask: UInt32, valueList: [UInt8], byteOrder: ByteOrder) {
        var entry = GCEntry(id: id, drawable: drawable)
        applyValueList(into: &entry.values, mask: valueMask, list: valueList, byteOrder: byteOrder)
        gcs[id] = entry
    }

    public func remove(_ id: UInt32) { gcs.removeValue(forKey: id) }
    public func get(_ id: UInt32) -> GCEntry? { gcs[id] }

    /// Apply a ChangeGC's partial (valueMask, valueList): for each bit set
    /// in `valueMask`, decode the corresponding 4-byte value at that bit's
    /// rank within the *change's* mask and store it in the entry's values
    /// dict, overwriting any previous value for the same bit. Bits not set
    /// in `valueMask` are left untouched.
    ///
    /// Per X11 spec, the `clipMask` slot and the `SetClipRectangles` rect
    /// list are two faces of the same GC attribute — setting one replaces
    /// the other. So any ChangeGC that touches `clipMask` must also clear
    /// any rect list previously set via `SetClipRectangles` (`XSetClipMask
    /// (gc, None)` is the universal way clients say "remove the clip").
    /// Without this, a leftover rect list from an earlier draw keeps
    /// clipping subsequent draws — visible as quickplot's plot frame
    /// disappearing after a resize: the client draws data with a clip rect
    /// list, calls `XSetClipMask(gc, None)` to reset, then on the next
    /// expose tries to draw the frame, but the stored rect list still
    /// clips it to the old plot position which doesn't overlap the new one.
    public func change(_ id: UInt32, valueMask: UInt32, valueList: [UInt8], byteOrder: ByteOrder) {
        guard var entry = gcs[id] else { return }
        applyValueList(into: &entry.values, mask: valueMask, list: valueList, byteOrder: byteOrder)
        if valueMask & GCBits.clipMask != 0 {
            entry.clipRectangles = nil
        }
        gcs[id] = entry
    }

    /// Update the GC's clip rectangles + clip origin (SetClipRectangles).
    public func setClip(_ id: UInt32, rectangles: [Rectangle], xOrigin: Int16, yOrigin: Int16) {
        guard var entry = gcs[id] else { return }
        entry.clipRectangles = rectangles
        entry.values[GCBits.clipXOrigin] = UInt32(UInt16(bitPattern: xOrigin))
        entry.values[GCBits.clipYOrigin] = UInt32(UInt16(bitPattern: yOrigin))
        gcs[id] = entry
    }

    /// Update the GC's dash pattern + offset (SetDashes).
    public func setDashes(_ id: UInt32, dashes: [UInt8], offset: Int16) {
        guard var entry = gcs[id] else { return }
        entry.dashes = dashes
        entry.values[GCBits.dashOffset] = UInt32(UInt16(bitPattern: offset))
        gcs[id] = entry
    }

    public var count: Int { gcs.count }

    /// Walk `mask`'s set bits in ascending order; for each, read the next
    /// 4-byte CARD32 from `list` and store under that bit. Spec: the value
    /// list contains exactly one CARD32 per set bit, in mask-bit order.
    private func applyValueList(into values: inout [UInt32: UInt32], mask: UInt32, list: [UInt8], byteOrder: ByteOrder) {
        var index = 0
        var bit: UInt32 = 1
        while bit != 0 {
            if mask & bit != 0 {
                let offset = index * 4
                guard offset + 4 <= list.count else { return }
                let a = UInt32(list[offset])
                let b = UInt32(list[offset + 1])
                let c = UInt32(list[offset + 2])
                let d = UInt32(list[offset + 3])
                let value: UInt32
                switch byteOrder {
                case .lsbFirst: value = a | (b << 8) | (c << 16) | (d << 24)
                case .msbFirst: value = (a << 24) | (b << 16) | (c << 8) | d
                }
                values[bit] = value
                index += 1
            }
            bit <<= 1
        }
    }
}

public struct PixmapEntry: Equatable, Sendable {
    public var id: UInt32
    public var drawable: UInt32
    public var depth: UInt8
    public var width: UInt16
    public var height: UInt16

    public init(id: UInt32, drawable: UInt32, depth: UInt8, width: UInt16, height: UInt16) {
        self.id = id; self.drawable = drawable; self.depth = depth
        self.width = width; self.height = height
    }
}

public final class PixmapTable: @unchecked Sendable {
    private(set) public var pixmaps: [UInt32: PixmapEntry] = [:]
    /// CGBitmapContext per pixmap, allocated eagerly at `allocate` and
    /// freed at `remove`. Kept off `PixmapEntry` so the entry stays a
    /// pure value (Equatable + Sendable). PixmapEntry without a buffer
    /// is a temporary state that only exists if allocation failed
    /// (effectively never for sane width/height).
    private var buffers: [UInt32: PixelBuffer] = [:]
    /// Logical-to-device scale, applied to every PixelBuffer we allocate.
    /// Pixmaps store at device scale so CopyArea round-trips with the
    /// (same-scale) window backing are pixel-lossless, which is what
    /// Motif's caret save-under needs to avoid eroding glyph AA edges
    /// every blink. See PixelBuffer.scaleFactor for the full rationale.
    private let scaleFactor: Double

    public init(scaleFactor: Double = 1) {
        self.scaleFactor = scaleFactor
    }

    /// Record the pixmap and eagerly allocate its CGBitmapContext.
    /// Replaces any pre-existing entry at the same id.
    public func allocate(id: UInt32, drawable: UInt32, depth: UInt8, width: UInt16, height: UInt16) {
        pixmaps[id] = PixmapEntry(id: id, drawable: drawable, depth: depth, width: width, height: height)
        buffers[id] = PixelBuffer(width: Int(width), height: Int(height), scaleFactor: scaleFactor)
    }

    public func remove(_ id: UInt32) {
        pixmaps.removeValue(forKey: id)
        buffers.removeValue(forKey: id)
    }

    public func get(_ id: UInt32) -> PixmapEntry? { pixmaps[id] }

    /// Pixel buffer for the pixmap, nil if the pixmap doesn't exist or
    /// allocation failed at create time.
    public func buffer(for id: UInt32) -> PixelBuffer? { buffers[id] }

    public var count: Int { pixmaps.count }
}

public struct FontEntry: Equatable, Sendable {
    public var id: UInt32
    public var name: [UInt8]
    /// Resolved Mac font + cell metrics. Populated at OpenFont time so
    /// QueryFont can answer without re-parsing, and the bridge can
    /// instantiate the CTFont without round-tripping back to the session.
    public var resolved: ResolvedFont

    public init(id: UInt32, name: [UInt8], resolved: ResolvedFont) {
        self.id = id; self.name = name; self.resolved = resolved
    }
}

public final class FontTable {
    private(set) public var fonts: [UInt32: FontEntry] = [:]
    public init() {}

    public func insert(_ font: FontEntry) { fonts[font.id] = font }
    public func remove(_ id: UInt32) { fonts.removeValue(forKey: id) }
    public func get(_ id: UInt32) -> FontEntry? { fonts[id] }

    public var count: Int { fonts.count }
}

/// Tracks cursor resources created by the client. Maps the X cursor id to
/// the source-glyph index from the X "cursor" font (XC_xterm = 152, etc.) —
/// fg/bg colors and mask glyphs are ignored because we substitute NSCursor
/// system cursors at render time. The substitution happens on the bridge
/// side; this table just remembers the glyph for each id.
public struct CursorEntry: Equatable, Sendable {
    public var id: UInt32
    public var sourceGlyph: UInt16
    public init(id: UInt32, sourceGlyph: UInt16) {
        self.id = id; self.sourceGlyph = sourceGlyph
    }
}

public final class CursorTable {
    private(set) public var cursors: [UInt32: CursorEntry] = [:]
    public init() {}

    public func insert(_ cursor: CursorEntry) { cursors[cursor.id] = cursor }
    public func remove(_ id: UInt32) { cursors.removeValue(forKey: id) }
    public func glyph(_ id: UInt32) -> UInt16? { cursors[id]?.sourceGlyph }

    public var count: Int { cursors.count }
}

public struct PropertyEntry: Equatable, Sendable {
    public var window: UInt32
    public var property: UInt32     // ATOM
    public var type: UInt32         // ATOM
    public var format: UInt8        // 8/16/32
    public var value: [UInt8]

    public init(window: UInt32, property: UInt32, type: UInt32, format: UInt8, value: [UInt8]) {
        self.window = window; self.property = property
        self.type = type; self.format = format; self.value = value
    }
}

public final class PropertyTable {
    private(set) public var properties: [UInt32: [UInt32: PropertyEntry]] = [:]
    public init() {}

    /// Result of a ChangeProperty mutation. `.ok` succeeded; `.mismatch`
    /// means the request's type or format doesn't match the existing
    /// entry's (Prepend / Append modes only) and the caller must emit
    /// BadMatch per spec 10.10 — the entry was NOT mutated.
    public enum ChangeResult: Equatable, Sendable {
        case ok
        case mismatch
    }

    @discardableResult
    public func change(window: UInt32, property: UInt32, type: UInt32, format: UInt8, mode: UInt8, value: [UInt8]) -> ChangeResult {
        var perWindow = properties[window] ?? [:]
        if mode == 0 || perWindow[property] == nil {
            // Replace mode OR no existing entry: store as-is. Spec allows
            // overwriting any type/format on Replace.
            perWindow[property] = PropertyEntry(window: window, property: property, type: type, format: format, value: value)
        } else {
            // Prepend (mode==1) or Append (mode==2) into an existing entry.
            // Spec 10.10: BadMatch if request's type ≠ existing.type or
            // request's format ≠ existing.format. Pre-2026-05-15 we
            // silently kept the existing type/format and concatenated the
            // bytes — which corrupts the property because the wire-format
            // contract on the stored bytes (count of 8/16/32-bit units) no
            // longer matches what the client appended. Now we refuse,
            // leaving the entry untouched.
            var existing = perWindow[property]!
            if existing.type != type || existing.format != format {
                return .mismatch
            }
            if mode == 1 {                              // PropModePrepend
                existing.value = value + existing.value
            } else {                                    // PropModeAppend
                existing.value.append(contentsOf: value)
            }
            perWindow[property] = existing
        }
        properties[window] = perWindow
        return .ok
    }

    public func get(window: UInt32, property: UInt32) -> PropertyEntry? {
        properties[window]?[property]
    }

    public func delete(window: UInt32, property: UInt32) {
        properties[window]?.removeValue(forKey: property)
    }

    public func deleteAll(window: UInt32) {
        properties.removeValue(forKey: window)
    }

    public var totalCount: Int {
        properties.values.reduce(0) { $0 + $1.count }
    }
}
