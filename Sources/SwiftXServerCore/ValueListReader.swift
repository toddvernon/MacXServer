import Framer

// Helpers for extracting fields from CreateWindow / ChangeWindowAttributes /
// CreateGC / ChangeGC valueLists. Each request carries a bitmask + a list of
// 4-byte values that correspond to the set bits of the mask in ascending order
// of bit position. We only need a couple of specific fields in M1, so this is
// a small surgical helper rather than a full decoder.

enum ValueListReader {
    /// If `bit` is set in `mask`, returns the 4 bytes at the position
    /// corresponding to that bit's rank in the mask. Returns nil otherwise.
    static func read(valueList: [UInt8], mask: UInt32, bit: UInt32, byteOrder: ByteOrder) -> UInt32? {
        guard mask & bit != 0 else { return nil }
        let prior = mask & (bit &- 1)
        let index = Int(prior.nonzeroBitCount)
        let offset = index * 4
        guard offset + 4 <= valueList.count else { return nil }
        let a = UInt32(valueList[offset])
        let b = UInt32(valueList[offset + 1])
        let c = UInt32(valueList[offset + 2])
        let d = UInt32(valueList[offset + 3])
        switch byteOrder {
        case .lsbFirst: return a | (b << 8) | (c << 16) | (d << 24)
        case .msbFirst: return (a << 24) | (b << 16) | (c << 8) | d
        }
    }
}

// CW (CreateWindow / ChangeWindowAttributes) attribute bit positions.
enum CW {
    static let backPixmap: UInt32         = 1 << 0
    static let backPixel: UInt32          = 1 << 1
    static let borderPixmap: UInt32       = 1 << 2
    static let borderPixel: UInt32        = 1 << 3
    static let bitGravity: UInt32         = 1 << 4
    static let winGravity: UInt32         = 1 << 5
    static let backingStore: UInt32       = 1 << 6
    static let backingPlanes: UInt32      = 1 << 7
    static let backingPixel: UInt32       = 1 << 8
    static let overrideRedirect: UInt32   = 1 << 9
    static let saveUnder: UInt32          = 1 << 10
    static let eventMask: UInt32          = 1 << 11
    static let dontPropagate: UInt32      = 1 << 12
    static let colormap: UInt32           = 1 << 13
    static let cursor: UInt32             = 1 << 14
}

// Configure-window value bits.
enum CWindow {
    static let x: UInt32           = 1 << 0
    static let y: UInt32           = 1 << 1
    static let width: UInt32       = 1 << 2
    static let height: UInt32      = 1 << 3
    static let borderWidth: UInt32 = 1 << 4
    static let sibling: UInt32     = 1 << 5
    static let stackMode: UInt32   = 1 << 6
}
