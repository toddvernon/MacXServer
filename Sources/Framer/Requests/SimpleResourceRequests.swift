// Requests that consist of just (opcode + unused + length=2 + 4-byte resource id).
// Bundled into one file because they're trivially identical in shape — only the
// opcode and field semantics differ.

public struct GetWindowAttributes: Equatable, Sendable {
    public static let opcode: UInt8 = 3
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetWindowAttributes {
        GetWindowAttributes(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct DestroyWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 4
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> DestroyWindow {
        DestroyWindow(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct DestroySubwindows: Equatable, Sendable {
    public static let opcode: UInt8 = 5
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> DestroySubwindows {
        DestroySubwindows(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct MapSubwindows: Equatable, Sendable {
    public static let opcode: UInt8 = 9
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> MapSubwindows {
        MapSubwindows(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct UnmapWindow: Equatable, Sendable {
    public static let opcode: UInt8 = 10
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UnmapWindow {
        UnmapWindow(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct UnmapSubwindows: Equatable, Sendable {
    public static let opcode: UInt8 = 11
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UnmapSubwindows {
        UnmapSubwindows(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct GetGeometry: Equatable, Sendable {
    public static let opcode: UInt8 = 14
    public var drawable: UInt32
    public init(drawable: UInt32) { self.drawable = drawable }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: drawable, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetGeometry {
        GetGeometry(drawable: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct QueryTree: Equatable, Sendable {
    public static let opcode: UInt8 = 15
    public var window: UInt32
    public init(window: UInt32) { self.window = window }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: window, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryTree {
        QueryTree(window: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct GetAtomName: Equatable, Sendable {
    public static let opcode: UInt8 = 17
    public var atom: UInt32
    public init(atom: UInt32) { self.atom = atom }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: atom, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetAtomName {
        GetAtomName(atom: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct GetSelectionOwner: Equatable, Sendable {
    public static let opcode: UInt8 = 23
    public var selection: UInt32
    public init(selection: UInt32) { self.selection = selection }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: selection, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetSelectionOwner {
        GetSelectionOwner(selection: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct CloseFont: Equatable, Sendable {
    public static let opcode: UInt8 = 46
    public var font: UInt32
    public init(font: UInt32) { self.font = font }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: font, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> CloseFont {
        CloseFont(font: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct QueryFont: Equatable, Sendable {
    public static let opcode: UInt8 = 47
    public var font: UInt32
    public init(font: UInt32) { self.font = font }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: font, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryFont {
        QueryFont(font: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct FreePixmap: Equatable, Sendable {
    public static let opcode: UInt8 = 54
    public var pixmap: UInt32
    public init(pixmap: UInt32) { self.pixmap = pixmap }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: pixmap, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FreePixmap {
        FreePixmap(pixmap: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct FreeGC: Equatable, Sendable {
    public static let opcode: UInt8 = 60
    public var gc: UInt32
    public init(gc: UInt32) { self.gc = gc }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: gc, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FreeGC {
        FreeGC(gc: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

public struct FreeCursor: Equatable, Sendable {
    public static let opcode: UInt8 = 95
    public var cursor: UInt32
    public init(cursor: UInt32) { self.cursor = cursor }
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeIDRequest(opcode: Self.opcode, id: cursor, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> FreeCursor {
        FreeCursor(cursor: try decodeIDRequest(opcode: Self.opcode, from: bytes, byteOrder: byteOrder))
    }
}

// Shared helpers for the single-ID shape.

func encodeIDRequest(opcode: UInt8, id: UInt32, byteOrder: ByteOrder) -> [UInt8] {
    var w = ByteWriter(byteOrder: byteOrder)
    w.writeUInt8(opcode)
    w.writeUInt8(0)
    w.writeUInt16(2)
    w.writeUInt32(id)
    return w.bytes
}

func decodeIDRequest(opcode: UInt8, from bytes: [UInt8], byteOrder: ByteOrder) throws -> UInt32 {
    var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
    let op = try r.readUInt8()
    guard op == opcode else { throw FramerError.invalidOpcode(expected: opcode, got: op) }
    _ = try r.readUInt8()
    _ = try r.readUInt16()
    return try r.readUInt32()
}
