// QueryPointer reply layout (X11 spec section 9; Xproto.h xQueryPointerReply):
//
//   1 byte:  marker (1)
//   1 byte:  same-screen (BOOL)
//   2 bytes: sequence number
//   4 bytes: reply length = 0
//   4 bytes: root window
//   4 bytes: child window (None = 0 if no descendant of root contains pointer)
//   2 bytes: rootX (signed, in root coords)
//   2 bytes: rootY (signed)
//   2 bytes: winX (signed, relative to the queried window)
//   2 bytes: winY (signed)
//   2 bytes: mask (SETofKEYBUTMASK — modifier + button state)
//   2 bytes: unused
//   4 bytes: unused

public struct QueryPointerReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var sameScreen: Bool
    public var root: UInt32
    public var child: UInt32
    public var rootX: Int16
    public var rootY: Int16
    public var winX: Int16
    public var winY: Int16
    public var mask: UInt16

    public init(
        sequenceNumber: UInt16, sameScreen: Bool,
        root: UInt32, child: UInt32,
        rootX: Int16, rootY: Int16, winX: Int16, winY: Int16,
        mask: UInt16
    ) {
        self.sequenceNumber = sequenceNumber
        self.sameScreen = sameScreen
        self.root = root
        self.child = child
        self.rootX = rootX
        self.rootY = rootY
        self.winX = winX
        self.winY = winY
        self.mask = mask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(sameScreen ? 1 : 0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(root)
        w.writeUInt32(child)
        w.writeUInt16(UInt16(bitPattern: rootX))
        w.writeUInt16(UInt16(bitPattern: rootY))
        w.writeUInt16(UInt16(bitPattern: winX))
        w.writeUInt16(UInt16(bitPattern: winY))
        w.writeUInt16(mask)
        w.writePadding(6)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryPointerReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let same = (try r.readUInt8()) != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let root = try r.readUInt32()
        let child = try r.readUInt32()
        let rx = Int16(bitPattern: try r.readUInt16())
        let ry = Int16(bitPattern: try r.readUInt16())
        let wx = Int16(bitPattern: try r.readUInt16())
        let wy = Int16(bitPattern: try r.readUInt16())
        let mask = try r.readUInt16()
        return QueryPointerReply(
            sequenceNumber: seq, sameScreen: same,
            root: root, child: child,
            rootX: rx, rootY: ry, winX: wx, winY: wy,
            mask: mask
        )
    }
}
