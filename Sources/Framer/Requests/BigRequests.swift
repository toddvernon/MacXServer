// BIG-REQUESTS extension wire types.
//
// One opcode: BigReqEnable (minor 0). Clients call it once after
// QueryExtension(BIG-REQUESTS) returns present=true to enable the
// extended-length-prefix format on subsequent requests (a 32-bit length
// in bytes 4-7 when the regular 16-bit length is 0). The reply carries
// the server's new maximum-request size.
//
// Wire layout verified against
// reference/X11R6/xc/include/extensions/bigreqstr.h.

public enum BigReqMinor {
    public static let enable: UInt8 = 0
}

/// BigReqEnable request — just a 4-byte header.
public struct BigReqEnable: Equatable, Sendable {
    public static let minor: UInt8 = BigReqMinor.enable

    public init() {}

    public func encode(majorOpcode: UInt8, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(majorOpcode); w.writeUInt8(Self.minor); w.writeUInt16(1)
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> BigReqEnable {
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8(); _ = try r.readUInt8()
        _ = try r.readUInt16()
        return BigReqEnable()
    }
}
