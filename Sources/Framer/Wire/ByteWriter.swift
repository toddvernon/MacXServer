public struct ByteWriter {
    public private(set) var bytes: [UInt8]
    public let byteOrder: ByteOrder

    public init(byteOrder: ByteOrder) {
        self.bytes = []
        self.byteOrder = byteOrder
    }

    public mutating func writeUInt8(_ v: UInt8) {
        bytes.append(v)
    }

    public mutating func writeUInt16(_ v: UInt16) {
        switch byteOrder {
        case .lsbFirst:
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        case .msbFirst:
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
    }

    public mutating func writeUInt32(_ v: UInt32) {
        switch byteOrder {
        case .lsbFirst:
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 24) & 0xFF))
        case .msbFirst:
            bytes.append(UInt8((v >> 24) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
    }

    public mutating func writeBytes(_ b: [UInt8]) {
        bytes.append(contentsOf: b)
    }

    public mutating func writePadding(_ n: Int) {
        bytes.append(contentsOf: Array(repeating: UInt8(0), count: n))
    }
}
