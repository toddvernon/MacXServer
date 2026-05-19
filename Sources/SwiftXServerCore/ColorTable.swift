import Foundation

// PseudoColor colormap for the default colormap.
//
// X11 colormaps are server-global resources identified by ColormapId. Every
// client connected to the same screen sees the same default colormap; if
// xterm allocates pixel 17 = green, xcalc reading pixel 17 must also see
// green. This table is owned by ServerCoordinator (not the session) so that
// invariant holds across multi-client sessions.
//
// AllocColor implements shared read-only cells: requesting an RGB that's
// already in the table returns the existing pixel rather than allocating a
// new one. That's the path Motif's no-color-server fallback walks when it
// calls AllocColor(65535,65535,65535) expecting whitePixel back — without
// it, Motif's BlackWhite-detection in dtcalc fails and the LCD widget
// renders white-on-white. The X spec mandates this behavior for read-only
// cells; we always emit read-only (no AllocColorCells support yet).

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
    private var pixelToRGB: [UInt32: RGB16] = [:]
    private var rgbToPixel: [RGB16: UInt32] = [:]
    private var nextPixel: UInt32 = 16

    public init() {
        // Pin pixel 0 = white, pixel 1 = black. Matches the
        // whitePixel/blackPixel values our SetupAccepted advertises
        // (ServerConfig.swift) which in turn match real u5 Xsun (verified
        // 2026-05-14 against four captured Sun sessions). Counter-intuitive
        // — many people expect 0 = black — but X11 monochrome convention is
        // 0 = paper = white, 1 = ink = black, and Sun's PseudoColor screen
        // setup inherited that convention.
        //
        // With shared-cell AllocColor below, these pins are what make
        // Motif's no-color-server fallback work: it calls
        // AllocColor(65535,65535,65535) expecting whitePixel back, then
        // checks `pixels[0].bg == white_pixel` to set BlackWhite=True. Real
        // Sun Xsun returns whitePixel for that request because it's a
        // shared cell already in the colormap; we match by RGB to do the
        // same.
        //
        // 0xFFFFFF is also pinned to white as a defensive carryover.
        // Pre-2026-05-14 we incorrectly advertised whitePixel=0xFFFFFF (out
        // of range for a depth-8 visual); a few captured corpus paths
        // reference 0xFFFFFF expecting white. Keeping the pin means those
        // paths still render correctly even though we've stopped
        // advertising the value. Since rgbToPixel prefers the lowest pixel
        // ID for a given RGB, AllocColor still returns 0 (not 0xFFFFFF)
        // for white requests.
        pin(pixel: 0, rgb: RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
        pin(pixel: 1, rgb: RGB16(red: 0, green: 0, blue: 0))
        pin(pixel: 0xFFFFFF, rgb: RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
    }

    /// Pin a (pixel, rgb) mapping into the table without going through the
    /// allocator. Used at init time for whitePixel/blackPixel. The reverse
    /// map (rgbToPixel) prefers the LOWEST pixel ID for a given RGB so
    /// shared-cell matches stay canonical when multiple pixels map to the
    /// same RGB.
    private func pin(pixel: UInt32, rgb: RGB16) {
        pixelToRGB[pixel] = rgb
        if let existing = rgbToPixel[rgb], existing < pixel {
            // Existing mapping has a lower pixel ID; leave it canonical.
            return
        }
        rgbToPixel[rgb] = pixel
    }

    /// X11 PseudoColor AllocColor on a shared (read-only) cell: if the
    /// requested RGB is already in the colormap, return that existing
    /// pixel. Otherwise allocate a new pixel. Thread-safe.
    public func allocate(red: UInt16, green: UInt16, blue: UInt16) -> (pixel: UInt32, allocated: RGB16) {
        lock.lock(); defer { lock.unlock() }
        let rgb = RGB16(red: red, green: green, blue: blue)
        if let existing = rgbToPixel[rgb] {
            return (existing, rgb)
        }
        let pixel = nextPixel
        nextPixel += 1
        pixelToRGB[pixel] = rgb
        rgbToPixel[rgb] = pixel
        return (pixel, rgb)
    }

    public func rgb(for pixel: UInt32) -> RGB16? {
        lock.lock(); defer { lock.unlock() }
        return pixelToRGB[pixel]
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return pixelToRGB.count
    }
}
