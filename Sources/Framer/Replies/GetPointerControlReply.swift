// Reply to GetPointerControl (opcode 106).
// xGetPointerControlReply: type(1=1) + pad(1) + seq(2) + length(4=0) +
// accelNum(2) + accelDen(2) + threshold(2) + 18 bytes of trailing pad.
public struct GetPointerControlReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var accelerationNumerator: UInt16
    public var accelerationDenominator: UInt16
    public var threshold: UInt16

    public init(sequenceNumber: UInt16, accelerationNumerator: UInt16,
                accelerationDenominator: UInt16, threshold: UInt16) {
        self.sequenceNumber = sequenceNumber
        self.accelerationNumerator = accelerationNumerator
        self.accelerationDenominator = accelerationDenominator
        self.threshold = threshold
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(accelerationNumerator)
        w.writeUInt16(accelerationDenominator)
        w.writeUInt16(threshold)
        w.writePadding(18)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetPointerControlReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let accelNum = try r.readUInt16()
        let accelDen = try r.readUInt16()
        let threshold = try r.readUInt16()
        return GetPointerControlReply(
            sequenceNumber: seq,
            accelerationNumerator: accelNum,
            accelerationDenominator: accelDen,
            threshold: threshold
        )
    }
}
