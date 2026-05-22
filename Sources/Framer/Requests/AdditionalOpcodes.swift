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

// QueryTextExtents (op 48). Measures a character string against the
// metrics of a previously-opened font. Motif's CascadeButton uses this
// for menu-title widths during XmRowColumn layout; pre-2026-05-15 we
// returned BadRequest and Motif fell back to a default-width estimate,
// producing visibly-misaligned menu titles. Wire body is CHAR2B
// (UTF-16, MSB first per X spec) padded to a 4-byte boundary; the
// `oddLength` flag in the header's second byte signals whether the
// trailing 2 padding bytes are part of the string or filler.
public struct QueryTextExtents: Equatable, Sendable {
    public static let opcode: UInt8 = 48
    public var fid: UInt32
    /// Raw CHAR2B bytes — two bytes per character, big-endian per X
    /// (independent of the connection byte order). We keep the raw
    /// bytes so the handler can decode to whatever it needs.
    public var stringBytes: [UInt8]

    public init(fid: UInt32, stringBytes: [UInt8]) {
        self.fid = fid; self.stringBytes = stringBytes
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        // Each CHAR2B is 2 bytes. Length field counts whole 4-byte
        // units; if the byte count isn't a multiple of 4 we need 2
        // bytes of pad AND oddLength = 1.
        let n = stringBytes.count
        let totalBodyBytes = n + (n % 4 == 0 ? 0 : (4 - n % 4))
        let lenIn4 = UInt16(2 + totalBodyBytes / 4)
        let isOdd = (n / 2) % 2 != 0    // odd number of CHAR2B chars
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(isOdd ? 1 : 0)
        w.writeUInt16(lenIn4)
        w.writeUInt32(fid)
        w.writeBytes(stringBytes)
        if n % 4 != 0 { w.writePadding(4 - n % 4) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryTextExtents {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let oddLength = try r.readUInt8() != 0
        let lenIn4 = Int(try r.readUInt16())
        let fid = try r.readUInt32()
        // Body: (lenIn4 - 2) * 4 bytes; the last 2 are padding when oddLength=1.
        let bodyBytes = max(0, (lenIn4 - 2) * 4)
        let raw = try r.readBytes(bodyBytes)
        // Trim trailing 2 pad bytes when odd. Each CHAR2B is 2 bytes,
        // so odd means the string had an odd number of CHAR2Bs.
        let trimmed: [UInt8]
        if oddLength && raw.count >= 2 {
            trimmed = Array(raw[0..<(raw.count - 2)])
        } else {
            trimmed = raw
        }
        return QueryTextExtents(fid: fid, stringBytes: trimmed)
    }
}

// PolyPoint (op 64). Draws single-pixel dots at the given coordinates
// using the GC's foreground pixel. Identical wire shape to PolyLine but
// without segment connection. Load-bearing for any plotting client
// (xmgrace, xfig point markers, scatter plots). Pre-2026-05-15 this
// fell through to BadRequest because no Framer decoder existed.
public struct PolyPoint: Equatable, Sendable {
    public static let opcode: UInt8 = 64
    public var coordinateMode: CoordinateMode
    public var drawable: UInt32
    public var gc: UInt32
    public var points: [Point]

    public init(coordinateMode: CoordinateMode, drawable: UInt32, gc: UInt32, points: [Point]) {
        self.coordinateMode = coordinateMode; self.drawable = drawable
        self.gc = gc; self.points = points
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let lenIn4 = UInt16(3 + points.count)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(coordinateMode.rawValue)
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        for p in points { p.encode(into: &w) }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyPoint {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let modeRaw = try r.readUInt8()
        guard let mode = CoordinateMode(rawValue: modeRaw) else {
            throw FramerError.invalidEnum(name: "CoordinateMode", value: UInt32(modeRaw))
        }
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let nPoints = max(0, lenIn4 - 3)
        var points: [Point] = []
        points.reserveCapacity(nPoints)
        for _ in 0..<nPoints {
            points.append(try Point.decode(from: &r))
        }
        return PolyPoint(coordinateMode: mode, drawable: drawable, gc: gc, points: points)
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

// Screensaver trio (107/108/115). x11perf calls all three at startup to save
// the current screensaver state, disable blanking during the run, and reset
// it afterward. swift-x doesn't own screen blanking — macOS does — so these
// are honest no-ops: GetScreenSaver reports "disabled" (timeout=0), Set/Force
// accept and ignore. Pre-this-change they fell through to .unknown and emitted
// BadRequest, which trips Xlib's default error handler and aborts the client.

public struct GetScreenSaver: Equatable, Sendable {
    public static let opcode: UInt8 = 108

    public init() {}

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(0)
        w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetScreenSaver {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        return GetScreenSaver()
    }
}

public struct SetScreenSaver: Equatable, Sendable {
    public static let opcode: UInt8 = 107
    public var timeout: Int16        // seconds; 0 disables, -1 restores default
    public var interval: Int16       // seconds between regenerations
    public var preferBlanking: UInt8 // 0 No, 1 Yes, 2 Default
    public var allowExposures: UInt8 // 0 No, 1 Yes, 2 Default

    public init(timeout: Int16, interval: Int16, preferBlanking: UInt8, allowExposures: UInt8) {
        self.timeout = timeout
        self.interval = interval
        self.preferBlanking = preferBlanking
        self.allowExposures = allowExposures
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(3)
        w.writeUInt16(UInt16(bitPattern: timeout))
        w.writeUInt16(UInt16(bitPattern: interval))
        w.writeUInt8(preferBlanking); w.writeUInt8(allowExposures)
        w.writeUInt16(0)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetScreenSaver {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let to = Int16(bitPattern: try r.readUInt16())
        let iv = Int16(bitPattern: try r.readUInt16())
        let pb = try r.readUInt8()
        let ae = try r.readUInt8()
        _ = try r.readUInt16()
        return SetScreenSaver(timeout: to, interval: iv, preferBlanking: pb, allowExposures: ae)
    }
}

public struct ForceScreenSaver: Equatable, Sendable {
    public static let opcode: UInt8 = 115
    public var mode: UInt8           // 0 Reset, 1 Activate

    public init(mode: UInt8) { self.mode = mode }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(mode)
        w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ForceScreenSaver {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        let mode = try r.readUInt8()
        _ = try r.readUInt16()
        return ForceScreenSaver(mode: mode)
    }
}
