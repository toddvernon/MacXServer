// Reply to ListHosts (opcode 110).
// xListHostsReply: type(1=1) + enabled(1) + seq(2) + length(4=n/4) +
// nHosts(2) + 22 bytes pad. Then each HOST is family(1) + pad(1) +
// addressLength(2) + bytes(addressLength) + pad-to-4.
public struct ListHostsReply: Equatable, Sendable {

    public struct Host: Equatable, Sendable {
        public var family: HostFamily
        public var address: [UInt8]

        public init(family: HostFamily, address: [UInt8]) {
            self.family = family
            self.address = address
        }
    }

    public var sequenceNumber: UInt16
    /// false = access control disabled (all hosts allowed);
    /// true = enabled (only listed hosts allowed). Spec calls these "Enabled" / "Disabled"
    /// but the meaning is whether enforcement is on, so this is the natural Swift flip.
    public var enabled: Bool
    public var hosts: [Host]

    public init(sequenceNumber: UInt16, enabled: Bool, hosts: [Host]) {
        self.sequenceNumber = sequenceNumber
        self.enabled = enabled
        self.hosts = hosts
    }

    /// Total bytes the host list occupies on the wire (each HOST padded to 4).
    private static func listLen(_ hosts: [Host]) -> Int {
        hosts.reduce(0) { acc, h in
            let n = h.address.count
            return acc + 4 + n + xPad(n)
        }
    }

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        let listBytes = Self.listLen(hosts)
        let lenIn4 = UInt32(listBytes / 4)
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1); w.writeUInt8(enabled ? 1 : 0); w.writeUInt16(sequenceNumber)
        w.writeUInt32(lenIn4)
        w.writeUInt16(UInt16(hosts.count))
        w.writePadding(22)
        for h in hosts {
            let n = h.address.count
            w.writeUInt8(h.family.rawValue); w.writePadding(1); w.writeUInt16(UInt16(n))
            w.writeBytes(h.address)
            w.writePadding(xPad(n))
        }
        return w.bytes
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> ListHostsReply {
        guard bytes.count >= 32 else {
            throw FramerError.truncated(needed: 32, available: bytes.count)
        }
        var r = ByteReader(bytes: bytes, byteOrder: byteOrder)
        _ = try r.readUInt8()
        let enabled = try r.readUInt8() != 0
        let seq = try r.readUInt16()
        _ = try r.readUInt32()
        let nHosts = Int(try r.readUInt16())
        try r.skip(22)
        var hosts: [Host] = []
        hosts.reserveCapacity(nHosts)
        for _ in 0..<nHosts {
            let famRaw = try r.readUInt8()
            guard let family = HostFamily(rawValue: famRaw) else {
                throw FramerError.invalidEnum(name: "HostFamily", value: UInt32(famRaw))
            }
            try r.skip(1)
            let n = Int(try r.readUInt16())
            let addr = try r.readBytes(n)
            try r.skip(xPad(n))
            hosts.append(Host(family: family, address: addr))
        }
        return ListHostsReply(sequenceNumber: seq, enabled: enabled, hosts: hosts)
    }
}
