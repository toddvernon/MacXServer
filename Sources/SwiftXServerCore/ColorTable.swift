import Foundation

// Color allocator for the depth-24 TrueColor visual we advertise.
//
// Was a PseudoColor 8-bit colormap pre-2026-06-13; see DECISIONS for the
// switch reasoning. The visible API hasn't changed (allocate / rgb(for:) /
// pixel(for:) / count) so call sites are untouched; the implementation is
// now degenerate. In TrueColor the pixel value IS the RGB packed as 24
// bits: bits 16..23 = red, 8..15 = green, 0..7 = blue. No state needed
// for the mapping; `allocate` is a bit-pack, `rgb(for:)` is a bit-unpack.
//
// The count of unique allocated pixels is still tracked because the
// CapturedAppReplayTests baselines key on it — the same set of distinct
// RGBs an app allocates will produce the same `count` whether we were
// PseudoColor or TrueColor, modulo whatever color identity the visual
// imposes (the PseudoColor table pinned three special pixels at init;
// TrueColor doesn't).

public struct RGB16: Hashable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public final class ColorTable: @unchecked Sendable {
    private let lock = NSLock()
    /// Distinct pixel values handed out via `allocate`. Used only for
    /// `count` (regression-test baseline). The mapping itself is
    /// stateless — we always pack/unpack at call time.
    private var seenPixels: Set<UInt32> = []

    public init() {}

    /// AllocColor in TrueColor: pack the RGB into a 24-bit pixel and
    /// return it. The "allocated" RGB is the 8-bit-quantized form: we
    /// truncate the low 8 bits of each 16-bit channel and broadcast the
    /// remaining 8 bits to 16 (the `*257` X convention), so QueryColors
    /// later returns what hardware will actually display rather than the
    /// caller's original-precision request.
    public func allocate(red: UInt16, green: UInt16, blue: UInt16) -> (pixel: UInt32, allocated: RGB16) {
        let r8 = UInt32(red   >> 8)
        let g8 = UInt32(green >> 8)
        let b8 = UInt32(blue  >> 8)
        let pixel = (r8 << 16) | (g8 << 8) | b8
        lock.lock(); seenPixels.insert(pixel); lock.unlock()
        return (pixel, ColorTable.unpack(pixel))
    }

    /// Pixel → RGB16. Pure bit unpack; no state. Returns nil only when
    /// the pixel has bits set above the 24-bit RGB888 mask (i.e. someone
    /// stashed something into the alpha byte) — we treat that as garbage
    /// rather than rendering a bogus color.
    public func rgb(for pixel: UInt32) -> RGB16? {
        // Tolerate the high byte being either 0 or 0xFF — depth-24
        // pixels are sometimes 32-bit-aligned with alpha=0xFF in some
        // clients' PutImage data.
        let highByte = (pixel >> 24) & 0xFF
        guard highByte == 0 || highByte == 0xFF else { return nil }
        return ColorTable.unpack(pixel & 0x00FFFFFF)
    }

    /// RGB → pixel reverse lookup. Pure pack; identical to `allocate`'s
    /// pixel without the tracking side effect. Used by GetImage to turn
    /// the 32-bit ARGB sitting in the Mac backing back into a 24-bit X
    /// pixel value. In TrueColor this is lossless — no rounding to the
    /// nearest allocated cell, no AA-edge clamping to background like
    /// the PseudoColor era did.
    public func pixel(for rgb: RGB16) -> UInt32? {
        let r8 = UInt32(rgb.red   >> 8)
        let g8 = UInt32(rgb.green >> 8)
        let b8 = UInt32(rgb.blue  >> 8)
        return (r8 << 16) | (g8 << 8) | b8
    }

    /// Count of distinct pixel values allocated this session. Used by
    /// CapturedAppReplayTests to detect regressions in the request-flow
    /// path. Not load-bearing for any rendering decision.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seenPixels.count
    }

    /// Static helper for the bit unpack: 8-bit channel → 16-bit via
    /// `v * 257` (which is the same as `v | (v << 8)`), the X convention
    /// for expanding 8-bit colormap values to the 16-bit channel form
    /// X uses everywhere on the wire.
    private static func unpack(_ pixel: UInt32) -> RGB16 {
        let r8 = (pixel >> 16) & 0xFF
        let g8 = (pixel >> 8)  & 0xFF
        let b8 =  pixel        & 0xFF
        return RGB16(
            red:   UInt16(r8 * 257),
            green: UInt16(g8 * 257),
            blue:  UInt16(b8 * 257)
        )
    }
}
