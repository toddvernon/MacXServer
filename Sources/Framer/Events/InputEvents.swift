// Events that share a 32-byte input-event layout: KeyPress, KeyRelease,
// ButtonPress, ButtonRelease, MotionNotify. Detail byte interpretation varies
// (keycode for keyboard events, button number for buttons, hint flag for motion)
// but the bit layout is identical, so they share one type.

public struct InputEvent: Equatable, Sendable {
    public var detail: UInt8                  // keycode / button / motion-hint
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var root: UInt32
    public var event: UInt32
    public var child: UInt32                  // 0 = None
    public var rootX: Int16
    public var rootY: Int16
    public var eventX: Int16
    public var eventY: Int16
    public var state: UInt16                  // SETofKEYBUTMASK
    public var sameScreen: Bool

    public init(
        detail: UInt8, sequenceNumber: UInt16, time: UInt32,
        root: UInt32, event: UInt32, child: UInt32,
        rootX: Int16, rootY: Int16, eventX: Int16, eventY: Int16,
        state: UInt16, sameScreen: Bool
    ) {
        self.detail = detail
        self.sequenceNumber = sequenceNumber
        self.time = time
        self.root = root
        self.event = event
        self.child = child
        self.rootX = rootX
        self.rootY = rootY
        self.eventX = eventX
        self.eventY = eventY
        self.state = state
        self.sameScreen = sameScreen
    }

    public func encode(code: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(code)
        w.writeUInt8(detail)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt32(root)
        w.writeUInt32(event)
        w.writeUInt32(child)
        w.writeUInt16(UInt16(bitPattern: rootX))
        w.writeUInt16(UInt16(bitPattern: rootY))
        w.writeUInt16(UInt16(bitPattern: eventX))
        w.writeUInt16(UInt16(bitPattern: eventY))
        w.writeUInt16(state)
        w.writeUInt8(sameScreen ? 1 : 0)
        w.writeUInt8(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> InputEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()                             // code
        let detail = try r.readUInt8()
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let root = try r.readUInt32()
        let event = try r.readUInt32()
        let child = try r.readUInt32()
        let rx = Int16(bitPattern: try r.readUInt16())
        let ry = Int16(bitPattern: try r.readUInt16())
        let ex = Int16(bitPattern: try r.readUInt16())
        let ey = Int16(bitPattern: try r.readUInt16())
        let state = try r.readUInt16()
        let same = (try r.readUInt8()) != 0
        try r.skip(1)
        return InputEvent(
            detail: detail, sequenceNumber: seq, time: time,
            root: root, event: event, child: child,
            rootX: rx, rootY: ry, eventX: ex, eventY: ey,
            state: state, sameScreen: same
        )
    }
}

// EnterNotify, LeaveNotify. Same overall layout as InputEvent but the detail
// byte means crossing-detail (Ancestor/Virtual/Inferior/etc.), the trailing
// byte holds mode + same-screen-focus flags.

public enum CrossingDetail: UInt8, Sendable {
    case ancestor = 0
    case virtual = 1
    case inferior = 2
    case nonlinear = 3
    case nonlinearVirtual = 4
}

public enum CrossingMode: UInt8, Sendable {
    case normal = 0
    case grab = 1
    case ungrab = 2
}

public struct CrossingEvent: Equatable, Sendable {
    public var detail: CrossingDetail
    public var sequenceNumber: UInt16
    public var time: UInt32
    public var root: UInt32
    public var event: UInt32
    public var child: UInt32
    public var rootX: Int16
    public var rootY: Int16
    public var eventX: Int16
    public var eventY: Int16
    public var state: UInt16
    public var mode: CrossingMode
    public var sameScreen: Bool
    public var focus: Bool

    public init(
        detail: CrossingDetail, sequenceNumber: UInt16, time: UInt32,
        root: UInt32, event: UInt32, child: UInt32,
        rootX: Int16, rootY: Int16, eventX: Int16, eventY: Int16,
        state: UInt16, mode: CrossingMode, sameScreen: Bool, focus: Bool
    ) {
        self.detail = detail
        self.sequenceNumber = sequenceNumber
        self.time = time
        self.root = root
        self.event = event
        self.child = child
        self.rootX = rootX
        self.rootY = rootY
        self.eventX = eventX
        self.eventY = eventY
        self.state = state
        self.mode = mode
        self.sameScreen = sameScreen
        self.focus = focus
    }

    public func encode(code: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(code)
        w.writeUInt8(detail.rawValue)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(time)
        w.writeUInt32(root)
        w.writeUInt32(event)
        w.writeUInt32(child)
        w.writeUInt16(UInt16(bitPattern: rootX))
        w.writeUInt16(UInt16(bitPattern: rootY))
        w.writeUInt16(UInt16(bitPattern: eventX))
        w.writeUInt16(UInt16(bitPattern: eventY))
        w.writeUInt16(state)
        w.writeUInt8(mode.rawValue)
        var flags: UInt8 = 0
        if focus      { flags |= 0x01 }
        if sameScreen { flags |= 0x02 }
        w.writeUInt8(flags)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CrossingEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let detailRaw = try r.readUInt8()
        guard let detail = CrossingDetail(rawValue: detailRaw) else {
            throw FramerError.invalidEnum(name: "CrossingDetail", value: UInt32(detailRaw))
        }
        let seq = try r.readUInt16()
        let time = try r.readUInt32()
        let root = try r.readUInt32()
        let event = try r.readUInt32()
        let child = try r.readUInt32()
        let rx = Int16(bitPattern: try r.readUInt16())
        let ry = Int16(bitPattern: try r.readUInt16())
        let ex = Int16(bitPattern: try r.readUInt16())
        let ey = Int16(bitPattern: try r.readUInt16())
        let state = try r.readUInt16()
        let modeRaw = try r.readUInt8()
        guard let mode = CrossingMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "CrossingMode", value: UInt32(modeRaw))
        }
        let flags = try r.readUInt8()
        return CrossingEvent(
            detail: detail, sequenceNumber: seq, time: time,
            root: root, event: event, child: child,
            rootX: rx, rootY: ry, eventX: ex, eventY: ey,
            state: state, mode: mode,
            sameScreen: (flags & 0x02) != 0,
            focus: (flags & 0x01) != 0
        )
    }
}

// FocusIn, FocusOut.

public enum FocusDetail: UInt8, Sendable {
    case ancestor = 0
    case virtual = 1
    case inferior = 2
    case nonlinear = 3
    case nonlinearVirtual = 4
    case pointer = 5
    case pointerRoot = 6
    case none = 7
}

public enum FocusMode: UInt8, Sendable {
    case normal = 0
    case grab = 1
    case ungrab = 2
    case whileGrabbed = 3
}

public struct FocusEvent: Equatable, Sendable {
    public var detail: FocusDetail
    public var sequenceNumber: UInt16
    public var event: UInt32
    public var mode: FocusMode

    public init(detail: FocusDetail, sequenceNumber: UInt16, event: UInt32, mode: FocusMode) {
        self.detail = detail
        self.sequenceNumber = sequenceNumber
        self.event = event
        self.mode = mode
    }

    public func encode(code: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(code)
        w.writeUInt8(detail.rawValue)
        w.writeUInt16(sequenceNumber)
        w.writeUInt32(event)
        w.writeUInt8(mode.rawValue)
        w.writePadding(23)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FocusEvent {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let detailRaw = try r.readUInt8()
        guard let detail = FocusDetail(rawValue: detailRaw) else {
            throw FramerError.invalidEnum(name: "FocusDetail", value: UInt32(detailRaw))
        }
        let seq = try r.readUInt16()
        let event = try r.readUInt32()
        let modeRaw = try r.readUInt8()
        guard let mode = FocusMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "FocusMode", value: UInt32(modeRaw))
        }
        return FocusEvent(detail: detail, sequenceNumber: seq, event: event, mode: mode)
    }
}

// KeymapNotify is special: no sequence number, just 31 bytes of bitmap data.
public struct KeymapNotifyEvent: Equatable, Sendable {
    public var keys: [UInt8]                  // exactly 31 bytes

    public init(keys: [UInt8]) {
        precondition(keys.count == 31, "KeymapNotify keys must be 31 bytes")
        self.keys = keys
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(11)
        w.writeBytes(keys)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> KeymapNotifyEvent {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        return KeymapNotifyEvent(keys: Array(bytes[1..<32]))
    }
}
