// Font search path requests. Both opcodes deal with the LISTofSTR
// wire form — each STR is one length byte followed by that many bytes
// of text (no terminator, no per-string padding).

// MARK: - SetFontPath (opcode 51)

/// xSetFontPathReq: opcode(1) + pad(1) + length(2) + nStrs(2) + pad(2).
/// Then a LISTofSTR (each: length byte + bytes), padded to 4 at the end.
public struct SetFontPath: Equatable, Sendable {
    public static let opcode: UInt8 = 51

    public var path: [String]

    public init(path: [String]) { self.path = path }

    /// LISTofSTR length in bytes (sum of `1 + str.utf8.count` per string).
    private static func listLen(_ strs: [String]) -> Int {
        strs.reduce(0) { $0 + 1 + $1.utf8.count }
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = Self.listLen(path)
        let p = xPad(n)
        let lenIn4 = UInt16(2 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt16(UInt16(path.count)); w.writePadding(2)
        for s in path {
            let bytes = Array(s.utf8)
            precondition(bytes.count <= 255, "STR length must fit in one byte")
            w.writeUInt8(UInt8(bytes.count))
            w.writeBytes(bytes)
        }
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> SetFontPath {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        _ = try r.readUInt16()
        let nStrs = Int(try r.readUInt16())
        try r.skip(2)
        var path: [String] = []
        path.reserveCapacity(nStrs)
        for _ in 0..<nStrs {
            let len = Int(try r.readUInt8())
            let raw = try r.readBytes(len)
            path.append(String(decoding: raw, as: UTF8.self))
        }
        return SetFontPath(path: path)
    }
}

// MARK: - GetFontPath (opcode 52)

public struct GetFontPath: Equatable, Sendable {
    public static let opcode: UInt8 = 52
    public init() {}
    public func encode(byteOrder: ByteOrder) -> [UInt8] { encodeHeaderOnly(opcode: Self.opcode, byteOrder: byteOrder) }
    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetFontPath {
        try decodeHeaderOnly(opcode: Self.opcode, from: bytes, byteOrder: byteOrder)
        return GetFontPath()
    }
}
