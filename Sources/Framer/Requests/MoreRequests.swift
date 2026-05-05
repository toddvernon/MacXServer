// More request opcodes added in the second batch.

public struct ReparentWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 7
    public var window: UInt32
    public var parent: UInt32
    public var x: Int16
    public var y: Int16

    public init(window: UInt32, parent: UInt32, x: Int16, y: Int16) {
        self.window = window
        self.parent = parent
        self.x = x
        self.y = y
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)
        w.writeUInt32(window)
        w.writeUInt32(parent)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ReparentWindow {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let parent = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        return ReparentWindow(window: win, parent: parent, x: x, y: y)
    }
}

public struct SetSelectionOwner: Equatable, Sendable {
    public static let opcode: UInt8 = 22
    public var owner: UInt32              // 0 = None
    public var selection: UInt32
    public var time: UInt32               // 0 = CurrentTime

    public init(owner: UInt32, selection: UInt32, time: UInt32 = 0) {
        self.owner = owner
        self.selection = selection
        self.time = time
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)
        w.writeUInt32(owner)
        w.writeUInt32(selection)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetSelectionOwner {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let owner = try r.readUInt32()
        let selection = try r.readUInt32()
        let time = try r.readUInt32()
        return SetSelectionOwner(owner: owner, selection: selection, time: time)
    }
}

public struct GrabPointer: Equatable, Sendable {
    public static let opcode: UInt8 = 26
    public var ownerEvents: Bool
    public var grabWindow: UInt32
    public var eventMask: UInt16
    public var pointerMode: GrabMode
    public var keyboardMode: GrabMode
    public var confineTo: UInt32
    public var cursor: UInt32
    public var time: UInt32

    public init(
        ownerEvents: Bool, grabWindow: UInt32, eventMask: UInt16,
        pointerMode: GrabMode, keyboardMode: GrabMode,
        confineTo: UInt32 = 0, cursor: UInt32 = 0, time: UInt32 = 0
    ) {
        self.ownerEvents = ownerEvents
        self.grabWindow = grabWindow
        self.eventMask = eventMask
        self.pointerMode = pointerMode
        self.keyboardMode = keyboardMode
        self.confineTo = confineTo
        self.cursor = cursor
        self.time = time
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(ownerEvents ? 1 : 0)
        w.writeUInt16(6)
        w.writeUInt32(grabWindow)
        w.writeUInt16(eventMask)
        w.writeUInt8(pointerMode.rawValue)
        w.writeUInt8(keyboardMode.rawValue)
        w.writeUInt32(confineTo)
        w.writeUInt32(cursor)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabPointer {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let oe = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let mask = try r.readUInt16()
        let pmRaw = try r.readUInt8()
        let kmRaw = try r.readUInt8()
        guard let pm = GrabMode(rawValue: pmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(pmRaw))
        }
        guard let km = GrabMode(rawValue: kmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(kmRaw))
        }
        let confine = try r.readUInt32()
        let cursor = try r.readUInt32()
        let time = try r.readUInt32()
        return GrabPointer(
            ownerEvents: oe, grabWindow: win, eventMask: mask,
            pointerMode: pm, keyboardMode: km,
            confineTo: confine, cursor: cursor, time: time
        )
    }
}

public struct UngrabPointer: Equatable, Sendable {
    public static let opcode: UInt8 = 27
    public var time: UInt32

    public init(time: UInt32 = 0) { self.time = time }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(2)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UngrabPointer {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        return UngrabPointer(time: try r.readUInt32())
    }
}

public struct GrabKeyboard: Equatable, Sendable {
    public static let opcode: UInt8 = 31
    public var ownerEvents: Bool
    public var grabWindow: UInt32
    public var time: UInt32
    public var pointerMode: GrabMode
    public var keyboardMode: GrabMode

    public init(
        ownerEvents: Bool, grabWindow: UInt32, time: UInt32 = 0,
        pointerMode: GrabMode, keyboardMode: GrabMode
    ) {
        self.ownerEvents = ownerEvents
        self.grabWindow = grabWindow
        self.time = time
        self.pointerMode = pointerMode
        self.keyboardMode = keyboardMode
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(ownerEvents ? 1 : 0)
        w.writeUInt16(4)
        w.writeUInt32(grabWindow)
        w.writeUInt32(time)
        w.writeUInt8(pointerMode.rawValue)
        w.writeUInt8(keyboardMode.rawValue)
        w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabKeyboard {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let oe = (try r.readUInt8()) != 0
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let time = try r.readUInt32()
        let pmRaw = try r.readUInt8()
        let kmRaw = try r.readUInt8()
        _ = try r.readUInt16()
        guard let pm = GrabMode(rawValue: pmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(pmRaw))
        }
        guard let km = GrabMode(rawValue: kmRaw) else {
            throw FramerError.invalidEnum(name: "GrabMode", value: UInt32(kmRaw))
        }
        return GrabKeyboard(
            ownerEvents: oe, grabWindow: win, time: time,
            pointerMode: pm, keyboardMode: km
        )
    }
}

public struct UngrabKeyboard: Equatable, Sendable {
    public static let opcode: UInt8 = 32
    public var time: UInt32

    public init(time: UInt32 = 0) { self.time = time }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(2)
        w.writeUInt32(time)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UngrabKeyboard {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        return UngrabKeyboard(time: try r.readUInt32())
    }
}

public struct QueryPointer: Equatable, Sendable {
    public static let opcode: UInt8 = 38
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryPointer {
        QueryPointer(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct WarpPointer: Equatable, Sendable {
    public static let opcode: UInt8 = 41
    public var srcWindow: UInt32
    public var dstWindow: UInt32
    public var srcX: Int16
    public var srcY: Int16
    public var srcWidth: UInt16
    public var srcHeight: UInt16
    public var dstX: Int16
    public var dstY: Int16

    public init(
        srcWindow: UInt32, dstWindow: UInt32,
        srcX: Int16, srcY: Int16, srcWidth: UInt16, srcHeight: UInt16,
        dstX: Int16, dstY: Int16
    ) {
        self.srcWindow = srcWindow
        self.dstWindow = dstWindow
        self.srcX = srcX
        self.srcY = srcY
        self.srcWidth = srcWidth
        self.srcHeight = srcHeight
        self.dstX = dstX
        self.dstY = dstY
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(6)
        w.writeUInt32(srcWindow)
        w.writeUInt32(dstWindow)
        w.writeUInt16(UInt16(bitPattern: srcX))
        w.writeUInt16(UInt16(bitPattern: srcY))
        w.writeUInt16(srcWidth)
        w.writeUInt16(srcHeight)
        w.writeUInt16(UInt16(bitPattern: dstX))
        w.writeUInt16(UInt16(bitPattern: dstY))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> WarpPointer {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let src = try r.readUInt32()
        let dst = try r.readUInt32()
        let sx = Int16(bitPattern: try r.readUInt16())
        let sy = Int16(bitPattern: try r.readUInt16())
        let sw = try r.readUInt16()
        let sh = try r.readUInt16()
        let dx = Int16(bitPattern: try r.readUInt16())
        let dy = Int16(bitPattern: try r.readUInt16())
        return WarpPointer(
            srcWindow: src, dstWindow: dst,
            srcX: sx, srcY: sy, srcWidth: sw, srcHeight: sh,
            dstX: dx, dstY: dy
        )
    }
}
