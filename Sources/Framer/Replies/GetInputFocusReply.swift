// GetInputFocus reply layout (X11 spec section 9.5):
//
//   1 byte:  marker (1)
//   1 byte:  revert-to (None=0, PointerRoot=1, Parent=2)
//   2 bytes: sequence number
//   4 bytes: additional length = 0
//   4 bytes: focus window (None=0, PointerRoot=1, or a window ID)
//  20 bytes: unused

public enum FocusRevertTo: UInt8, Sendable {
    case none = 0
    case pointerRoot = 1
    case parent = 2
}

public struct GetInputFocusReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var revertTo: FocusRevertTo
    public var focus: UInt32

    public init(sequenceNumber: UInt16, revertTo: FocusRevertTo, focus: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.revertTo = revertTo
        self.focus = focus
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(revertTo.rawValue)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(focus)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetInputFocusReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let revertRaw = try r.readUInt8()
        guard let revertTo = FocusRevertTo(rawValue: revertRaw) else {
            throw FramerError.invalidEnum(name: "FocusRevertTo", value: UInt32(revertRaw))
        }
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let focus = try r.readUInt32()
        return GetInputFocusReply(sequenceNumber: seq, revertTo: revertTo, focus: focus)
    }
}
