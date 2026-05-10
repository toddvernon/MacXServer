// QueryTree reply layout (X11 spec section 9; Xproto.h xQueryTreeReply):
//
//   1 byte:  marker (1)
//   1 byte:  unused
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= nChildren)
//   4 bytes: root window
//   4 bytes: parent window (None = 0 if window is the root)
//   2 bytes: nChildren
//   2 bytes: unused
//   14 bytes: unused
//   4*nChildren bytes: child window IDs (top-most last)

public struct QueryTreeReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var root: UInt32
    public var parent: UInt32     // 0 = None (window is the root)
    public var children: [UInt32] // bottom-to-top stacking order

    public init(sequenceNumber: UInt16, root: UInt32, parent: UInt32, children: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.root = root
        self.parent = parent
        self.children = children
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(UInt32(children.count))
        w.writeUInt32(root)
        w.writeUInt32(parent)
        w.writeUInt16(UInt16(children.count))
        w.writePadding(14)
        for child in children {
            w.writeUInt32(child)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryTreeReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let length = try r.readUInt32()
        let root = try r.readUInt32()
        let parent = try r.readUInt32()
        let nChildren = try r.readUInt16()
        try r.skip(14)
        let total = 32 + Int(length) * 4
        guard bytes.count >= total else {
            throw FramerError.truncated(needed: total, available: bytes.count)
        }
        var children: [UInt32] = []
        children.reserveCapacity(Int(nChildren))
        for _ in 0..<Int(nChildren) {
            children.append(try r.readUInt32())
        }
        return QueryTreeReply(sequenceNumber: seq, root: root, parent: parent, children: children)
    }
}
