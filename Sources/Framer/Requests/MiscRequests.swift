// Smaller standalone request opcodes batched together.

public struct AllocNamedColor: Equatable, Sendable {
    public static let opcode: UInt8 = 85
    public var cmap: UInt32
    public var name: [UInt8]

    public init(cmap: UInt32, name: [UInt8]) {
        self.cmap = cmap
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(3 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(cmap)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocNamedColor {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return AllocNamedColor(cmap: cmap, name: name)
    }
}

public struct Bell: Equatable, Sendable {
    public static let opcode: UInt8 = 104
    public var percent: Int8           // -100..100; 0 = default volume

    public init(percent: Int8) {
        self.percent = percent
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(UInt8(bitPattern: percent))
        w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> Bell {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let pct = Int8(bitPattern: try r.readUInt8())
        _ = try r.readUInt16()
        return Bell(percent: pct)
    }
}

public struct QueryExtension: Equatable, Sendable {
    public static let opcode: UInt8 = 98
    public var name: [UInt8]

    public init(name: [UInt8]) {
        self.name = name
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = name.count
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt16(UInt16(n)); w.writeUInt16(0)
        w.writeBytes(name)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryExtension {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let n = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(n)
        try r.skip(xPad(n))
        return QueryExtension(name: name)
    }
}

public enum GetImageFormat: UInt8, Sendable {
    case xyPixmap = 1
    case zPixmap = 2
}

public struct GetImage: Equatable, Sendable {
    public static let opcode: UInt8 = 73
    public var format: GetImageFormat
    public var drawable: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var planeMask: UInt32

    public init(format: GetImageFormat,
                drawable: UInt32,
                x: Int16, y: Int16,
                width: UInt16, height: UInt16,
                planeMask: UInt32) {
        self.format = format
        self.drawable = drawable
        self.x = x; self.y = y
        self.width = width; self.height = height
        self.planeMask = planeMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(format.rawValue); w.writeUInt16(5)
        w.writeUInt32(drawable)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt32(planeMask)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetImage {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let fmtRaw = try r.readUInt8()
        guard let fmt = GetImageFormat(rawValue: fmtRaw) else {
            throw FramerError.invalidEnum(name: "GetImageFormat", value: UInt32(fmtRaw))
        }
        _ = try r.readUInt16()
        let d = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let w = try r.readUInt16()
        let h = try r.readUInt16()
        let pm = try r.readUInt32()
        return GetImage(format: fmt, drawable: d, x: x, y: y, width: w, height: h, planeMask: pm)
    }
}
