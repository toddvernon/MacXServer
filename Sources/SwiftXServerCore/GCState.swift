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

    public init() {}

    /// Build a GCState from a GCEntry's parsed per-bit values dict. Each bit
    /// holds its most recent CARD32 (CreateGC + every subsequent ChangeGC),
    /// so reads are O(1) and there's no bytes-merging trap.
    public static func materialise(from entry: GCEntry, byteOrder: ByteOrder) -> GCState {
        var state = GCState()
        if let v = entry.values[GCBits.foreground] { state.foreground = v }
        if let v = entry.values[GCBits.background] { state.background = v }
        if let v = entry.values[GCBits.lineWidth]  { state.lineWidth  = v }
        if let v = entry.values[GCBits.fillRule]   { state.fillRuleEvenOdd = (v == 0) }
        if let v = entry.values[GCBits.font]       { state.font = v }
        return state
    }
}

// X11 fill-rule constants (from xproto X.h).
public enum FillRule: UInt32 {
    case evenOdd = 0
    case winding = 1
}
