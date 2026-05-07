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
    public var widthInPixels: UInt16
    public var heightInPixels: UInt16
    public var widthInMillimeters: UInt16
    public var heightInMillimeters: UInt16
    public var vendor: [UInt8]
    public var releaseNumber: UInt32

    public static let `default` = ServerConfig(
        rootWindowId: 0x28,
        defaultColormapId: 0x21,
        rootVisualId: 0x22,
        resourceIdBase: 0x4400000,
        resourceIdMask: 0x1FFFFF,
        widthInPixels: 1280,
        heightInPixels: 1024,
        widthInMillimeters: 360,
        heightInMillimeters: 290,
        vendor: Array("swift-x".utf8),
        releaseNumber: 1
    )

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
        releaseNumber: UInt32
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
