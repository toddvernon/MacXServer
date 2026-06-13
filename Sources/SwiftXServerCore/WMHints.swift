import Foundation
import Framer

/// ICCCM §4.1.2.3 WM_SIZE_HINTS. 18 CARD32 slots; `flags` says which
/// downstream fields are populated. We honor PMinSize / PMaxSize /
/// PResizeInc / PAspect / PBaseSize (the bits mwm/dtwm honor and the
/// only ones that map to AppKit's NSWindow constraint API). USPosition /
/// USSize / PPosition / PSize / PWinGravity are advisory positioning
/// hints that NSWindow doesn't honor through this API path.
///
/// Field layout from `Xatomtype.h` `xPropSizeHints`. Pre-ICCCM clients
/// may publish a 15-element property (missing baseW/baseH/winGravity);
/// `decode` accepts both and zeros the missing fields. WM_NORMAL_HINTS
/// is atom 40 (predefined).
public struct WMSizeHints: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let usPosition  = Flags(rawValue: 0x0001)
        public static let usSize      = Flags(rawValue: 0x0002)
        public static let pPosition   = Flags(rawValue: 0x0004)
        public static let pSize       = Flags(rawValue: 0x0008)
        public static let pMinSize    = Flags(rawValue: 0x0010)
        public static let pMaxSize    = Flags(rawValue: 0x0020)
        public static let pResizeInc  = Flags(rawValue: 0x0040)
        public static let pAspect     = Flags(rawValue: 0x0080)
        public static let pBaseSize   = Flags(rawValue: 0x0100)
        public static let pWinGravity = Flags(rawValue: 0x0200)
    }

    public let flags: Flags
    public let minWidth: Int32, minHeight: Int32
    public let maxWidth: Int32, maxHeight: Int32
    public let widthInc: Int32, heightInc: Int32
    public let minAspectX: Int32, minAspectY: Int32
    public let maxAspectX: Int32, maxAspectY: Int32
    public let baseWidth: Int32, baseHeight: Int32

    public init(flags: Flags,
                minWidth: Int32 = 0, minHeight: Int32 = 0,
                maxWidth: Int32 = 0, maxHeight: Int32 = 0,
                widthInc: Int32 = 0, heightInc: Int32 = 0,
                minAspectX: Int32 = 0, minAspectY: Int32 = 0,
                maxAspectX: Int32 = 0, maxAspectY: Int32 = 0,
                baseWidth: Int32 = 0, baseHeight: Int32 = 0) {
        self.flags = flags
        self.minWidth = minWidth; self.minHeight = minHeight
        self.maxWidth = maxWidth; self.maxHeight = maxHeight
        self.widthInc = widthInc; self.heightInc = heightInc
        self.minAspectX = minAspectX; self.minAspectY = minAspectY
        self.maxAspectX = maxAspectX; self.maxAspectY = maxAspectY
        self.baseWidth = baseWidth; self.baseHeight = baseHeight
    }

    /// Decode the property bytes. Returns nil for the truncated case
    /// (< 18 bytes, can't even read flags). Pre-ICCCM 15-element form is
    /// accepted: missing trailing fields zero out.
    public static func decode(_ data: [UInt8], byteOrder: ByteOrder) -> WMSizeHints? {
        guard data.count >= 4 else { return nil }
        let read = { (offset: Int) -> Int32 in
            guard offset + 4 <= data.count else { return 0 }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            let raw: UInt32 = byteOrder == .lsbFirst
                ? (b0 | b1 << 8 | b2 << 16 | b3 << 24)
                : (b3 | b2 << 8 | b1 << 16 | b0 << 24)
            return Int32(bitPattern: raw)
        }
        let flags = Flags(rawValue: UInt32(bitPattern: read(0)))
        return WMSizeHints(
            flags: flags,
            // x/y/w/h at offsets 4,8,12,16 are obsolete; skip.
            minWidth:   read(20), minHeight:  read(24),
            maxWidth:   read(28), maxHeight:  read(32),
            widthInc:   read(36), heightInc:  read(40),
            minAspectX: read(44), minAspectY: read(48),
            maxAspectX: read(52), maxAspectY: read(56),
            baseWidth:  read(60), baseHeight: read(64)
            // winGravity at 68 ignored.
        )
    }
}

/// `_MOTIF_WM_HINTS` (and the older alias `_MWM_HINTS`). 5 CARD32s:
/// flags, functions, decorations, inputMode, status. From Motif's
/// `MwmUtil.h` `PropMotifWmHints`. Decoration flags drive the per-window
/// chrome on the Motif frame; without a `flags & DECORATIONS` bit set,
/// the decorations field is undefined and the static frame config wins.
public struct MotifWMHints: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let functions   = Flags(rawValue: 0x1)
        public static let decorations = Flags(rawValue: 0x2)
        public static let inputMode   = Flags(rawValue: 0x4)
        public static let status      = Flags(rawValue: 0x8)
    }

    public struct Decorations: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let all      = Decorations(rawValue: 0x01)
        public static let border   = Decorations(rawValue: 0x02)
        public static let resizeH  = Decorations(rawValue: 0x04)
        public static let title    = Decorations(rawValue: 0x08)
        public static let menu     = Decorations(rawValue: 0x10)
        public static let minimize = Decorations(rawValue: 0x20)
        public static let maximize = Decorations(rawValue: 0x40)
    }

    public let flags: Flags
    public let functions: UInt32
    public let decorations: Decorations
    public let inputMode: Int32
    public let status: UInt32

    public init(flags: Flags, functions: UInt32, decorations: Decorations,
                inputMode: Int32, status: UInt32) {
        self.flags = flags
        self.functions = functions
        self.decorations = decorations
        self.inputMode = inputMode
        self.status = status
    }

    /// `flags & DECORATIONS` is set AND the decoration value is NOT
    /// `ALL` (which means "use the default everything-on set"). When
    /// false, callers should fall back to the static frame config.
    public var hasExplicitDecorations: Bool {
        flags.contains(.decorations) && !decorations.contains(.all)
    }

    public static func decode(_ data: [UInt8], byteOrder: ByteOrder) -> MotifWMHints? {
        guard data.count >= 4 else { return nil }
        let read = { (offset: Int) -> UInt32 in
            guard offset + 4 <= data.count else { return 0 }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            return byteOrder == .lsbFirst
                ? (b0 | b1 << 8 | b2 << 16 | b3 << 24)
                : (b3 | b2 << 8 | b1 << 16 | b0 << 24)
        }
        return MotifWMHints(
            flags: Flags(rawValue: read(0)),
            functions: read(4),
            decorations: Decorations(rawValue: read(8)),
            inputMode: Int32(bitPattern: read(12)),
            status: read(16)
        )
    }
}
