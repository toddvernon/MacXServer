// Reply to GetKeyboardControl (opcode 103).
// xGetKeyboardControlReply: type(1=1) + globalAutoRepeat(1) + seq(2) +
// length(4=5) + ledMask(4) + keyClickPercent(1) + bellPercent(1) +
// bellPitch(2) + bellDuration(2) + pad(2) + autoRepeats[32] (bit-vector
// of 256 keys, 1 bit per keycode).
public struct GetKeyboardControlReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var globalAutoRepeat: Bool   // false=Off, true=On
    public var ledMask: UInt32
    public var keyClickPercent: UInt8
    public var bellPercent: UInt8
    public var bellPitch: UInt16
    public var bellDuration: UInt16
    public var autoRepeats: [UInt8]   // 32 bytes, 256 bits — 1 bit per keycode

    public init(sequenceNumber: UInt16, globalAutoRepeat: Bool, ledMask: UInt32,
                keyClickPercent: UInt8, bellPercent: UInt8,
                bellPitch: UInt16, bellDuration: UInt16, autoRepeats: [UInt8]) {
        precondition(autoRepeats.count == 32, "autoRepeats must be exactly 32 bytes")
        self.sequenceNumber = sequenceNumber
        self.globalAutoRepeat = globalAutoRepeat
        self.ledMask = ledMask
        self.keyClickPercent = keyClickPercent
        self.bellPercent = bellPercent
        self.bellPitch = bellPitch
        self.bellDuration = bellDuration
        self.autoRepeats = autoRepeats
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(globalAutoRepeat ? 1 : 0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(5)
        w.writeUInt32(ledMask)
        w.writeUInt8(keyClickPercent); w.writeUInt8(bellPercent)
        w.writeUInt16(bellPitch); w.writeUInt16(bellDuration)
        w.writePadding(2)
        w.writeBytes(autoRepeats)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetKeyboardControlReply {
        guard bytes.count >= 52 else {
            throw FramerError.truncated(needed: 52, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let globalAutoRepeat = try r.readUInt8() != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let ledMask = try r.readUInt32()
        let keyClickPercent = try r.readUInt8()
        let bellPercent = try r.readUInt8()
        let bellPitch = try r.readUInt16()
        let bellDuration = try r.readUInt16()
        try r.skip(2)
        let autoRepeats = try r.readBytes(32)
        return GetKeyboardControlReply(
            sequenceNumber: seq,
            globalAutoRepeat: globalAutoRepeat,
            ledMask: ledMask,
            keyClickPercent: keyClickPercent,
            bellPercent: bellPercent,
            bellPitch: bellPitch,
            bellDuration: bellDuration,
            autoRepeats: autoRepeats
        )
    }
}
