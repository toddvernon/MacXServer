// Synthetic pixel allocator for AllocColor in PseudoColor mode.
//
// We hand out monotonic pixel values starting at 16 (low values are commonly
// reserved for black/white). The pixel → RGB mapping is cached so M3's
// rendering can resolve pixel values at draw time. This isn't a real palette
// (no shared cells, no freelist, no cap) — see SHORTCUTS.md.

public struct RGB16: Equatable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public final class ColorTable {
    private var pixelToRGB: [UInt32: RGB16] = [:]
    private var nextPixel: UInt32 = 16

    public init() {
        // Pin black=0, white=0xFFFFFF for completeness. Most apps refer to these
        // by the screen's blackPixel/whitePixel rather than allocating.
        pixelToRGB[0] = RGB16(red: 0, green: 0, blue: 0)
        pixelToRGB[0xFFFFFF] = RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
    }

    public func allocate(red: UInt16, green: UInt16, blue: UInt16) -> (pixel: UInt32, allocated: RGB16) {
        let pixel = nextPixel
        nextPixel += 1
        let rgb = RGB16(red: red, green: green, blue: blue)
        pixelToRGB[pixel] = rgb
        return (pixel, rgb)
    }

    public func rgb(for pixel: UInt32) -> RGB16? {
        pixelToRGB[pixel]
    }

    public var count: Int { pixelToRGB.count }
}
