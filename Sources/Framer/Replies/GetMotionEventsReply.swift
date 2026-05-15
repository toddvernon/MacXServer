// GetMotionEvents reply (X11 spec section 9.3 / xGetMotionEventsReply):
//
//   1 byte:   marker (1)
//   1 byte:   unused
//   2 bytes:  sequence number
//   4 bytes:  additional length in 4-byte units = nEvents * 2 (each event
//             is 8 bytes: 4-byte timestamp + 2 INT16 root coords)
//   4 bytes:  nEvents (number of events that follow)
//  20 bytes:  unused
//   then:    nEvents * (Time(4) + INT16 rootX + INT16 rootY)
//
// swift-x doesn't currently maintain a server-side motion-event ring, so
// nEvents is always 0 and the reply is the 32-byte header alone. Real
// behavior would require a configurable motion-buffer-size and a ring of
// pointer-position samples; spec-compliant empty reply is sufficient for
// any client that uses GetMotionEvents to back-poll an idle window.

public struct GetMotionEventsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16

    public init(sequenceNumber: UInt16) {
        self.sequenceNumber = sequenceNumber
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)        // additional length
        w.writeUInt32(0)        // nEvents
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetMotionEventsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        return GetMotionEventsReply(sequenceNumber: seq)
    }
}
