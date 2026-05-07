// GetKeyboardMapping reply layout (X11 spec section 9.5):
//
//   1 byte:   marker (1)
//   1 byte:   keysymsPerKeycode
//   2 bytes:  sequence number
//   4 bytes:  additional length in 4-byte units (= count * keysymsPerKeycode)
//  24 bytes:  unused
//   N bytes:  LISTofKEYSYM (each KEYSYM is 4 bytes)
//
// `count` is the number of keycodes the request asked for; the reply has
// `count * keysymsPerKeycode` keysym entries, in keycode-then-group order.
// Unmapped slots use NoSymbol (0).

public struct GetKeyboardMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var keysymsPerKeycode: UInt8
    public var keysyms: [UInt32]            // size = count * keysymsPerKeycode

    public init(sequenceNumber: UInt16, keysymsPerKeycode: UInt8, keysyms: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.keysymsPerKeycode = keysymsPerKeycode
        self.keysyms = keysyms
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(keysymsPerKeycode)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(UInt32(keysyms.count))         // each keysym is 1 word = 1 unit
        w.writePadding(24)
        for k in keysyms { w.writeUInt32(k) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetKeyboardMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let kpk = try r.readUInt8()
        let seq = try r.readUInt16()
        let lenIn4 = Int(try r.readUInt32())
        try r.skip(24)
        var keysyms: [UInt32] = []
        keysyms.reserveCapacity(lenIn4)
        for _ in 0..<lenIn4 {
            keysyms.append(try r.readUInt32())
        }
        return GetKeyboardMappingReply(sequenceNumber: seq, keysymsPerKeycode: kpk, keysyms: keysyms)
    }
}
