// MIT-SHM reply wire types.
// Wire layouts verified against
// reference/X11R6/xc/include/extensions/shmstr.h.

// MARK: - ShmQueryVersion reply

/// xShmQueryVersionReply: type(1) + sharedPixmaps(1, BOOL) + seq(2) +
/// length(4=0) + majorVersion(2) + minorVersion(2) + uid(2) + gid(2) +
/// pixmapFormat(1) + 1 pad + 2 pad + 12 pad. 32 bytes.
public struct ShmQueryVersionReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var sharedPixmaps: Bool
    public var majorVersion: UInt16
    public var minorVersion: UInt16
    public var uid: UInt16
    public var gid: UInt16
    public var pixmapFormat: UInt8

    public init(sequenceNumber: UInt16, sharedPixmaps: Bool,
                majorVersion: UInt16, minorVersion: UInt16,
                uid: UInt16, gid: UInt16, pixmapFormat: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.sharedPixmaps = sharedPixmaps
        self.majorVersion = majorVersion; self.minorVersion = minorVersion
        self.uid = uid; self.gid = gid
        self.pixmapFormat = pixmapFormat
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(sharedPixmaps ? 1 : 0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt16(majorVersion); w.writeUInt16(minorVersion)
        w.writeUInt16(uid); w.writeUInt16(gid)
        w.writeUInt8(pixmapFormat); w.writePadding(15)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmQueryVersionReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let sharedPixmaps = try r.readUInt8() != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        let uid = try r.readUInt16()
        let gid = try r.readUInt16()
        let pixmapFormat = try r.readUInt8()
        return ShmQueryVersionReply(
            sequenceNumber: seq, sharedPixmaps: sharedPixmaps,
            majorVersion: major, minorVersion: minor,
            uid: uid, gid: gid, pixmapFormat: pixmapFormat
        )
    }
}

// MARK: - ShmGetImage reply

/// xShmGetImageReply: type(1) + depth(1) + seq(2) + length(4=0) +
/// visual(4) + size(4) + 16 bytes pad. 32 bytes.
public struct ShmGetImageReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var depth: UInt8
    public var visual: UInt32
    public var size: UInt32

    public init(sequenceNumber: UInt16, depth: UInt8, visual: UInt32, size: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.depth = depth
        self.visual = visual
        self.size = size
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(depth); w.writeUInt16(sequenceNumber)
        w.writeUInt32(0)
        w.writeUInt32(visual)
        w.writeUInt32(size)
        w.writePadding(16)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmGetImageReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let depth = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let visual = try r.readUInt32()
        let size = try r.readUInt32()
        return ShmGetImageReply(sequenceNumber: seq, depth: depth, visual: visual, size: size)
    }
}
