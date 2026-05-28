// SHAPE extension event: ShapeNotify.
//
// Wire layout transcribed from reference/X11R6/xc/include/extensions/shapestr.h
// (xShapeNotifyEvent). The event `type` byte is the server's assigned event
// base + ShapeNotify (0), so it's dynamic — the server fills it from whatever
// base it advertised in QueryExtension. Sent to clients that have called
// ShapeSelectInput on the window.

public struct ShapeNotifyEvent: Equatable, Sendable {
    public var type: UInt8                    // eventBase + ShapeNotify
    public var kind: UInt8                    // ShapeBounding or ShapeClip
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var time: UInt32
    public var shaped: Bool                   // true if a shape region actually exists

    public init(type: UInt8, kind: UInt8, sequenceNumber: UInt16, window: UInt32,
                x: Int16, y: Int16, width: UInt16, height: UInt16,
                time: UInt32, shaped: Bool) {
        self.type = type; self.kind = kind
        self.sequenceNumber = sequenceNumber; self.window = window
        self.x = x; self.y = y; self.width = width; self.height = height
        self.time = time; self.shaped = shaped
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(kind)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(window)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt32(time)
        w.writeUInt8(shaped ? 1 : 0); w.writeUInt8(0); w.writeUInt16(0)
        w.writeUInt32(0); w.writeUInt32(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShapeNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8()
        let kind = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16()); let y = Int16(bitPattern: try r.readUInt16())
        let width = try r.readUInt16(); let height = try r.readUInt16()
        let time = try r.readUInt32()
        let shaped = (try r.readUInt8()) != 0
        return ShapeNotifyEvent(type: type, kind: kind, sequenceNumber: seq, window: window,
                                x: x, y: y, width: width, height: height, time: time, shaped: shaped)
    }
}
