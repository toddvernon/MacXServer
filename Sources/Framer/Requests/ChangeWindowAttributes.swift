public struct ChangeWindowAttributes: Equatable, Sendable {
    public static let opcode: UInt8 = 2

    public var window: UInt32
    public var valueMask: UInt32
    public var valueList: [UInt8]

    public init(window: UInt32, valueMask: UInt32, valueList: [UInt8] = []) {
        precondition(valueList.count % 4 == 0, "valueList must be 4-byte aligned")
        precondition(valueList.count / 4 == valueMask.nonzeroBitCount, "valueList size must match valueMask popcount")
        self.window = window
        self.valueMask = valueMask
        self.valueList = valueList
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = valueList.count / 4
        let lenIn4 = UInt16(3 + n)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(lenIn4)
        w.writeUInt32(window)
        w.writeUInt32(valueMask)
        w.writeBytes(valueList)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeWindowAttributes {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let window = try r.readUInt32()
        let valueMask = try r.readUInt32()
        let valueListBytes = (lenIn4 - 3) * 4
        let valueList = try r.readBytes(valueListBytes)
        return ChangeWindowAttributes(window: window, valueMask: valueMask, valueList: valueList)
    }
}
