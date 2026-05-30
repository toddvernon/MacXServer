// Reply to GetFontPath (opcode 52).
// xGetFontPathReply: type(1=1) + pad(1) + seq(2) + length(4) +
// nPaths(2) + 22 bytes pad. Then a LISTofSTR (length-prefixed; no
// terminator, no per-string pad), end-padded to 4.
public struct GetFontPathReply: Equatable, Sendable {
    public var sequenceNumber: UInt16
    public var path: [String]

    public init(sequenceNumber: UInt16, path: [String]) {
        self.sequenceNumber = sequenceNumber
        self.path = path
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let strBytes = path.reduce(0) { $0 + 1 + $1.utf8.count }
        let p = xPad(strBytes)
        let lenIn4 = UInt32((strBytes + p) / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(path.count))
        w.writePadding(22)
        for s in path {
            let bytes = Array(s.utf8)
            precondition(bytes.count <= 255, "STR length must fit in one byte")
            w.writeUInt8(UInt8(bytes.count))
            w.writeBytes(bytes)
        }
        w.writePadding(p)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> GetFontPathReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let nPaths = Int(try r.readUInt16())
        try r.skip(22)
        var path: [String] = []
        path.reserveCapacity(nPaths)
        for _ in 0..<nPaths {
            let len = Int(try r.readUInt8())
            let raw = try r.readBytes(len)
            path.append(String(decoding: raw, as: UTF8.self))
        }
        return GetFontPathReply(sequenceNumber: seq, path: path)
    }
}
