// Reply to ListProperties (opcode 21).
// xListPropertiesReply: type(1=1) + pad(1) + seq(2) + length(4=n) +
// nProperties(2) + 22 bytes pad. Then nProperties ATOMs (4 bytes each).
public struct ListPropertiesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var atoms: [UInt32]

    public init(sequenceNumber: UInt16, atoms: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.atoms = atoms
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = atoms.count
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(UInt32(n))
        w.writeUInt16(UInt16(n))
        w.writePadding(22)
        for a in atoms { w.writeUInt32(a) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListPropertiesReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = Int(try r.readUInt16())
        try r.skip(22)
        var atoms: [UInt32] = []
        atoms.reserveCapacity(n)
        for _ in 0..<n { atoms.append(try r.readUInt32()) }
        return ListPropertiesReply(sequenceNumber: seq, atoms: atoms)
    }
}
