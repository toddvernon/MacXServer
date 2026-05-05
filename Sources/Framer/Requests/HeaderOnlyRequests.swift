// Requests that consist of just the 4-byte header (opcode + unused + length=1).
// No fields. Bundled together because they're all the same one-line shape.

public struct GrabServer: Equatable, Sendable {
    public static let opcode: UInt8 = 36
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GrabServer {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GrabServer()
    }
}

public struct UngrabServer: Equatable, Sendable {
    public static let opcode: UInt8 = 37
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> UngrabServer {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return UngrabServer()
    }
}

public struct QueryKeymap: Equatable, Sendable {
    public static let opcode: UInt8 = 44
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> QueryKeymap {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return QueryKeymap()
    }
}

public struct GetInputFocus: Equatable, Sendable {
    public static let opcode: UInt8 = 43
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetInputFocus {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetInputFocus()
    }
}

public struct GetModifierMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 119
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetModifierMapping {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetModifierMapping()
    }
}

public struct GetPointerMapping: Equatable, Sendable {
    public static let opcode: UInt8 = 117
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetPointerMapping {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetPointerMapping()
    }
}

public struct ListExtensions: Equatable, Sendable {
    public static let opcode: UInt8 = 99
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListExtensions {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return ListExtensions()
    }
}

func encodeHeaderOnly(opcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
    var w = ByteWriter(byteOrder: byteOrder)
    w.writeUInt8(opcode)
    w.writeUInt8(0)
    w.writeUInt16(1)
    return w.bytes
}

func decodeHeaderOnly(opcode: UInt8, from bytes: [UInt8], byteOrder: ByteOrder) throws {
    var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
    let op = try r.readUInt8()
    guard op == opcode else { throw FramerError.invalidOpcode(expected: opcode, got: op) }
    _ = try r.readUInt8()
    _ = try r.readUInt16()
}
