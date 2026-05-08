// GetGeometry reply layout (X11 spec section 9; Xproto.h xGetGeometryReply):
//
//   1 byte:  marker (1)
//   1 byte:  drawable depth
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= 0)
//   4 bytes: root window
//   2 bytes: x (signed)
//   2 bytes: y (signed)
//   2 bytes: width
//   2 bytes: height
//   2 bytes: border-width
//   2 bytes: unused
//   8 bytes: unused

public struct GetGeometryReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var depth: UInt8
    public var root: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16

    public init(
        sequenceNumber: UInt16, depth: UInt8, root: UInt32,
        x: Int16, y: Int16, width: UInt16, height: UInt16, borderWidth: UInt16
    ) {
        self.sequenceNumber = sequenceNumber
        self.depth = depth
        self.root = root
        self.x = x; self.y = y
        self.width = width; self.height = height
        self.borderWidth = borderWidth
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(depth)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(root)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width)
        w.writeUInt16(height)
        w.writeUInt16(borderWidth)
        w.writePadding(10)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetGeometryReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let depth = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let root = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let borderWidth = try r.readUInt16()
        return GetGeometryReply(
            sequenceNumber: seq, depth: depth, root: root,
            x: x, y: y, width: width, height: height, borderWidth: borderWidth
        )
    }
}
