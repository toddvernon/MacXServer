public enum ImageFormat: UInt8, Sendable {
    case bitmap = 0
    case xyPixmap = 1
    case zPixmap = 2
}

public struct PutImage: Equatable, Sendable {
    public static let opcode: UInt8 = 72

    public var format: ImageFormat
    public var drawable: UInt32
    public var gc: UInt32
    public var width: UInt16
    public var height: UInt16
    public var dstX: Int16
    public var dstY: Int16
    public var leftPad: UInt8
    public var depth: UInt8
    public var data: [UInt8]              // raw image data, byte-order interpretation depends on the connection

    public init(
        format: ImageFormat, drawable: UInt32, gc: UInt32,
        width: UInt16, height: UInt16, dstX: Int16, dstY: Int16,
        leftPad: UInt8, depth: UInt8, data: [UInt8]
    ) {
        self.format = format
        self.drawable = drawable
        self.gc = gc
        self.width = width
        self.height = height
        self.dstX = dstX
        self.dstY = dstY
        self.leftPad = leftPad
        self.depth = depth
        self.data = data
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = data.count
        let p = xPad(n)
        let lenIn4 = UInt16(6 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(format.rawValue)
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        w.writeUInt16(width)
        w.writeUInt16(height)
        w.writeUInt16(UInt16(bitPattern: dstX))
        w.writeUInt16(UInt16(bitPattern: dstY))
        w.writeUInt8(leftPad)
        w.writeUInt8(depth)
        w.writeUInt16(0)
        w.writeBytes(data)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PutImage {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let fmtRaw = try r.readUInt8()
        guard let fmt = ImageFormat(rawValue: fmtRaw) else {
            throw FramerError.invalidEnum(name: "ImageFormat", value: UInt32(fmtRaw))
        }
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let dstX = Int16(bitPattern: try r.readUInt16())
        let dstY = Int16(bitPattern: try r.readUInt16())
        let leftPad = try r.readUInt8()
        let depth = try r.readUInt8()
        _ = try r.readUInt16()
        let totalBodyBytes = (lenIn4 - 6) * 4
        let data = try r.readBytes(totalBodyBytes)
        return PutImage(
            format: fmt, drawable: drawable, gc: gc,
            width: width, height: height, dstX: dstX, dstY: dstY,
            leftPad: leftPad, depth: depth, data: data
        )
    }
}
