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
        // Pin pixel 0 = white, pixel 1 = black. Matches the
        // whitePixel/blackPixel values our SetupAccepted advertises
        // (ServerConfig.swift) which in turn match real u5 Xsun (verified
        // 2026-05-14 against four captured Sun sessions). Counter-intuitive
        // — many people expect 0 = black — but X11 monochrome convention is
        // 0 = paper = white, 1 = ink = black, and Sun's PseudoColor screen
        // setup inherited that convention.
        //
        // Also pin 0xFFFFFF = white as a defensive carryover. Pre-2026-05-14
        // we incorrectly advertised whitePixel=0xFFFFFF (out of range for a
        // depth-8 visual); a few captured corpus paths reference 0xFFFFFF
        // expecting white. Keeping the pin means those paths render correctly
        // even though we've stopped advertising the value.
        pixelToRGB[0] = RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
        pixelToRGB[1] = RGB16(red: 0, green: 0, blue: 0)
        pixelToRGB[0xFFFFFF] = RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)

        // Pre-seed the CDE customization-daemon palette: pixels 1..23 (decimal).
        // CDE dt-apps consume an `SDT Pixel Set` property published by the
        // dtsession daemon (we impersonate this in ServerSession init) which
        // is just an underscore-separated string of hex pixel indices. dt-apps
        // then set `CWBackPixel = <one of those pixels>` on their widgets,
        // expecting the colormap to already hold sensible RGB values at those
        // slots. With nothing pre-allocated, resolveColor() falls back to
        // black and the entire calculator paints black-on-black (verified
        // 2026-05-10 against dtcalc / dtterm / dthelpview / dticon).
        //
        // Values below are an approximation of the CDE "Default" colour
        // scheme — the medium-cool-grey look most CDE-on-Solaris boxes shipped
        // with. Pixels 9 (main window bg) and 14 (LCD/text-area bg) are the
        // ones dtcalc actually uses for background; the rest get sensible
        // shadow/highlight greys so any widget reaching for them gets a
        // colour rather than black.
        // Pixel-role mapping derived empirically from dtcalc's GC creations
        // (CreateGC seqs 119-123 in dtcalc-swiftx.xtap, 2026-05-10):
        //   GC 0x440000A: FG=0x9  BG=0xD  — panel-fill (bg matches parent)
        //   GC 0x440000B: FG=0xB  BG=0xD  — TOP shadow (lighter than bg)
        //   GC 0x440000C: FG=0xC  BG=0xD  — BOTTOM shadow (darker than bg)
        //   GC 0x440000D: FG=0x4  BG=0x9  — text/label on panel bg
        //   GC 0x440000E: FG=0xD  BG=0x9  — secondary line / divider
        // The pivot: pixel 4 must be DARK (text on grey is invisible if it's
        // also a grey). Pixels B and C must be visibly lighter and darker
        // than pixel 9 (the main bg) for Motif's 3D button shadows to show.
        // Prior palette had B and C both near-identical to bg → buttons
        // rendered as flat panels with no visible borders or labels.
        let cdePalette: [UInt32: (UInt16, UInt16, UInt16)] = [
            0x01: (0x0000, 0x0000, 0x0000),  // black
            0x02: (0xE0E0, 0xE0E0, 0xE8E8),  // very light highlight
            0x03: (0xFFFF, 0xFFFF, 0xFFFF),  // white
            0x04: (0x1010, 0x1010, 0x1818),  // DARK — text/labels on bg
            0x05: (0x8080, 0x8080, 0xA0A0),  // mid select
            0x06: (0xA0A0, 0xA0A0, 0xC0C0),  // light select
            0x07: (0x6060, 0x6060, 0x8080),  // dark select
            0x08: (0x6060, 0x6060, 0x6868),  // dark grey (secondary)
            0x09: (0xB0B0, 0xB0B0, 0xB8B8),  // main bg — CDE grey
            0x0A: (0xA8A8, 0xA8A8, 0xB0B0),  // secondary bg
            0x0B: (0xE0E0, 0xE0E0, 0xE8E8),  // TOP shadow — lighter than bg
            0x0C: (0x5858, 0x5858, 0x6060),  // BOTTOM shadow — darker than bg
            0x0D: (0xACAC, 0xACAC, 0xB4B4),  // mid grey (used as GC BG)
            0x0E: (0xADAD, 0xAFAF, 0xBDBD),  // LCD / text-area bg
            0x0F: (0x7070, 0x7070, 0x7878),  // borders
            0x10: (0x4040, 0x4040, 0x4848),  // dark border
            0x11: (0x9090, 0x9090, 0x9898),  // mid border
            0x12: (0x9898, 0x9898, 0x9E9E),  // panel divider
            0x13: (0xC8C8, 0xC8C8, 0xD0D0),  // light divider
            0x14: (0xADAD, 0xAFAF, 0xBDBD),  // LCD accent bg
            0x15: (0xB0B0, 0xB0B0, 0xB8B8),  // fill grey
            0x16: (0xB0B0, 0xB0B0, 0xB8B8),  // fill grey
            0x17: (0xB0B0, 0xB0B0, 0xB8B8),  // fill grey
        ]
        for (pixel, (r, g, b)) in cdePalette {
            pixelToRGB[pixel] = RGB16(red: r, green: g, blue: b)
        }
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
