public enum ImageByteOrder: UInt8, Sendable {
    case lsbFirst = 0
    case msbFirst = 1
}

public enum BitOrder: UInt8, Sendable {
    case leastSignificant = 0
    case mostSignificant = 1
}

public struct SetupAccepted: Equatable, Sendable {
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var releaseNumber: UInt32
    public var resourceIdBase: UInt32
    public var resourceIdMask: UInt32
    public var motionBufferSize: UInt32
    public var maximumRequestLength: UInt16
    public var imageByteOrder: ImageByteOrder
    public var bitmapFormatBitOrder: BitOrder
    public var bitmapFormatScanlineUnit: UInt8
    public var bitmapFormatScanlinePad: UInt8
    public var minKeycode: UInt8
    public var maxKeycode: UInt8
    public var vendor: [UInt8]
    public var pixmapFormats: [PixmapFormat]
    public var screens: [Screen]

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        releaseNumber: UInt32,
        resourceIdBase: UInt32,
        resourceIdMask: UInt32,
        motionBufferSize: UInt32,
        maximumRequestLength: UInt16,
        imageByteOrder: ImageByteOrder,
        bitmapFormatBitOrder: BitOrder,
        bitmapFormatScanlineUnit: UInt8,
        bitmapFormatScanlinePad: UInt8,
        minKeycode: UInt8,
        maxKeycode: UInt8,
        vendor: [UInt8],
        pixmapFormats: [PixmapFormat],
        screens: [Screen]
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.releaseNumber = releaseNumber
        self.resourceIdBase = resourceIdBase
        self.resourceIdMask = resourceIdMask
        self.motionBufferSize = motionBufferSize
        self.maximumRequestLength = maximumRequestLength
        self.imageByteOrder = imageByteOrder
        self.bitmapFormatBitOrder = bitmapFormatBitOrder
        self.bitmapFormatScanlineUnit = bitmapFormatScanlineUnit
        self.bitmapFormatScanlinePad = bitmapFormatScanlinePad
        self.minKeycode = minKeycode
        self.maxKeycode = maxKeycode
        self.vendor = vendor
        self.pixmapFormats = pixmapFormats
        self.screens = screens
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var body = ByteWriter(byteOrder: byteOrder)
        body.writeUInt32(releaseNumber)
        body.writeUInt32(resourceIdBase)
        body.writeUInt32(resourceIdMask)
        body.writeUInt32(motionBufferSize)
        body.writeUInt16(UInt16(vendor.count))
        body.writeUInt16(maximumRequestLength)
        body.writeUInt8(UInt8(screens.count))
        body.writeUInt8(UInt8(pixmapFormats.count))
        body.writeUInt8(imageByteOrder.rawValue)
        body.writeUInt8(bitmapFormatBitOrder.rawValue)
        body.writeUInt8(bitmapFormatScanlineUnit)
        body.writeUInt8(bitmapFormatScanlinePad)
        body.writeUInt8(minKeycode)
        body.writeUInt8(maxKeycode)
        body.writePadding(4)
        body.writeBytes(vendor)
        body.writePadding(xPad(vendor.count))
        for fmt in pixmapFormats { fmt.encode(into: &body) }
        for screen in screens { screen.encode(into: &body) }

        precondition(body.bytes.count % 4 == 0, "accepted reply body not 4-byte aligned")
        let lenIn4 = UInt16(body.bytes.count / 4)

        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(protocolMajor)
        w.writeUInt16(protocolMinor)
        w.writeUInt16(lenIn4)
        w.writeBytes(body.bytes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetupAccepted {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        _ = try r.readUInt16()
        let release = try r.readUInt32()
        let idBase = try r.readUInt32()
        let idMask = try r.readUInt32()
        let motion = try r.readUInt32()
        let vendorLen = Int(try r.readUInt16())
        let maxReqLen = try r.readUInt16()
        let nScreens = Int(try r.readUInt8())
        let nFormats = Int(try r.readUInt8())
        let imgRaw = try r.readUInt8()
        let bitRaw = try r.readUInt8()
        let scanlineUnit = try r.readUInt8()
        let scanlinePad = try r.readUInt8()
        let minKey = try r.readUInt8()
        let maxKey = try r.readUInt8()
        try r.skip(4)

        guard let img = ImageByteOrder(rawValue: imgRaw) else {
            throw FramerError.invalidEnum(name: "ImageByteOrder", value: UInt32(imgRaw))
        }
        guard let bit = BitOrder(rawValue: bitRaw) else {
            throw FramerError.invalidEnum(name: "BitOrder", value: UInt32(bitRaw))
        }

        let vendor = try r.readBytes(vendorLen)
        try r.skip(xPad(vendorLen))

        var formats: [PixmapFormat] = []
        formats.reserveCapacity(nFormats)
        for _ in 0..<nFormats {
            formats.append(try PixmapFormat.decode(from: &r))
        }

        var screens: [Screen] = []
        screens.reserveCapacity(nScreens)
        for _ in 0..<nScreens {
            screens.append(try Screen.decode(from: &r))
        }

        return SetupAccepted(
            protocolMajor: major,
            protocolMinor: minor,
            releaseNumber: release,
            resourceIdBase: idBase,
            resourceIdMask: idMask,
            motionBufferSize: motion,
            maximumRequestLength: maxReqLen,
            imageByteOrder: img,
            bitmapFormatBitOrder: bit,
            bitmapFormatScanlineUnit: scanlineUnit,
            bitmapFormatScanlinePad: scanlinePad,
            minKeycode: minKey,
            maxKeycode: maxKey,
            vendor: vendor,
            pixmapFormats: formats,
            screens: screens
        )
    }
}
