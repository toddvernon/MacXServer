// ChangeActivePointerGrab request layout (X11 spec section 12;
// Xproto.h xChangeActivePointerGrabReq):
//
//   1 byte:  opcode (30)
//   1 byte:  unused
//   2 bytes: request length = 4
//   4 bytes: cursor (None = 0, or cursor id)
//   4 bytes: time (CurrentTime = 0, or timestamp)
//   2 bytes: event-mask (SETofPOINTEREVENT)
//   2 bytes: unused
//
// Replaces the cursor and event-mask of the currently active pointer grab
// without releasing it. Used by menu code (Xt's `XtPopupSpringLoaded`)
// after posting a popup: the press-time grab covered the menu title widget;
// once the menu maps, this request transfers the grab parameters so motion
// + release events flow through the menu. Without honoring this request
// the menu maps then immediately unmaps because the active grab still
// targets the menu title and the release is interpreted as "click without
// selection → cancel."

public struct ChangeActivePointerGrab: Equatable, Sendable {
    public static let opcode: UInt8 = 30
    public var cursor: UInt32             // None=0
    public var time: UInt32               // CurrentTime=0
    public var eventMask: UInt16

    public init(cursor: UInt32, time: UInt32, eventMask: UInt16) {
        self.cursor = cursor
        self.time = time
        self.eventMask = eventMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)
        w.writeUInt32(cursor)
        w.writeUInt32(time)
        w.writeUInt16(eventMask)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ChangeActivePointerGrab {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let cursor = try r.readUInt32()
        let time = try r.readUInt32()
        let eventMask = try r.readUInt16()
        _ = try r.readUInt16()
        return ChangeActivePointerGrab(cursor: cursor, time: time, eventMask: eventMask)
    }
}
