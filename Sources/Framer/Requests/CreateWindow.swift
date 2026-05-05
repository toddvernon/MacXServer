public enum WindowClass: UInt16, Sendable {
    case copyFromParent = 0
    case inputOutput = 1
    case inputOnly = 2
}

public struct CreateWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 1

    public var depth: UInt8
    public var wid: UInt32
    public var parent: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var windowClass: WindowClass
    public var visual: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]

    public init(
        depth: UInt8,
        wid: UInt32,
        parent: UInt32,
        x: Int16,
        y: Int16,
        width: UInt16,
        height: UInt16,
        borderWidth: UInt16,
        windowClass: WindowClass,
        visual: UInt32,
        valueMask: UInt32,
        valueList: [UInt8] = []
    ) {
        precondition(valueList.count % 4 == 0, "valueList must be 4-byte aligned")
        precondition(valueList.count / 4 == valueMask.nonzeroBitCount, "valueList size must match valueMask popcount")
        self.depth = depth
        self.wid = wid
        self.parent = parent
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.borderWidth = borderWidth
        self.windowClass = windowClass
        self.visual = visual
        self.valueMask = valueMask
        self.valueList = valueList
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = valueList.count / 4
        let lenIn4 = UInt16(8 + n)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(depth)
        w.writeUInt16(lenIn4)
        w.writeUInt32(wid)
        w.writeUInt32(parent)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width)
        w.writeUInt16(height)
        w.writeUInt16(borderWidth)
        w.writeUInt16(windowClass.rawValue)
        w.writeUInt32(visual)
        w.writeUInt32(valueMask)
        w.writeBytes(valueList)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreateWindow {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        let depth = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let wid = try r.readUInt32()
        let parent = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let borderWidth = try r.readUInt16()
        let classRaw = try r.readUInt16()
        guard let cls = WindowClass(rawValue: classRaw) else {
            throw FramerError.invalidEnum(name: "WindowClass", value: UInt32(classRaw))
        }
        let visual = try r.readUInt32()
        let valueMask = try r.readUInt32()
        let valueListBytes = (lenIn4 - 8) * 4
        let valueList = try r.readBytes(valueListBytes)
        return CreateWindow(
            depth: depth,
            wid: wid,
            parent: parent,
            x: x,
            y: y,
            width: width,
            height: height,
            borderWidth: borderWidth,
            windowClass: cls,
            visual: visual,
            valueMask: valueMask,
            valueList: valueList
        )
    }
}
