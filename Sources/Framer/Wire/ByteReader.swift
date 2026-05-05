public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int
    public let byteOrder: ByteOrder

    public init(bytes: [UInt8], byteOrder: ByteOrder, offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
        self.byteOrder = byteOrder
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func readUInt8() throws -> UInt8 {
        try ensure(1)
        let v = bytes[offset]
        offset += 1
        return v
    }

    public mutating func readUInt16() throws -> UInt16 {
        try ensure(2)
        let a = UInt16(bytes[offset])
        let b = UInt16(bytes[offset + 1])
        offset += 2
        switch byteOrder {
        case .lsbFirst: return (b << 8) | a
        case .msbFirst: return (a << 8) | b
        }
    }

    public mutating func readUInt32() throws -> UInt32 {
        try ensure(4)
        let a = UInt32(bytes[offset])
        let b = UInt32(bytes[offset + 1])
        let c = UInt32(bytes[offset + 2])
        let d = UInt32(bytes[offset + 3])
        offset += 4
        switch byteOrder {
        case .lsbFirst: return (d << 24) | (c << 16) | (b << 8) | a
        case .msbFirst: return (a << 24) | (b << 16) | (c << 8) | d
        }
    }

    public mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try ensure(n)
        let slice = Array(bytes[offset..<(offset + n)])
        offset += n
        return slice
    }

    public mutating func skip(_ n: Int) throws {
        try ensure(n)
        offset += n
    }

    private func ensure(_ n: Int) throws {
        if remaining < n {
            throw FramerError.truncated(needed: n, available: remaining)
        }
    }
}
