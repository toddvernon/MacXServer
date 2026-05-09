// GrabPointer / GrabKeyboard reply (X11 spec sections 9.4 and 9.6).
// Both replies have the same layout — 32 bytes total with a status byte
// in the place of the usual reply prefix. The X11 protocol distinguishes
// them only by which request the client correlates the reply to.
//
//   1 byte:  marker (1)
//   1 byte:  status (Success=0, AlreadyGrabbed=1, InvalidTime=2,
//                    NotViewable=3, Frozen=4)
//   2 bytes: sequence number
//   4 bytes: additional length = 0
//  24 bytes: unused

public enum GrabStatus: UInt8, Sendable {
    case success = 0
    case alreadyGrabbed = 1
    case invalidTime = 2
    case notViewable = 3
    case frozen = 4
}

public struct GrabReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var status: GrabStatus

    public init(sequenceNumber: UInt16, status: GrabStatus) {
        self.sequenceNumber = sequenceNumber
        self.status = status
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(status.rawValue)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writePadding(24)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let statusRaw = try r.readUInt8()
        guard let status = GrabStatus(rawValue: statusRaw) else {
            throw FramerError.invalidEnum(name: "GrabStatus", value: UInt32(statusRaw))
        }
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        return GrabReply(sequenceNumber: seq, status: status)
    }
}
