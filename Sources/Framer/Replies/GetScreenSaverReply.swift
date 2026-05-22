// GetScreenSaver reply layout (X11 spec section 9):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: additional length = 0
//   2 bytes: timeout (seconds, 0 = disabled)
//   2 bytes: interval (seconds)
//   1 byte:  preferBlanking (0 No, 1 Yes)
//   1 byte:  allowExposures (0 No, 1 Yes)
//  18 bytes: unused

public struct GetScreenSaverReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var timeout: UInt16
    public var interval: UInt16
    public var preferBlanking: UInt8
    public var allowExposures: UInt8

    public init(sequenceNumber: UInt16,
                timeout: UInt16 = 0,
                interval: UInt16 = 0,
                preferBlanking: UInt8 = 0,
                allowExposures: UInt8 = 0) {
        self.sequenceNumber = sequenceNumber
        self.timeout = timeout
        self.interval = interval
        self.preferBlanking = preferBlanking
        self.allowExposures = allowExposures
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(timeout)
        w.writeUInt16(interval)
        w.writeUInt8(preferBlanking)
        w.writeUInt8(allowExposures)
        w.writePadding(18)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetScreenSaverReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let to = try r.readUInt16()
        let iv = try r.readUInt16()
        let pb = try r.readUInt8()
        let ae = try r.readUInt8()
        return GetScreenSaverReply(sequenceNumber: seq, timeout: to, interval: iv,
                                   preferBlanking: pb, allowExposures: ae)
    }
}
