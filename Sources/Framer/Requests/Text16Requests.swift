// CHAR2B variants of PolyText8/ImageText8. Each character on the wire is 2
// bytes: row (high) then column (low), MSB-first independent of the
// connection byte order. The framer stores characters as already-decoded
// `[UInt16]` (row<<8 | column) so the dispatcher can pass them straight to
// Core Text as UniChar values without further byte-order gymnastics.

public struct PolyText16: Equatable, Sendable {
    public static let opcode: UInt8 = 75
    public var drawable: UInt32
    public var gc: UInt32
    public var x: Int16
    public var y: Int16
    /// Raw TEXTITEM16 items bytes (includes any trailing pad). Each item is
    /// either a font-shift sentinel (`0xFF` + 4 bytes font id) or a text run:
    /// `stringLen(1) + delta(INT8) + 2*stringLen bytes` (CHAR2B big-endian).
    /// Stored raw because the per-item walk happens in the renderer.
    public var items: [UInt8]

    public init(drawable: UInt32, gc: UInt32, x: Int16, y: Int16, items: [UInt8]) {
        self.drawable = drawable
        self.gc = gc
        self.x = x; self.y = y
        self.items = items
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = items.count
        let p = xPad(n)
        let lenIn4 = UInt16(4 + (n + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode); w.writeUInt8(0); w.writeUInt16(lenIn4)
        w.writeUInt32(drawable); w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        w.writeBytes(items)
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> PolyText16 {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else { throw FramerError.invalidOpcode(expected: Self.opcode, got: op) }
        _ = try r.readUInt8()
        let lenIn4 = Int(try r.readUInt16())
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        let totalItemsBytes = (lenIn4 - 4) * 4
        let items = try r.readBytes(totalItemsBytes)
        return PolyText16(drawable: drawable, gc: gc, x: x, y: y, items: items)
    }
}

public struct ImageText16: Equatable, Sendable {
    public static let opcode: UInt8 = 77

    public var drawable: UInt32
    public var gc: UInt32
    public var x: Int16
    public var y: Int16
    /// One UInt16 per character (row<<8 | column). Decoded from CHAR2B
    /// big-endian wire bytes regardless of connection byte order.
    public var characters: [UInt16]

    public init(drawable: UInt32, gc: UInt32, x: Int16, y: Int16, characters: [UInt16]) {
        precondition(characters.count <= 255, "ImageText16 character count exceeds CARD8 max")
        self.drawable = drawable
        self.gc = gc
        self.x = x; self.y = y
        self.characters = characters
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let n = characters.count
        let payloadBytes = n * 2
        let p = xPad(payloadBytes)
        let lenIn4 = UInt16(4 + (payloadBytes + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(Self.opcode)
        w.writeUInt8(UInt8(n))
        w.writeUInt16(lenIn4)
        w.writeUInt32(drawable)
        w.writeUInt32(gc)
        w.writeUInt16(UInt16(bitPattern: x))
        w.writeUInt16(UInt16(bitPattern: y))
        // CHAR2B is MSB-first per X spec, independent of connection byte
        // order. Emit row (high byte) then column (low byte).
        for ch in characters {
            w.writeUInt8(UInt8((ch >> 8) & 0xFF))
            w.writeUInt8(UInt8(ch & 0xFF))
        }
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ImageText16 {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        let op = try r.readUInt8()
        guard op == Self.opcode else {
            throw FramerError.invalidOpcode(expected: Self.opcode, got: op)
        }
        let n = Int(try r.readUInt8())
        _ = try r.readUInt16()
        let drawable = try r.readUInt32()
        let gc = try r.readUInt32()
        let x = Int16(bitPattern: try r.readUInt16())
        let y = Int16(bitPattern: try r.readUInt16())
        var chars = [UInt16](repeating: 0, count: n)
        for i in 0..<n {
            let hi = UInt16(try r.readUInt8())
            let lo = UInt16(try r.readUInt8())
            chars[i] = (hi << 8) | lo
        }
        try r.skip(xPad(n * 2))
        return ImageText16(drawable: drawable, gc: gc, x: x, y: y, characters: chars)
    }
}
