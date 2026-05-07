// GetModifierMapping reply layout (X11 spec section 9.5):
//
//   1 byte:   marker (1)
//   1 byte:   keycodesPerModifier
//   2 bytes:  sequence number
//   4 bytes:  additional length = 2 * keycodesPerModifier (8 modifier groups
//             × keycodesPerModifier keycodes × 1 byte each, /4 for words)
//  24 bytes:  unused
//   N bytes:  LISTofKEYCODE (each 1 byte): 8 modifier groups in fixed order
//             — Shift, Lock, Control, Mod1..Mod5 — each with
//             keycodesPerModifier slots (0 = unmapped).

public struct GetModifierMappingReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var keycodesPerModifier: UInt8
    public var keycodes: [UInt8]            // length = 8 * keycodesPerModifier

    public init(sequenceNumber: UInt16, keycodesPerModifier: UInt8, keycodes: [UInt8]) {
        precondition(keycodes.count == 8 * Int(keycodesPerModifier),
                     "keycodes count must equal 8 * keycodesPerModifier")
        self.sequenceNumber = sequenceNumber
        self.keycodesPerModifier = keycodesPerModifier
        self.keycodes = keycodes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt32(2 * Int(keycodesPerModifier))      // 8 * kpm bytes / 4
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(keycodesPerModifier)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writePadding(24)
        w.writeBytes(keycodes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetModifierMappingReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let kpm = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        try r.skip(24)
        let total = 8 * Int(kpm)
        let codes = try r.readBytes(total)
        return GetModifierMappingReply(sequenceNumber: seq, keycodesPerModifier: kpm, keycodes: codes)
    }
}
