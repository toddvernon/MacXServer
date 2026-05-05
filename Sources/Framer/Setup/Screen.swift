public enum BackingStores: UInt8, Sendable {
    case never = 0
    case whenMapped = 1
    case always = 2
}

public enum VisualClass: UInt8, Sendable {
    case staticGray = 0
    case grayScale = 1
    case staticColor = 2
    case pseudoColor = 3
    case trueColor = 4
    case directColor = 5
}

public struct VisualType: Equatable, Sendable {
    public var visualId: UInt32
    public var visualClass: VisualClass
    public var bitsPerRgbValue: UInt8
    public var colormapEntries: UInt16
    public var redMask: UInt32
    public var greenMask: UInt32
    public var blueMask: UInt32

    public init(
        visualId: UInt32,
        visualClass: VisualClass,
        bitsPerRgbValue: UInt8,
        colormapEntries: UInt16,
        redMask: UInt32,
        greenMask: UInt32,
        blueMask: UInt32
    ) {
        self.visualId = visualId
        self.visualClass = visualClass
        self.bitsPerRgbValue = bitsPerRgbValue
        self.colormapEntries = colormapEntries
        self.redMask = redMask
        self.greenMask = greenMask
        self.blueMask = blueMask
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt32(visualId)
        writer.writeUInt8(visualClass.rawValue)
        writer.writeUInt8(bitsPerRgbValue)
        writer.writeUInt16(colormapEntries)
        writer.writeUInt32(redMask)
        writer.writeUInt32(greenMask)
        writer.writeUInt32(blueMask)
        writer.writePadding(4)
    }

    static func decode(from reader: inout ByteReader) throws -> VisualType {
        let id = try reader.readUInt32()
        let classRaw = try reader.readUInt8()
        guard let cls = VisualClass(rawValue: classRaw) else {
            throw FramerError.invalidEnum(name: "VisualClass", value: UInt32(classRaw))
        }
        let bpr = try reader.readUInt8()
        let entries = try reader.readUInt16()
        let red = try reader.readUInt32()
        let green = try reader.readUInt32()
        let blue = try reader.readUInt32()
        try reader.skip(4)
        return VisualType(
            visualId: id,
            visualClass: cls,
            bitsPerRgbValue: bpr,
            colormapEntries: entries,
            redMask: red,
            greenMask: green,
            blueMask: blue
        )
    }
}

public struct Depth: Equatable, Sendable {
    public var depth: UInt8
    public var visuals: [VisualType]

    public init(depth: UInt8, visuals: [VisualType]) {
        self.depth = depth
        self.visuals = visuals
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt8(depth)
        writer.writePadding(1)
        writer.writeUInt16(UInt16(visuals.count))
        writer.writePadding(4)
        for v in visuals { v.encode(into: &writer) }
    }

    static func decode(from reader: inout ByteReader) throws -> Depth {
        let depth = try reader.readUInt8()
        try reader.skip(1)
        let nVisuals = Int(try reader.readUInt16())
        try reader.skip(4)
        var visuals: [VisualType] = []
        visuals.reserveCapacity(nVisuals)
        for _ in 0..<nVisuals {
            visuals.append(try VisualType.decode(from: &reader))
        }
        return Depth(depth: depth, visuals: visuals)
    }
}

public struct Screen: Equatable, Sendable {
    public var root: UInt32
    public var defaultColormap: UInt32
    public var whitePixel: UInt32
    public var blackPixel: UInt32
    public var currentInputMasks: UInt32
    public var widthInPixels: UInt16
    public var heightInPixels: UInt16
    public var widthInMillimeters: UInt16
    public var heightInMillimeters: UInt16
    public var minInstalledMaps: UInt16
    public var maxInstalledMaps: UInt16
    public var rootVisual: UInt32
    public var backingStores: BackingStores
    public var saveUnders: Bool
    public var rootDepth: UInt8
    public var allowedDepths: [Depth]

    public init(
        root: UInt32,
        defaultColormap: UInt32,
        whitePixel: UInt32,
        blackPixel: UInt32,
        currentInputMasks: UInt32,
        widthInPixels: UInt16,
        heightInPixels: UInt16,
        widthInMillimeters: UInt16,
        heightInMillimeters: UInt16,
        minInstalledMaps: UInt16,
        maxInstalledMaps: UInt16,
        rootVisual: UInt32,
        backingStores: BackingStores,
        saveUnders: Bool,
        rootDepth: UInt8,
        allowedDepths: [Depth]
    ) {
        self.root = root
        self.defaultColormap = defaultColormap
        self.whitePixel = whitePixel
        self.blackPixel = blackPixel
        self.currentInputMasks = currentInputMasks
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.widthInMillimeters = widthInMillimeters
        self.heightInMillimeters = heightInMillimeters
        self.minInstalledMaps = minInstalledMaps
        self.maxInstalledMaps = maxInstalledMaps
        self.rootVisual = rootVisual
        self.backingStores = backingStores
        self.saveUnders = saveUnders
        self.rootDepth = rootDepth
        self.allowedDepths = allowedDepths
    }

    func encode(into writer: inout ByteWriter) {
        writer.writeUInt32(root)
        writer.writeUInt32(defaultColormap)
        writer.writeUInt32(whitePixel)
        writer.writeUInt32(blackPixel)
        writer.writeUInt32(currentInputMasks)
        writer.writeUInt16(widthInPixels)
        writer.writeUInt16(heightInPixels)
        writer.writeUInt16(widthInMillimeters)
        writer.writeUInt16(heightInMillimeters)
        writer.writeUInt16(minInstalledMaps)
        writer.writeUInt16(maxInstalledMaps)
        writer.writeUInt32(rootVisual)
        writer.writeUInt8(backingStores.rawValue)
        writer.writeUInt8(saveUnders ? 1 : 0)
        writer.writeUInt8(rootDepth)
        writer.writeUInt8(UInt8(allowedDepths.count))
        for d in allowedDepths { d.encode(into: &writer) }
    }

    static func decode(from reader: inout ByteReader) throws -> Screen {
        let root = try reader.readUInt32()
        let defaultColormap = try reader.readUInt32()
        let whitePixel = try reader.readUInt32()
        let blackPixel = try reader.readUInt32()
        let currentInputMasks = try reader.readUInt32()
        let widthPx = try reader.readUInt16()
        let heightPx = try reader.readUInt16()
        let widthMm = try reader.readUInt16()
        let heightMm = try reader.readUInt16()
        let minMaps = try reader.readUInt16()
        let maxMaps = try reader.readUInt16()
        let rootVisual = try reader.readUInt32()
        let backingRaw = try reader.readUInt8()
        guard let backing = BackingStores(rawValue: backingRaw) else {
            throw FramerError.invalidEnum(name: "BackingStores", value: UInt32(backingRaw))
        }
        let saveUnders = (try reader.readUInt8()) != 0
        let rootDepth = try reader.readUInt8()
        let nDepths = Int(try reader.readUInt8())
        var depths: [Depth] = []
        depths.reserveCapacity(nDepths)
        for _ in 0..<nDepths {
            depths.append(try Depth.decode(from: &reader))
        }
        return Screen(
            root: root,
            defaultColormap: defaultColormap,
            whitePixel: whitePixel,
            blackPixel: blackPixel,
            currentInputMasks: currentInputMasks,
            widthInPixels: widthPx,
            heightInPixels: heightPx,
            widthInMillimeters: widthMm,
            heightInMillimeters: heightMm,
            minInstalledMaps: minMaps,
            maxInstalledMaps: maxMaps,
            rootVisual: rootVisual,
            backingStores: backing,
            saveUnders: saveUnders,
            rootDepth: rootDepth,
            allowedDepths: depths
        )
    }
}
