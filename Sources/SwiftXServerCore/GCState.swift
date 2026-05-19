import Framer

// X11 GC attribute mask bits (from xproto X.h).
public enum GCBits {
    public static let function: UInt32         = 1 << 0
    public static let planeMask: UInt32        = 1 << 1
    public static let foreground: UInt32       = 1 << 2
    public static let background: UInt32       = 1 << 3
    public static let lineWidth: UInt32        = 1 << 4
    public static let lineStyle: UInt32        = 1 << 5
    public static let capStyle: UInt32         = 1 << 6
    public static let joinStyle: UInt32        = 1 << 7
    public static let fillStyle: UInt32        = 1 << 8
    public static let fillRule: UInt32         = 1 << 9
    public static let tile: UInt32             = 1 << 10
    public static let stipple: UInt32          = 1 << 11
    public static let tileStippleXOrigin: UInt32 = 1 << 12
    public static let tileStippleYOrigin: UInt32 = 1 << 13
    public static let font: UInt32             = 1 << 14
    public static let subwindowMode: UInt32    = 1 << 15
    public static let graphicsExposures: UInt32 = 1 << 16
    public static let clipXOrigin: UInt32      = 1 << 17
    public static let clipYOrigin: UInt32      = 1 << 18
    public static let clipMask: UInt32         = 1 << 19
    public static let dashOffset: UInt32       = 1 << 20
    public static let dashList: UInt32         = 1 << 21
    public static let arcMode: UInt32          = 1 << 22
}

// Materialised GC state. Per RENDERING_DESIGN.md item 4: each drawing request
// applies fresh — we don't try to hold "current" state on the CGContext.
public struct GCState: Equatable, Sendable {
    public var foreground: UInt32 = 0       // pixel value
    public var background: UInt32 = 0xFFFFFF
    public var lineWidth: UInt32 = 0        // 0 = 1px thin line per X11 spec
    public var fillRuleEvenOdd: Bool = true
    public var font: UInt32 = 0             // X font id; 0 = none set
    /// Drawing function (X11 GC `function` attribute). Default = GXcopy = 3
    /// (overwrite destination). The toolkit-relevant non-default is GXxor = 6
    /// (XOR with destination), used by Athena's menu-item highlight: first
    /// XOR-fill highlights, second XOR-fill on same area un-highlights, text
    /// preserved underneath. Without honoring this, Athena/Motif menus
    /// destroy item text on mouse-over because we paint solid over it.
    public var function: UInt8 = 3
    /// Clip rectangles in DRAWABLE-LOCAL coords (clipXOrigin/Yorigin already
    /// folded in). The bridge's `withDrawContext` translates these to
    /// top-level coords for window targets (using the target's windowOffset);
    /// pixmap targets use them as-is. nil = no clip; empty = clip-everything.
    public var clipRectangles: [Rectangle]?
    /// Dash on/off lengths (first byte = on). nil = solid line.
    public var dashes: [UInt8]?
    /// Dash phase offset, in pen-distance units along the path.
    public var dashOffset: UInt32 = 0
    /// GC graphics-exposures bit. true = server emits GraphicsExpose /
    /// NoExposure events for CopyArea / CopyPlane. Default true per X11
    /// spec. When false (Xt sets this on many internal GCs), the server
    /// MUST emit neither — pre-2026-05-15 we emitted NoExposure
    /// unconditionally, which forced clients with graphicsExposures=False
    /// to queue and discard an event they explicitly said they didn't
    /// want.
    public var graphicsExposures: Bool = true
    /// GC fill-style. 0 = FillSolid (default; fg fills everywhere),
    /// 1 = FillTiled (fg-channel comes from `tile` pixmap, replicated),
    /// 2 = FillStippled (fg only where `stipple` bit is 1; dest unchanged
    /// elsewhere), 3 = FillOpaqueStippled (fg where 1, bg where 0).
    /// Motif's XmText caret uses FillStippled with a small depth-1 pixmap
    /// to render the I-beam; without honoring this we draw a solid block.
    public var fillStyle: UInt8 = 0
    /// Pixmap ID for the stipple pattern. 0 = unset.
    public var stipple: UInt32 = 0
    /// Pixmap ID for the tile pattern. 0 = unset.
    public var tile: UInt32 = 0
    /// Pattern origin (CWStippleXOrigin / CWStippleYOrigin). The stipple
    /// tiles starting from this point so toolkits can keep the pattern
    /// phase-aligned with a parent's pattern across redraws.
    public var tileStippleXOrigin: Int16 = 0
    public var tileStippleYOrigin: Int16 = 0

    public init() {}

    /// Build a GCState from a GCEntry's parsed per-bit values dict. Each bit
    /// holds its most recent CARD32 (CreateGC + every subsequent ChangeGC),
    /// so reads are O(1) and there's no bytes-merging trap. Clip rects and
    /// dashes ride alongside the dict on the entry; this also folds in the
    /// clip-origin offsets so callers don't have to do it.
    public static func materialise(from entry: GCEntry, byteOrder: ByteOrder) -> GCState {
        var state = GCState()
        if let v = entry.values[GCBits.foreground] { state.foreground = v }
        if let v = entry.values[GCBits.background] { state.background = v }
        if let v = entry.values[GCBits.lineWidth]  { state.lineWidth  = v }
        if let v = entry.values[GCBits.fillRule]   { state.fillRuleEvenOdd = (v == 0) }
        if let v = entry.values[GCBits.font]       { state.font = v }
        if let v = entry.values[GCBits.dashOffset] { state.dashOffset = v }
        if let v = entry.values[GCBits.function]   { state.function = UInt8(truncatingIfNeeded: v) }
        if let v = entry.values[GCBits.graphicsExposures] { state.graphicsExposures = (v != 0) }
        if let v = entry.values[GCBits.fillStyle]  { state.fillStyle = UInt8(truncatingIfNeeded: v) }
        if let v = entry.values[GCBits.stipple]    { state.stipple = v }
        if let v = entry.values[GCBits.tile]       { state.tile = v }
        if let v = entry.values[GCBits.tileStippleXOrigin] {
            state.tileStippleXOrigin = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
        }
        if let v = entry.values[GCBits.tileStippleYOrigin] {
            state.tileStippleYOrigin = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
        }
        if let rects = entry.clipRectangles {
            let cox = Int16(bitPattern: UInt16(truncatingIfNeeded: entry.values[GCBits.clipXOrigin] ?? 0))
            let coy = Int16(bitPattern: UInt16(truncatingIfNeeded: entry.values[GCBits.clipYOrigin] ?? 0))
            state.clipRectangles = rects.map {
                Rectangle(x: $0.x &+ cox, y: $0.y &+ coy, width: $0.width, height: $0.height)
            }
        }
        state.dashes = entry.dashes
        return state
    }
}

// X11 fill-rule constants (from xproto X.h).
public enum FillRule: UInt32 {
    case evenOdd = 0
    case winding = 1
}
