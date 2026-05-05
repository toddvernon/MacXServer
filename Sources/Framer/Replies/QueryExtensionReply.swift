public struct QueryExtensionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var present: Bool
    public var majorOpcode: UInt8     // dynamically assigned (128..255), 0 if not present
    public var firstEvent: UInt8
    public var firstError: UInt8

    public init(sequenceNumber: UInt16, present: Bool, majorOpcode: UInt8, firstEvent: UInt8, firstError: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.present = present
        self.majorOpcode = majorOpcode
        self.firstEvent = firstEvent
        self.firstError = firstError
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)              // additional length = 0
        w.writeUInt8(present ? 1 : 0)
        w.writeUInt8(majorOpcode)
        w.writeUInt8(firstEvent)
        w.writeUInt8(firstError)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryExtensionReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let present = (try r.readUInt8()) != 0
        let major = try r.readUInt8()
        let firstEvt = try r.readUInt8()
        let firstErr = try r.readUInt8()
        return QueryExtensionReply(
            sequenceNumber: seq, present: present,
            majorOpcode: major, firstEvent: firstEvt, firstError: firstErr
        )
    }
}
