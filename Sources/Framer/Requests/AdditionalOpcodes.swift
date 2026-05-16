// Opcodes added 2026-05-14 to close framer-decoder gaps surfaced by the
// xorg/XQuartz comparison study. Pre-this-change, requests for these
// opcodes fell through to Request.unknown and the server emitted
// BadRequest — semantically wrong for spec-defined opcodes. Xt's color
// converter, for example, gates on BadAlloc from AllocColorCells to fall
// back to read-only AllocColor; BadRequest got logged as "server is
// broken." Wire layouts are from X11R6 Xproto.h.

public struct UngrabButton: Equatable, Sendable {
    public static let opcode: UInt8 = 29
    public var button: UInt8           // AnyButton = 0
    public var grabWindow: UInt32
    public var modifiers: UInt16       // AnyModifier = 0x8000

    public init(button: UInt8, grabWindow: UInt32, modifiers: UInt16) {
        self.button = button; self.grabWindow = grabWindow; self.modifiers = modifiers
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(button)
        w.writeUInt16(3)                // length in 4-byte units (= 12 bytes)
        w.writeUInt32(grabWindow)
        w.writeUInt16(modifiers)
        w.writeUInt16(0)                // pad
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UngrabButton {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let button = try r.readUInt8()
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let mods = try r.readUInt16()
        _ = try r.readUInt16()
        return UngrabButton(button: button, grabWindow: win, modifiers: mods)
    }
}

public struct UngrabKey: Equatable, Sendable {
    public static let opcode: UInt8 = 34
    public var key: UInt8              // AnyKey = 0
    public var grabWindow: UInt32
    public var modifiers: UInt16

    public init(key: UInt8, grabWindow: UInt32, modifiers: UInt16) {
        self.key = key; self.grabWindow = grabWindow; self.modifiers = modifiers
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(key)
        w.writeUInt16(3)
        w.writeUInt32(grabWindow)
        w.writeUInt16(modifiers)
        w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UngrabKey {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let key = try r.readUInt8()
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let mods = try r.readUInt16()
        _ = try r.readUInt16()
        return UngrabKey(key: key, grabWindow: win, modifiers: mods)
    }
}

public struct GetMotionEvents: Equatable, Sendable {
    public static let opcode: UInt8 = 39
    public var window: UInt32
    public var start: UInt32           // Time
    public var stop: UInt32            // Time

    public init(window: UInt32, start: UInt32, stop: UInt32) {
        self.window = window; self.start = start; self.stop = stop
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(4)                // 16-byte request
        w.writeUInt32(window)
        w.writeUInt32(start)
        w.writeUInt32(stop)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetMotionEvents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let win = try r.readUInt32()
        let start = try r.readUInt32()
        let stop = try r.readUInt32()
        return GetMotionEvents(window: win, start: start, stop: stop)
    }
}

public struct AllocColorCells: Equatable, Sendable {
    public static let opcode: UInt8 = 86
    public var contiguous: Bool
    public var cmap: UInt32
    public var colors: UInt16
    public var planes: UInt16

    public init(contiguous: Bool, cmap: UInt32, colors: UInt16, planes: UInt16) {
        self.contiguous = contiguous; self.cmap = cmap
        self.colors = colors; self.planes = planes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(contiguous ? 1 : 0)
        w.writeUInt16(3)
        w.writeUInt32(cmap)
        w.writeUInt16(colors)
        w.writeUInt16(planes)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> AllocColorCells {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let contig = try r.readUInt8() != 0
        _ = try r.readUInt16()
        let cmap = try r.readUInt32()
        let colors = try r.readUInt16()
        let planes = try r.readUInt16()
        return AllocColorCells(contiguous: contig, cmap: cmap, colors: colors, planes: planes)
    }
}

public struct SetCloseDownMode: Equatable, Sendable {
    public static let opcode: UInt8 = 112
    public var mode: UInt8              // 0 Destroy, 1 RetainPermanent, 2 RetainTemporary

    public init(mode: UInt8) { self.mode = mode }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(mode)
        w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetCloseDownMode {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let mode = try r.readUInt8()
        _ = try r.readUInt16()
        return SetCloseDownMode(mode: mode)
    }
}

public struct CirculateWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 13
    public var direction: UInt8         // 0 RaiseLowest, 1 LowerHighest
    public var window: UInt32

    public init(direction: UInt8, window: UInt32) {
        self.direction = direction; self.window = window
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(direction); w.writeUInt16(2)
        w.writeUInt32(window)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CirculateWindow {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let dir = try r.readUInt8()
        _ = try r.readUInt16()
        return CirculateWindow(direction: dir, window: try r.readUInt32())
    }
}

public struct KillClient: Equatable, Sendable {
    public static let opcode: UInt8 = 113
    // AllTemporary = 0 — close all clients with RetainTemporary close-down.
    // Otherwise resource is any X resource ID; server kills the owning client.
    public var resource: UInt32

    public init(resource: UInt32) { self.resource = resource }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(2)
        w.writeUInt32(resource)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> KillClient {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let res = try r.readUInt32()
        return KillClient(resource: res)
    }
}
