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

    /// Build a GCState by replaying CreateGC + ChangeGC accumulated in a
    /// GCEntry. The entry's `valueList` is a concatenation of every value
    /// list ever set on this GC (we just keep appending in ChangeGC). Walk
    /// from the start; later writes for a given attribute overwrite earlier
    /// ones because they appear later in the bit-order traversal — which
    /// is wrong if the same bit was set twice. M3 enough for xclock; refine
    /// when an app misbehaves.
    public static func materialise(from entry: GCEntry, byteOrder: ByteOrder) -> GCState {
        var state = GCState()

        // The valueList's layout is: for each set bit in valueMask in
        // ascending order, 4 bytes of value. ChangeGC appends; if the same
        // bit was set in two ChangeGC calls, both 4-byte values appear in
        // the list. The simplest replay is to scan bit-by-bit using the
        // accumulated mask, which is what `ValueListReader.read` does for
        // the *first* occurrence. For M3 with xclock we don't see GC
        // attributes set twice, so this is fine.

        if let v = ValueListReader.read(valueList: entry.valueList, mask: entry.valueMask, bit: GCBits.foreground, byteOrder: byteOrder) {
            state.foreground = v
        }
        if let v = ValueListReader.read(valueList: entry.valueList, mask: entry.valueMask, bit: GCBits.background, byteOrder: byteOrder) {
            state.background = v
        }
        if let v = ValueListReader.read(valueList: entry.valueList, mask: entry.valueMask, bit: GCBits.lineWidth, byteOrder: byteOrder) {
            state.lineWidth = v
        }
        if let v = ValueListReader.read(valueList: entry.valueList, mask: entry.valueMask, bit: GCBits.fillRule, byteOrder: byteOrder) {
            state.fillRuleEvenOdd = (v == 0)        // 0 = EvenOdd, 1 = Winding per spec
        }
        if let v = ValueListReader.read(valueList: entry.valueList, mask: entry.valueMask, bit: GCBits.font, byteOrder: byteOrder) {
            state.font = v
        }
        return state
    }
}

// X11 fill-rule constants (from xproto X.h).
public enum FillRule: UInt32 {
    case evenOdd = 0
    case winding = 1
}
