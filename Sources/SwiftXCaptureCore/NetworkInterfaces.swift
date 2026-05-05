import Darwin

public struct NetworkInterface: Sendable, Equatable {
    public let name: String
    public let address: String
    public let isLoopback: Bool

    public init(name: String, address: String, isLoopback: Bool) {
        self.name = name
        self.address = address
        self.isLoopback = isLoopback
    }
}

public func enumerateIPv4Interfaces() -> [NetworkInterface] {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }

    var result: [NetworkInterface] = []
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let p = current {
        let entry = p.pointee
        let next = entry.ifa_next

        if let addr = entry.ifa_addr,
           addr.pointee.sa_family == sa_family_t(AF_INET),
           (Int32(entry.ifa_flags) & IFF_UP) != 0 {
            let isLoopback = (Int32(entry.ifa_flags) & IFF_LOOPBACK) != 0
            let name = String(cString: entry.ifa_name)

            var addrIn = sockaddr_in()
            memcpy(&addrIn, addr, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if let cstr = inet_ntop(AF_INET, &addrIn.sin_addr, &buf, socklen_t(buf.count)) {
                result.append(NetworkInterface(
                    name: name,
                    address: String(cString: cstr),
                    isLoopback: isLoopback
                ))
            }
        }

        current = next
    }
    return result
}
