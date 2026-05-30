// Reply to BigReqEnable.
// xBigReqEnableReply: type(1=1) + pad(1) + seq(2) + length(4=0) +
// maxRequestSize(4) + 20 bytes pad. 32 bytes total.
public struct BigReqEnableReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var maxRequestSize: UInt32

    public init(sequenceNumber: UInt16, maxRequestSize: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.maxRequestSize = maxRequestSize
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(maxRequestSize)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> BigReqEnableReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let max = try r.readUInt32()
        return BigReqEnableReply(sequenceNumber: seq, maxRequestSize: max)
    }
}
