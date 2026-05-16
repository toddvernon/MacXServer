// Window-lifecycle and configuration events.

public struct CreateNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var parent: UInt32
    public var window: UInt32
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var overrideRedirect: Bool

    public init(
        sequenceNumber: UInt16, parent: UInt32, window: UInt32,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        borderWidth: UInt16, overrideRedirect: Bool
    ) {
        self.sequenceNumber = sequenceNumber
        self.parent = parent
        self.window = window
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.borderWidth = borderWidth
        self.overrideRedirect = overrideRedirect
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(16); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(parent); w.writeUInt32(window)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(borderWidth)
        w.writeUInt8(overrideRedirect ? 1 : 0)
        w.writePadding(9)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CreateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let parent = try r.readUInt32(); let window = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16()); let y = Int16(bitPattern: try r.readUInt16())
        let w = try r.readUInt16(); let h = try r.readUInt16()
        let bw = try r.readUInt16()
        let or = (try r.readUInt8()) != 0
        return CreateNotifyEvent(
            sequenceNumber: seq, parent: parent, window: window,
            x: x, y: y, width: w, height: h,
            borderWidth: bw, overrideRedirect: or
        )
    }
}

public struct DestroyNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32

    public init(sequenceNumber: UInt16, event: UInt32, window: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(17); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> DestroyNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32(); let window = try r.readUInt32()
        return DestroyNotifyEvent(sequenceNumber: seq, event: event, window: window)
    }
}

public struct UnmapNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32
    public var fromConfigure: Bool

    public init(sequenceNumber: UInt16, event: UInt32, window: UInt32, fromConfigure: Bool) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
        self.fromConfigure = fromConfigure
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(18); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window)
        w.writeUInt8(fromConfigure ? 1 : 0)
        w.writePadding(19)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UnmapNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32(); let window = try r.readUInt32()
        let fc = (try r.readUInt8()) != 0
        return UnmapNotifyEvent(sequenceNumber: seq, event: event, window: window, fromConfigure: fc)
    }
}

public struct MapNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32
    public var overrideRedirect: Bool

    public init(sequenceNumber: UInt16, event: UInt32, window: UInt32, overrideRedirect: Bool) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
        self.overrideRedirect = overrideRedirect
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(19); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window)
        w.writeUInt8(overrideRedirect ? 1 : 0)
        w.writePadding(19)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> MapNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32(); let window = try r.readUInt32()
        let or = (try r.readUInt8()) != 0
        return MapNotifyEvent(sequenceNumber: seq, event: event, window: window, overrideRedirect: or)
    }
}

public struct MapRequestEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var parent: UInt32
    public var window: UInt32

    public init(sequenceNumber: UInt16, parent: UInt32, window: UInt32) {
        self.sequenceNumber = sequenceNumber
        self.parent = parent
        self.window = window
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(20); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(parent); w.writeUInt32(window)
        w.writePadding(20)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> MapRequestEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let parent = try r.readUInt32(); let window = try r.readUInt32()
        return MapRequestEvent(sequenceNumber: seq, parent: parent, window: window)
    }
}

public struct ReparentNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32
    public var parent: UInt32
    public var x: Int16
    public var y: Int16
    public var overrideRedirect: Bool

    public init(
        sequenceNumber: UInt16, event: UInt32, window: UInt32, parent: UInt32,
        x: Int16, y: Int16, overrideRedirect: Bool
    ) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
        self.parent = parent
        self.x = x
        self.y = y
        self.overrideRedirect = overrideRedirect
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(21); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window); w.writeUInt32(parent)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt8(overrideRedirect ? 1 : 0)
        w.writePadding(11)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ReparentNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32(); let window = try r.readUInt32(); let parent = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16()); let y = Int16(bitPattern: try r.readUInt16())
        let or = (try r.readUInt8()) != 0
        return ReparentNotifyEvent(
            sequenceNumber: seq, event: event, window: window, parent: parent,
            x: x, y: y, overrideRedirect: or
        )
    }
}

public struct ConfigureNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var window: UInt32
    public var aboveSibling: UInt32          // 0 = None
    public var x: Int16
    public var y: Int16
    public var width: UInt16
    public var height: UInt16
    public var borderWidth: UInt16
    public var overrideRedirect: Bool

    public init(
        sequenceNumber: UInt16, event: UInt32, window: UInt32, aboveSibling: UInt32,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        borderWidth: UInt16, overrideRedirect: Bool
    ) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
        self.aboveSibling = aboveSibling
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.borderWidth = borderWidth
        self.overrideRedirect = overrideRedirect
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(22); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window); w.writeUInt32(aboveSibling)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(borderWidth)
        w.writeUInt8(overrideRedirect ? 1 : 0)
        w.writePadding(5)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ConfigureNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32(); let window = try r.readUInt32(); let above = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16()); let y = Int16(bitPattern: try r.readUInt16())
        let w = try r.readUInt16(); let h = try r.readUInt16()
        let bw = try r.readUInt16()
        let or = (try r.readUInt8()) != 0
        return ConfigureNotifyEvent(
            sequenceNumber: seq, event: event, window: window, aboveSibling: above,
            x: x, y: y, width: w, height: h,
            borderWidth: bw, overrideRedirect: or
        )
    }
}

// CirculateNotify event code 26 (per X.h). Per spec, emitted on each
// successful CirculateWindow when a child is restacked. `event` carries
// the substructure-recipient (= window itself for StructureNotifyMask,
// = parent for SubstructureNotifyMask). `place` is 0=Top or 1=Bottom.
public struct CirculateNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var event: UInt32           // recipient — same window as StructureNotify
    public var window: UInt32          // the restacked window
    public var place: UInt8            // 0 Top, 1 Bottom

    public init(sequenceNumber: UInt16, event: UInt32, window: UInt32, place: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.window = window
        self.place = place
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(26); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event); w.writeUInt32(window)
        w.writeUInt32(0)                 // parent — zero on Notify per spec
        w.writeUInt8(place)
        w.writePadding(11)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CirculateNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let event = try r.readUInt32()
        let window = try r.readUInt32()
        _ = try r.readUInt32()
        let place = try r.readUInt8()
        return CirculateNotifyEvent(sequenceNumber: seq, event: event, window: window, place: place)
    }
}
