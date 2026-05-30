// MIT-SHM extension request wire types.
//
// Six opcodes: QueryVersion(0), Attach(1), Detach(2), PutImage(3),
// GetImage(4), CreatePixmap(5). Wire layouts verified against
// reference/X11R6/xc/include/extensions/shmstr.h.
//
// Each request struct's `encode(majorOpcode:byteOrder:)` matches the
// SHAPE pattern — the major opcode is dynamic (assigned at QueryExtension
// time), the minor is fixed.

public enum ShmMinor {
    public static let queryVersion: UInt8 = 0
    public static let attach: UInt8 = 1
    public static let detach: UInt8 = 2
    public static let putImage: UInt8 = 3
    public static let getImage: UInt8 = 4
    public static let createPixmap: UInt8 = 5
}

// MARK: - ShmQueryVersion (minor 0)

public struct ShmQueryVersion: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.queryVersion
    public init() {}

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmQueryVersion {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        return ShmQueryVersion()
    }
}

// MARK: - ShmAttach (minor 1)

public struct ShmAttach: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.attach

    public var shmseg: UInt32
    public var shmid: UInt32
    public var readOnly: Bool

    public init(shmseg: UInt32, shmid: UInt32, readOnly: Bool) {
        self.shmseg = shmseg; self.shmid = shmid; self.readOnly = readOnly
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(4)
        w.writeUInt32(shmseg)
        w.writeUInt32(shmid)
        w.writeUInt8(readOnly ? 1 : 0); w.writePadding(3)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmAttach {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let shmseg = try r.readUInt32()
        let shmid = try r.readUInt32()
        let readOnly = try r.readUInt8() != 0
        return ShmAttach(shmseg: shmseg, shmid: shmid, readOnly: readOnly)
    }
}

// MARK: - ShmDetach (minor 2)

public struct ShmDetach: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.detach

    public var shmseg: UInt32

    public init(shmseg: UInt32) { self.shmseg = shmseg }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(2)
        w.writeUInt32(shmseg)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmDetach {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let shmseg = try r.readUInt32()
        return ShmDetach(shmseg: shmseg)
    }
}

// MARK: - ShmPutImage (minor 3)

public struct ShmPutImage: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.putImage

    public var drawable: UInt32
    public var gc: UInt32
    public var totalWidth: UInt16
    public var totalHeight: UInt16
    public var srcX: UInt16
    public var srcY: UInt16
    public var srcWidth: UInt16
    public var srcHeight: UInt16
    public var dstX: Int16
    public var dstY: Int16
    public var depth: UInt8
    public var format: UInt8
    public var sendEvent: Bool
    public var shmseg: UInt32
    public var offset: UInt32

    public init(drawable: UInt32, gc: UInt32,
                totalWidth: UInt16, totalHeight: UInt16,
                srcX: UInt16, srcY: UInt16, srcWidth: UInt16, srcHeight: UInt16,
                dstX: Int16, dstY: Int16,
                depth: UInt8, format: UInt8, sendEvent: Bool,
                shmseg: UInt32, offset: UInt32) {
        self.drawable = drawable; self.gc = gc
        self.totalWidth = totalWidth; self.totalHeight = totalHeight
        self.srcX = srcX; self.srcY = srcY
        self.srcWidth = srcWidth; self.srcHeight = srcHeight
        self.dstX = dstX; self.dstY = dstY
        self.depth = depth; self.format = format; self.sendEvent = sendEvent
        self.shmseg = shmseg; self.offset = offset
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(10)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        w.writeUInt16(totalWidth); w.writeUInt16(totalHeight)
        w.writeUInt16(srcX); w.writeUInt16(srcY)
        w.writeUInt16(srcWidth); w.writeUInt16(srcHeight)
        w.writeUInt16(UInt16(bitPattern: dstX)); w.writeUInt16(UInt16(bitPattern: dstY))
        w.writeUInt8(depth); w.writeUInt8(format)
        w.writeUInt8(sendEvent ? 1 : 0); w.writePadding(1)
        w.writeUInt32(shmseg); w.writeUInt32(offset)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmPutImage {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let totalWidth = try r.readUInt16()
        let totalHeight = try r.readUInt16()
        let srcX = try r.readUInt16()
        let srcY = try r.readUInt16()
        let srcWidth = try r.readUInt16()
        let srcHeight = try r.readUInt16()
        let dstX = Int16(bitPattern: try r.readUInt16())
        let dstY = Int16(bitPattern: try r.readUInt16())
        let depth = try r.readUInt8()
        let format = try r.readUInt8()
        let sendEvent = try r.readUInt8() != 0
        try r.skip(1)
        let shmseg = try r.readUInt32()
        let offset = try r.readUInt32()
        return ShmPutImage(
            drawable: drawable, gc: gc,
            totalWidth: totalWidth, totalHeight: totalHeight,
            srcX: srcX, srcY: srcY, srcWidth: srcWidth, srcHeight: srcHeight,
            dstX: dstX, dstY: dstY,
            depth: depth, format: format, sendEvent: sendEvent,
            shmseg: shmseg, offset: offset
        )
    }
}

// MARK: - ShmGetImage (minor 4)

public struct ShmGetImage: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.getImage

    public var drawable: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var planeMask: UInt32
    public var format: UInt8
    public var shmseg: UInt32
    public var offset: UInt32

    public init(drawable: UInt32, x: Int16, y: Int16,
                width: UInt16, height: UInt16,
                planeMask: UInt32, format: UInt8,
                shmseg: UInt32, offset: UInt32) {
        self.drawable = drawable; self.x = x; self.y = y
        self.width = width; self.height = height
        self.planeMask = planeMask; self.format = format
        self.shmseg = shmseg; self.offset = offset
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(8)
        w.writeUInt32(drawable)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt32(planeMask)
        w.writeUInt8(format); w.writePadding(3)
        w.writeUInt32(shmseg); w.writeUInt32(offset)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmGetImage {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let planeMask = try r.readUInt32()
        let format = try r.readUInt8()
        try r.skip(3)
        let shmseg = try r.readUInt32()
        let offset = try r.readUInt32()
        return ShmGetImage(
            drawable: drawable, x: x, y: y,
            width: width, height: height,
            planeMask: planeMask, format: format,
            shmseg: shmseg, offset: offset
        )
    }
}

// MARK: - ShmCreatePixmap (minor 5)

public struct ShmCreatePixmap: Equatable, Sendable {
    public static let minor: UInt8 = ShmMinor.createPixmap

    public var pid: UInt32
    public var drawable: UInt32
    public var width: UInt16
    public var height: UInt16
    public var depth: UInt8
    public var shmseg: UInt32
    public var offset: UInt32

    public init(pid: UInt32, drawable: UInt32,
                width: UInt16, height: UInt16,
                depth: UInt8, shmseg: UInt32, offset: UInt32) {
        self.pid = pid; self.drawable = drawable
        self.width = width; self.height = height
        self.depth = depth; self.shmseg = shmseg; self.offset = offset
    }

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(7)
        w.writeUInt32(pid)
        w.writeUInt32(drawable)
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt8(depth); w.writePadding(3)
        w.writeUInt32(shmseg); w.writeUInt32(offset)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmCreatePixmap {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8(); _ = try r.readUInt16()
        let pid = try r.readUInt32()
        let drawable = try r.readUInt32()
        let width = try r.readUInt16()
        let height = try r.readUInt16()
        let depth = try r.readUInt8()
        try r.skip(3)
        let shmseg = try r.readUInt32()
        let offset = try r.readUInt32()
        return ShmCreatePixmap(
            pid: pid, drawable: drawable,
            width: width, height: height,
            depth: depth, shmseg: shmseg, offset: offset
        )
    }
}
