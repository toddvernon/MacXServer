public struct InternAtomReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var atom: UInt32           // 0 = None (when onlyIfExists=true and not found)

    public init(sequenceNumber: UInt16, atom: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.atom = atom
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(atom)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> InternAtomReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let atom = try r.readUInt32()
        return InternAtomReply(sequenceNumber: seq, atom: atom)
    }
}
