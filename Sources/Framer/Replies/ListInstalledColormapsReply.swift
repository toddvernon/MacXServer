// ListInstalledColormaps reply (X11 spec section 8.5 /
// xListInstalledColormapsReply):
//
//   1 byte:   marker (1)
//   1 byte:   unused
//   2 bytes:  sequence number
//   4 bytes:  additional length in 4-byte units = nColormaps
//   2 bytes:  nColormaps
//   2 bytes:  unused
//  20 bytes:  unused
//   then:    nColormaps × 4 bytes = list of colormap IDs
//
// swift-x advertises one colormap (the default); on a real X server this
// would be the list of cmaps currently "installed" on the screen's
// hardware lookup table. For our TrueColor-backed PseudoColor the
// concept doesn't apply, but spec wants a list reply; we return the
// default cmap as the single installed entry.

public struct ListInstalledColormapsReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var colormaps: [UInt32]

    public init(sequenceNumber: UInt16, colormaps: [UInt32]) {
        self.sequenceNumber = sequenceNumber
        self.colormaps = colormaps
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(UInt32(colormaps.count))    // additional length
        w.writeUInt16(UInt16(colormaps.count))    // nColormaps
        w.writePadding(22)
        for cmap in colormaps {
            w.writeUInt32(cmap)
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListInstalledColormapsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let n = Int(try r.readUInt16())
        try r.skip(22)
        var cmaps: [UInt32] = []
        cmaps.reserveCapacity(n)
        for _ in 0..<n {
            cmaps.append(try r.readUInt32())
        }
        return ListInstalledColormapsReply(sequenceNumber: seq, colormaps: cmaps)
    }
}
