public struct SetupRequest: Equatable, Sendable {
    public var byteOrder: ByteOrder
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var authProtocolName: [UInt8]
    public var authProtocolData: [UInt8]

    public init(
        byteOrder: ByteOrder,
        protocolMajor: UInt16 = 11,
        protocolMinor: UInt16 = 0,
        authProtocolName: [UInt8] = [],
        authProtocolData: [UInt8] = []
    ) {
        self.byteOrder = byteOrder
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.authProtocolName = authProtocolName
        self.authProtocolData = authProtocolData
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(byteOrder == .msbFirst ? 0x42 : 0x6C)
        w.writeUInt8(0)
        w.writeUInt16(protocolMajor)
        w.writeUInt16(protocolMinor)
        w.writeUInt16(UInt16(authProtocolName.count))
        w.writeUInt16(UInt16(authProtocolData.count))
        w.writeUInt16(0)
        w.writeBytes(authProtocolName)
        w.writePadding(xPad(authProtocolName.count))
        w.writeBytes(authProtocolData)
        w.writePadding(xPad(authProtocolData.count))
        return w.bytes
    }

    public static func decode(from bytes: [UInt8]) throws -> SetupRequest {
        guard let first = bytes.first else {
            throw FramerError.truncated(needed: 1, available: 0)
        }
        let byteOrder: ByteOrder
        switch first {
        case 0x42: byteOrder = .msbFirst
        case 0x6C: byteOrder = .lsbFirst
        default: throw FramerError.invalidByteOrder(first)
        }

        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        _ = try r.readUInt8()
        let major = try r.readUInt16()
        let minor = try r.readUInt16()
        let nameLen = Int(try r.readUInt16())
        let dataLen = Int(try r.readUInt16())
        _ = try r.readUInt16()
        let name = try r.readBytes(nameLen)
        try r.skip(xPad(nameLen))
        let data = try r.readBytes(dataLen)
        try r.skip(xPad(dataLen))

        return SetupRequest(
            byteOrder: byteOrder,
            protocolMajor: major,
            protocolMinor: minor,
            authProtocolName: name,
            authProtocolData: data
        )
    }
}
