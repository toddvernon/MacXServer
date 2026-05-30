// MIT-SHM extension event: ShmCompletion.
//
// Wire layout transcribed from
// reference/X11R6/xc/include/extensions/shmstr.h (xShmCompletionEvent).
// Sent to the client when a ShmPutImage call (with sendEvent=true)
// finishes, so the client knows it's safe to reuse the shared-memory
// segment.
//
// `type` is firstEvent + ShmCompletion (offset 0) — the server fills
// it from whatever event-base it advertised at QueryExtension time.

public struct ShmCompletionEvent: Equatable, Sendable {
    public var type: UInt8                // firstEvent + ShmCompletion
    public var sequenceNumber: UInt16
    public var drawable: UInt32
    public var minorEvent: UInt16
    public var majorEvent: UInt8
    public var shmseg: UInt32
    public var offset: UInt32

    public init(type: UInt8, sequenceNumber: UInt16, drawable: UInt32,
                minorEvent: UInt16, majorEvent: UInt8,
                shmseg: UInt32, offset: UInt32) {
        self.type = type
        self.sequenceNumber = sequenceNumber
        self.drawable = drawable
        self.minorEvent = minorEvent
        self.majorEvent = majorEvent
        self.shmseg = shmseg
        self.offset = offset
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(type); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(drawable)
        w.writeUInt16(minorEvent); w.writeUInt8(majorEvent); w.writePadding(1)
        w.writeUInt32(shmseg); w.writeUInt32(offset)
        w.writePadding(12)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ShmCompletionEvent {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let type = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let drawable = try r.readUInt32()
        let minor = try r.readUInt16()
        let major = try r.readUInt8(); try r.skip(1)
        let shmseg = try r.readUInt32()
        let offset = try r.readUInt32()
        return ShmCompletionEvent(
            type: type, sequenceNumber: seq, drawable: drawable,
            minorEvent: minor, majorEvent: major,
            shmseg: shmseg, offset: offset
        )
    }
}
