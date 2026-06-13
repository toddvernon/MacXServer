import Framer

// All the hardcoded values that go into our SetupAccepted reply. M1 ships one
// PseudoColor 8-bit visual on a single 1280x1024 screen, vendor "swift-x",
// resource-id-base 0x4400000 (matches what Sun handed out in our xclock capture
// so the unit tests can replay captured C2S byte streams). Once we have real
// macOS display geometry plumbed through (post-M3), most of this becomes
// computed.
//
// Logged in SHORTCUTS.md.

public struct ServerConfig: Sendable {
    public var rootWindowId: UInt32
    public var defaultColormapId: UInt32
    public var rootVisualId: UInt32
    public var resourceIdBase: UInt32
    public var resourceIdMask: UInt32
    /// Logical pixel width — what X clients see as the screen size. Per
    /// `SERVER_RESOLUTION_SCALING_AND_FONTS.md` the rendering pipeline
    /// scales this up to device pixels by `scaleFactor`.
    public var widthInPixels: UInt16
    public var heightInPixels: UInt16
    /// Reported physical size, derived to keep DPI ≈ 90 regardless of
    /// underlying display so Sun-era Xt/Motif font auto-sizing stays sane.
    public var widthInMillimeters: UInt16
    public var heightInMillimeters: UInt16
    public var vendor: [UInt8]
    public var releaseNumber: UInt32
    /// Multiplier from logical pixels to device pixels. The X protocol
    /// layer never sees this; the rendering layer uses it. Integer values
    /// (1, 2, 3) are the Phase-1 happy path with clean N×N device-pixel
    /// blocks per logical pixel; fractional values like 2.5 are accepted
    /// at the cost of AA edges between cells.
    public var scaleFactor: Double

    /// Same as `scaleFactor` rounded to an `Int32` for the device-coord
    /// region system (`DEVICE_COORDS_REFACTOR.md`). Internal regions
    /// (`clipList`, `borderClip`, `boundingShape`, `clipShape`) store
    /// coordinates in device pixels; `BoxRec.scaledToDevice(by:)` /
    /// `Region.scaledToDevice(by:)` use this. Always ≥ 1.
    public var deviceScale: Int32 { max(1, Int32(scaleFactor.rounded())) }

    /// Default used by `ServerSession()` when no config is passed —
    /// scale=1 so test code that asserts directly on region values
    /// doesn't have to multiply through. The real (Cocoa-driven)
    /// `macxserver` path builds its own `ServerConfig(displayConfig:)`
    /// with the picked retina display, so its scale is whatever
    /// `DisplayConfig.forMainDisplay` chose (typically 3).
    public static let `default` = ServerConfig(displayConfig: .scaleOne)

    /// Same as `.default` today. Kept as an explicit name for tests that
    /// want to make the scale=1 choice visible at the callsite.
    public static let test = ServerConfig(displayConfig: .scaleOne)

    public init(
        rootWindowId: UInt32,
        defaultColormapId: UInt32,
        rootVisualId: UInt32,
        resourceIdBase: UInt32,
        resourceIdMask: UInt32,
        widthInPixels: UInt16,
        heightInPixels: UInt16,
        widthInMillimeters: UInt16,
        heightInMillimeters: UInt16,
        vendor: [UInt8],
        releaseNumber: UInt32,
        scaleFactor: Double = 1
    ) {
        self.rootWindowId = rootWindowId
        self.defaultColormapId = defaultColormapId
        self.rootVisualId = rootVisualId
        self.resourceIdBase = resourceIdBase
        self.resourceIdMask = resourceIdMask
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.widthInMillimeters = widthInMillimeters
        self.heightInMillimeters = heightInMillimeters
        self.vendor = vendor
        self.releaseNumber = releaseNumber
        self.scaleFactor = scaleFactor
    }

    /// Build a ServerConfig from a DisplayConfig + protocol-layer constants.
    /// The dimensions and physical mm come from the picked display preset.
    public init(
        displayConfig: DisplayConfig,
        rootWindowId: UInt32 = 0x28,
        defaultColormapId: UInt32 = 0x21,
        rootVisualId: UInt32 = 0x22,
        resourceIdBase: UInt32 = 0x4400000,
        resourceIdMask: UInt32 = 0x1FFFFF,
        vendor: [UInt8] = Array("macXserver".utf8),
        releaseNumber: UInt32 = 1
    ) {
        self.init(
            rootWindowId: rootWindowId,
            defaultColormapId: defaultColormapId,
            rootVisualId: rootVisualId,
            resourceIdBase: resourceIdBase,
            resourceIdMask: resourceIdMask,
            widthInPixels: UInt16(displayConfig.logicalWidth),
            heightInPixels: UInt16(displayConfig.logicalHeight),
            widthInMillimeters: UInt16(displayConfig.widthMm),
            heightInMillimeters: UInt16(displayConfig.heightMm),
            vendor: vendor,
            releaseNumber: releaseNumber,
            scaleFactor: displayConfig.scale
        )
    }

    public func makeSetupAccepted() -> SetupAccepted {
        // TrueColor 24-bit, RGB888. Pixel value IS the RGB (no colormap
        // lookup needed): bits 16..23 = red, 8..15 = green, 0..7 = blue.
        // Switched from PseudoColor-depth-8 on 2026-06-13 — see DECISIONS
        // for the reasoning. The 8-bit PseudoColor choice from 2026-05-05
        // was era-authentic to Sun frame buffers but imposed real costs
        // (replay color-translation problem, GetImage reverse-map fidelity
        // loss, AllocColor 256-cell ceiling, blocker for modern Linux apps
        // hitting us via the SSH launcher). Vintage Motif/Athena/Xt apps
        // use DefaultVisual and don't notice the switch; the small slice
        // of palette-cycling apps that DO require PseudoColor (xcolorize,
        // xmorph, screensaver demos) don't appear in the charter corpus.
        let trueColor24 = VisualType(
            visualId: rootVisualId,
            visualClass: .trueColor,
            bitsPerRgbValue: 8,
            // For TrueColor, colormapEntries advertises the per-channel
            // colormap size (RGB lookup tables, used for gamma) — 256 is
            // conventional for 8-bit-per-channel.
            colormapEntries: 256,
            redMask:   0x00FF0000,
            greenMask: 0x0000FF00,
            blueMask:  0x000000FF
        )
        let depth24 = Depth(depth: 24, visuals: [trueColor24])

        let screen = Screen(
            root: rootWindowId,
            defaultColormap: defaultColormapId,
            // TrueColor: pixel value IS the RGB. blackPixel = 0x000000,
            // whitePixel = 0xFFFFFF. These match how every Linux X server
            // since the mid-90s advertises depth-24 TrueColor.
            whitePixel: 0x00FFFFFF,
            blackPixel: 0x00000000,
            currentInputMasks: 0,
            widthInPixels: widthInPixels,
            heightInPixels: heightInPixels,
            widthInMillimeters: widthInMillimeters,
            heightInMillimeters: heightInMillimeters,
            minInstalledMaps: 1,
            maxInstalledMaps: 1,
            rootVisual: rootVisualId,
            backingStores: .never,
            saveUnders: false,
            rootDepth: 24,
            allowedDepths: [depth24]
        )

        // Depth-24 visuals pad pixel storage to 32 bits (X.org convention)
        // — one byte unused per pixel for word alignment. PutImage/GetImage
        // wire data is 32 bits per pixel even though only 24 are
        // meaningful. scanlinePad stays at 32 (one pixel per 32-bit word).
        let pixmapFormat = PixmapFormat(depth: 24, bitsPerPixel: 32, scanlinePad: 32)

        return SetupAccepted(
            protocolMajor: 11,
            protocolMinor: 0,
            releaseNumber: releaseNumber,
            resourceIdBase: resourceIdBase,
            resourceIdMask: resourceIdMask,
            motionBufferSize: 256,
            maximumRequestLength: 65535,
            imageByteOrder: .msbFirst,
            bitmapFormatBitOrder: .mostSignificant,
            bitmapFormatScanlineUnit: 32,
            bitmapFormatScanlinePad: 32,
            minKeycode: 8,
            maxKeycode: 255,
            vendor: vendor,
            pixmapFormats: [pixmapFormat],
            screens: [screen]
        )
    }
}
