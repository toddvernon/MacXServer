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

    /// Studio Display preset. Used as fallback when no real display info
    /// is available (e.g., test environment where the session is driven
    /// directly without a Cocoa runloop).
    public static let `default` = ServerConfig(displayConfig: .studioDisplay)

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
        vendor: [UInt8] = Array("swift-x".utf8),
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
        let pseudoColor8 = VisualType(
            visualId: rootVisualId,
            visualClass: .pseudoColor,
            bitsPerRgbValue: 8,
            colormapEntries: 256,
            redMask: 0,
            greenMask: 0,
            blueMask: 0
        )
        let depth8 = Depth(depth: 8, visuals: [pseudoColor8])

        let screen = Screen(
            root: rootWindowId,
            defaultColormap: defaultColormapId,
            whitePixel: 0xFFFFFF,
            blackPixel: 0x000000,
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
            rootDepth: 8,
            allowedDepths: [depth8]
        )

        let pixmapFormat = PixmapFormat(depth: 8, bitsPerPixel: 8, scanlinePad: 32)

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
