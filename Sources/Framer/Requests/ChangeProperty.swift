public enum PropertyMode: UInt8, Sendable {
    case replace = 0
    case prepend = 1
    case append = 2
}

public enum PropertyFormat: UInt8, Sendable {
    case format8 = 8
    case format16 = 16
    case format32 = 32
}

public struct ChangeProperty: Equatable, Sendable {
    public static let opcode: UInt8 = 18

    public var mode: PropertyMode
    public var window: UInt32
    public var property: UInt32
    public var type: UInt32
    public var format: PropertyFormat
    public var data: [UInt8]

    public init(
        mode: PropertyMode,
        window: UInt32,
        property: UInt32,
        type: UInt32,
        format: PropertyFormat,
        data: [UInt8]
    ) {
        let elementSize = Int(format.rawValue) / 8
        precondition(data.count % elementSize == 0, "data length must be multiple of format/8")
        self.mode = mode
        self.window = window
        self.property = property
        self.type = type
        self.format = format
        self.data = data
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let elementSize = Int(format.rawValue) / 8
        let dataLength = UInt32(data.count / elementSize)
        let p = xPad(data.count)
        let lenIn4 = UInt16(6 + (data.count + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(mode.rawValue)
        w.writeUInt16(lenIn4)
        w.writeUInt32(window)
        w.writeUInt32(property)
        w.writeUInt32(type)
        w.writeUInt8(format.rawValue)
        w.writePadding(3)
        w.writeUInt32(dataLength)
        w.writeBytes(data)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeProperty {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        let modeRaw = try r.readUInt8()
        guard let mode = PropertyMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "PropertyMode", value: UInt32(modeRaw))
        }
        _ = try r.readUInt16()
        let window = try r.readUInt32()
        let property = try r.readUInt32()
        let type = try r.readUInt32()
        let formatRaw = try r.readUInt8()
        guard let format = PropertyFormat(rawValue: formatRaw) else {
            throw FramerError.invalidEnum(name: "PropertyFormat", value: UInt32(formatRaw))
        }
        try r.skip(3)
        let dataLength = Int(try r.readUInt32())
        let elementSize = Int(format.rawValue) / 8
        let dataByteCount = dataLength * elementSize
        let data = try r.readBytes(dataByteCount)
        try r.skip(xPad(dataByteCount))
        return ChangeProperty(
            mode: mode,
            window: window,
            property: property,
            type: type,
            format: format,
            data: data
        )
    }
}
