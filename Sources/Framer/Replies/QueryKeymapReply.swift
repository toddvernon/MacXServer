// QueryKeymap reply layout (X11 spec section 9; Xproto.h xQueryKeymapReply):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: reply length = 2 (8 additional bytes — the reply is 40 bytes
//            total: a normal 32-byte header plus 8 trailing bytes; the 32-byte
//            keymap field straddles the boundary, occupying bytes 8..39 of
//            the on-wire layout)
//   32 bytes: keymap[32]  (one bit per keycode 0..255, LSB-first within byte;
//            keymap[i] >> (k & 7) & 1 == 1 means keycode (i*8 + k) is held)

public struct QueryKeymapReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var keys: [UInt8]   // exactly 32 bytes

    public init(sequenceNumber: UInt16, keys: [UInt8]) {
        precondition(keys.count == 32, "QueryKeymap keys must be 32 bytes")
        self.sequenceNumber = sequenceNumber
        self.keys = keys
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(2)
        w.writeBytes(keys)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryKeymapReply {
        guard bytes.count >= 40 else {
            throw FramerError.truncated(needed: 40, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let keys = try r.readBytes(32)
        return QueryKeymapReply(sequenceNumber: seq, keys: keys)
    }
}
