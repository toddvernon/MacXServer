// Opcode 57 — copies the specified components from src-gc to dst-gc.
// Wire format per X11R6 xCopyGCReq: opcode(1) + pad(1) + length(2=4) +
// srcGC(4) + dstGC(4) + valueMask(4). Total 16 bytes.

public struct CopyGC: Equatable, Sendable {
    public static let opcode: UInt8 = 57

    public var srcGC: UInt32
    public var dstGC: UInt32
    public var valueMask: UInt32

    public init(srcGC: UInt32, dstGC: UInt32, valueMask: UInt32) {
        self.srcGC = srcGC
        self.dstGC = dstGC
        self.valueMask = valueMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(4)
        w.writeUInt32(srcGC)
        w.writeUInt32(dstGC)
        w.writeUInt32(valueMask)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CopyGC {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let srcGC = try r.readUInt32()
        let dstGC = try r.readUInt32()
        let valueMask = try r.readUInt32()
        return CopyGC(srcGC: srcGC, dstGC: dstGC, valueMask: valueMask)
    }
}
