// GetWindowAttributes reply layout (X11 spec section 9; Xproto.h
// xGetWindowAttributesReply, sz=44 — extra-large reply, length field = 3
// in 4-byte units beyond the 32-byte header so total = 32+12 = 44):
//
//   1 byte:  marker (1)
//   1 byte:  backing-store enum (NotUseful=0, WhenMapped=1, Always=2)
//   2 bytes: sequence number
//   4 bytes: reply length in 4-byte units (= 3)
//   4 bytes: visualID
//   2 bytes: class (InputOutput=1, InputOnly=2, CopyFromParent=0)
//   1 byte:  bit-gravity (Forget=0..Static=10)
//   1 byte:  win-gravity (Unmap=0..Static=10)
//   4 bytes: backing-bit-planes
//   4 bytes: backing-pixel
//   1 byte:  save-under bool
//   1 byte:  map-is-installed bool
//   1 byte:  map-state (Unmapped=0, Unviewable=1, Viewable=2)
//   1 byte:  override-redirect bool
//   4 bytes: colormap (or None)
//   4 bytes: all-event-masks
//   4 bytes: your-event-mask
//   2 bytes: do-not-propagate-mask
//   2 bytes: unused

public struct GetWindowAttributesReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var backingStore: UInt8           // 0/1/2
    public var visualId: UInt32
    public var windowClass: UInt16           // 0/1/2
    public var bitGravity: UInt8
    public var winGravity: UInt8
    public var backingBitPlanes: UInt32
    public var backingPixel: UInt32
    public var saveUnder: Bool
    public var mapInstalled: Bool
    public var mapState: UInt8                // 0/1/2
    public var overrideRedirect: Bool
    public var colormap: UInt32               // or 0 = None
    public var allEventMasks: UInt32
    public var yourEventMask: UInt32
    public var doNotPropagateMask: UInt16

    public init(
        sequenceNumber: UInt16,
        backingStore: UInt8 = 0,
        visualId: UInt32,
        windowClass: UInt16,
        bitGravity: UInt8 = 0, winGravity: UInt8 = 0,
        backingBitPlanes: UInt32 = 0, backingPixel: UInt32 = 0,
        saveUnder: Bool = false, mapInstalled: Bool = true,
        mapState: UInt8 = 2, overrideRedirect: Bool = false,
        colormap: UInt32, allEventMasks: UInt32, yourEventMask: UInt32,
        doNotPropagateMask: UInt16 = 0
    ) {
        self.sequenceNumber = sequenceNumber
        self.backingStore = backingStore
        self.visualId = visualId
        self.windowClass = windowClass
        self.bitGravity = bitGravity
        self.winGravity = winGravity
        self.backingBitPlanes = backingBitPlanes
        self.backingPixel = backingPixel
        self.saveUnder = saveUnder
        self.mapInstalled = mapInstalled
        self.mapState = mapState
        self.overrideRedirect = overrideRedirect
        self.colormap = colormap
        self.allEventMasks = allEventMasks
        self.yourEventMask = yourEventMask
        self.doNotPropagateMask = doNotPropagateMask
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)
        w.writeUInt8(backingStore)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(3)
        w.writeUInt32(visualId)
        w.writeUInt16(windowClass)
        w.writeUInt8(bitGravity)
        w.writeUInt8(winGravity)
        w.writeUInt32(backingBitPlanes)
        w.writeUInt32(backingPixel)
        w.writeUInt8(saveUnder ? 1 : 0)
        w.writeUInt8(mapInstalled ? 1 : 0)
        w.writeUInt8(mapState)
        w.writeUInt8(overrideRedirect ? 1 : 0)
        w.writeUInt32(colormap)
        w.writeUInt32(allEventMasks)
        w.writeUInt32(yourEventMask)
        w.writeUInt16(doNotPropagateMask)
        w.writePadding(2)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetWindowAttributesReply {
        guard bytes.count >= 44 else {
            throw FramerError.truncated(needed: 44, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let bs = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let visual = try r.readUInt32()
        let cls = try r.readUInt16()
        let bg = try r.readUInt8()
        let wg = try r.readUInt8()
        let bbp = try r.readUInt32()
        let bp = try r.readUInt32()
        let su = (try r.readUInt8()) != 0
        let mi = (try r.readUInt8()) != 0
        let ms = try r.readUInt8()
        let or = (try r.readUInt8()) != 0
        let cmap = try r.readUInt32()
        let aem = try r.readUInt32()
        let yem = try r.readUInt32()
        let dnp = try r.readUInt16()
        try r.skip(2)
        return GetWindowAttributesReply(
            sequenceNumber: seq, backingStore: bs,
            visualId: visual, windowClass: cls,
            bitGravity: bg, winGravity: wg,
            backingBitPlanes: bbp, backingPixel: bp,
            saveUnder: su, mapInstalled: mi,
            mapState: ms, overrideRedirect: or,
            colormap: cmap, allEventMasks: aem, yourEventMask: yem,
            doNotPropagateMask: dnp
        )
    }
}
