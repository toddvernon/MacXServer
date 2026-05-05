// Drawing-related, visibility, property, and mapping events.

// GraphicsExposure: like Expose but generated for CopyArea/CopyPlane operations
// when source regions were obscured. Carries the major/minor opcode of the
// triggering request so clients can correlate.
public struct GraphicsExposureEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var drawable: UInt32
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    public var minorOpcode: UInt16
    public var count: UInt16
    public var majorOpcode: UInt8

    public init(
        sequenceNumber: UInt16, drawable: UInt32,
        x: UInt16, y: UInt16, width: UInt16, height: UInt16,
        minorOpcode: UInt16, count: UInt16, majorOpcode: UInt8
    ) {
        self.sequenceNumber = sequenceNumber
        self.drawable = drawable
        self.x = x; self.y = y; self.width = width; self.height = height
        self.minorOpcode = minorOpcode
        self.count = count
        self.majorOpcode = majorOpcode
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(13); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(drawable)
        w.writeUInt16(x); w.writeUInt16(y)
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(minorOpcode)
        w.writeUInt16(count)
        w.writeUInt8(majorOpcode)
        w.writePadding(11)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GraphicsExposureEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let drawable = try r.readUInt32()
        let x = try r.readUInt16(); let y = try r.readUInt16()
        let w = try r.readUInt16(); let h = try r.readUInt16()
        let minor = try r.readUInt16()
        let count = try r.readUInt16()
        let major = try r.readUInt8()
        return GraphicsExposureEvent(
            sequenceNumber: seq, drawable: drawable,
            x: x, y: y, width: w, height: h,
            minorOpcode: minor, count: count, majorOpcode: major
        )
    }
}

// NoExposure: sent after a CopyArea / CopyPlane that copied from a source with
// no obscured regions, so no GraphicsExpose follow-ups are coming.
public struct NoExposureEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var drawable: UInt32
    public var minorOpcode: UInt16
    public var majorOpcode: UInt8

    public init(sequenceNumber: UInt16, drawable: UInt32, minorOpcode: UInt16, majorOpcode: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.drawable = drawable
        self.minorOpcode = minorOpcode
        self.majorOpcode = majorOpcode
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(14); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(drawable)
        w.writeUInt16(minorOpcode)
        w.writeUInt8(majorOpcode)
        w.writePadding(21)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> NoExposureEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let drawable = try r.readUInt32()
        let minor = try r.readUInt16()
        let major = try r.readUInt8()
        return NoExposureEvent(
            sequenceNumber: seq, drawable: drawable,
            minorOpcode: minor, majorOpcode: major
        )
    }
}

public struct ExposeEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    public var count: UInt16

    public init(
        sequenceNumber: UInt16, window: UInt32,
        x: UInt16, y: UInt16, width: UInt16, height: UInt16, count: UInt16
    ) {
        self.sequenceNumber = sequenceNumber
        self.window = window
        self.x = x; self.y = y; self.width = width; self.height = height
        self.count = count
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(12); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(window)
        w.writeUInt16(x); w.writeUInt16(y)
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(count)
        w.writePadding(14)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ExposeEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let x = try r.readUInt16(); let y = try r.readUInt16()
        let w = try r.readUInt16(); let h = try r.readUInt16()
        let count = try r.readUInt16()
        return ExposeEvent(sequenceNumber: seq, window: window, x: x, y: y, width: w, height: h, count: count)
    }
}

public enum VisibilityState: UInt8, Sendable {
    case unobscured = 0
    case partiallyObscured = 1
    case fullyObscured = 2
}

public struct VisibilityNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var state: VisibilityState

    public init(sequenceNumber: UInt16, window: UInt32, state: VisibilityState) {
        self.sequenceNumber = sequenceNumber
        self.window = window
        self.state = state
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(15); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(window)
        w.writeUInt8(state.rawValue)
        w.writePadding(23)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> VisibilityNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32()
        let stateRaw = try r.readUInt8()
        guard let state = VisibilityState(rawValue: stateRaw) else {
            throw FramerError.invalidEnum(name: "VisibilityState", value: UInt32(stateRaw))
        }
        return VisibilityNotifyEvent(sequenceNumber: seq, window: window, state: state)
    }
}

public enum PropertyState: UInt8, Sendable {
    case newValue = 0
    case deleted = 1
}

public struct PropertyNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var window: UInt32
    public var atom: UInt32
    public var time: UInt32
    public var state: PropertyState

    public init(sequenceNumber: UInt16, window: UInt32, atom: UInt32, time: UInt32, state: PropertyState) {
        self.sequenceNumber = sequenceNumber
        self.window = window
        self.atom = atom
        self.time = time
        self.state = state
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(28); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(window); w.writeUInt32(atom); w.writeUInt32(time)
        w.writeUInt8(state.rawValue)
        w.writePadding(15)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PropertyNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let window = try r.readUInt32(); let atom = try r.readUInt32(); let time = try r.readUInt32()
        let stateRaw = try r.readUInt8()
        guard let state = PropertyState(rawValue: stateRaw) else {
            throw FramerError.invalidEnum(name: "PropertyState", value: UInt32(stateRaw))
        }
        return PropertyNotifyEvent(sequenceNumber: seq, window: window, atom: atom, time: time, state: state)
    }
}

public enum MappingRequest: UInt8, Sendable {
    case modifier = 0
    case keyboard = 1
    case pointer = 2
}

public struct MappingNotifyEvent: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var request: MappingRequest
    public var firstKeycode: UInt8
    public var count: UInt8

    public init(sequenceNumber: UInt16, request: MappingRequest, firstKeycode: UInt8, count: UInt8) {
        self.sequenceNumber = sequenceNumber
        self.request = request
        self.firstKeycode = firstKeycode
        self.count = count
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(34); w.writeUInt8(0)
        w.writeUInt16(sequenceNumber)
        w.writeUInt8(request.rawValue)
        w.writeUInt8(firstKeycode)
        w.writeUInt8(count)
        w.writePadding(25)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> MappingNotifyEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        let reqRaw = try r.readUInt8()
        guard let req = MappingRequest(rawValue: reqRaw) else {
            throw FramerError.invalidEnum(name: "MappingRequest", value: UInt32(reqRaw))
        }
        let first = try r.readUInt8()
        let count = try r.readUInt8()
        return MappingNotifyEvent(sequenceNumber: seq, request: req, firstKeycode: first, count: count)
    }
}
