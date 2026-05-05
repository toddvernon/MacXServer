import Foundation
import Darwin

public enum ProxyError: Error, Sendable {
    case notStarted
    case socketCreate(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case getsocknameFailed(errno: Int32)
    case resolveFailed(host: String, errno: Int32)
    case connectFailed(host: String, port: UInt16, errno: Int32)
    case invalidListenAddress(String)
}

public final class Proxy: @unchecked Sendable {
    public let listenHost: String
    public let listenPort: UInt16
    public let forwardHost: String
    public let forwardPort: UInt16
    private let recorder: Recorder?

    private var listenFd: Int32 = -1

    public init(
        listenHost: String,
        listenPort: UInt16,
        forwardHost: String,
        forwardPort: UInt16,
        recorder: Recorder?
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.forwardHost = forwardHost
        self.forwardPort = forwardPort
        self.recorder = recorder
    }

    public func start() throws -> UInt16 {
        listenFd = try createListenSocket(host: listenHost, port: listenPort)
        return try getActualPort(fd: listenFd)
    }

    public func run() throws {
        guard listenFd >= 0 else { throw ProxyError.notStarted }

        let clientFd = try acceptConnection(fd: listenFd)
        Darwin.close(listenFd)
        listenFd = -1
        setNoDelay(clientFd)

        let serverFd: Int32
        do {
            serverFd = try dial(host: forwardHost, port: forwardPort)
        } catch {
            Darwin.close(clientFd)
            throw error
        }
        setNoDelay(serverFd)

        let group = DispatchGroup()
        let queue = DispatchQueue.global()

        group.enter()
        queue.async {
            self.pump(from: clientFd, to: serverFd, direction: .clientToServer)
            shutdown(serverFd, Int32(SHUT_WR))
            group.leave()
        }

        group.enter()
        queue.async {
            self.pump(from: serverFd, to: clientFd, direction: .serverToClient)
            shutdown(clientFd, Int32(SHUT_WR))
            group.leave()
        }

        group.wait()
        Darwin.close(clientFd)
        Darwin.close(serverFd)
    }

    public func stop() {
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    private func pump(from src: Int32, to dst: Int32, direction: Direction) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return Darwin.read(src, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            let chunk = Array(buf[0..<n])
            recorder?.record(direction: direction, bytes: chunk)

            var written = 0
            while written < chunk.count {
                let w = chunk.withUnsafeBufferPointer { ptr -> Int in
                    return Darwin.write(dst, ptr.baseAddress!.advanced(by: written), chunk.count - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }
}

// MARK: - POSIX helpers

private func createListenSocket(host: String, port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProxyError.socketCreate(errno: errno) }

    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian

    if host.isEmpty || host == "0.0.0.0" {
        addr.sin_addr.s_addr = in_addr_t(0).bigEndian
    } else {
        guard inet_aton(host, &addr.sin_addr) != 0 else {
            Darwin.close(fd)
            throw ProxyError.invalidListenAddress(host)
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ProxyError.bindFailed(errno: e)
    }

    guard Darwin.listen(fd, 1) == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ProxyError.listenFailed(errno: e)
    }

    return fd
}

private func getActualPort(fd: Int32) throws -> UInt16 {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &len)
        }
    }
    guard result == 0 else { throw ProxyError.getsocknameFailed(errno: errno) }
    return UInt16(bigEndian: addr.sin_port)
}

private func acceptConnection(fd: Int32) throws -> Int32 {
    var addr = sockaddr()
    var len = socklen_t(MemoryLayout<sockaddr>.size)
    let cfd = Darwin.accept(fd, &addr, &len)
    guard cfd >= 0 else { throw ProxyError.acceptFailed(errno: errno) }
    return cfd
}

private func setNoDelay(_ fd: Int32) {
    // Disable Nagle's algorithm on this socket. Real X11 endpoints set this on
    // every TCP connection because the protocol's interactive request bursts get
    // murdered by the 40ms coalescing delay otherwise. Failure is non-fatal.
    var one: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func dial(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>? = nil
    let r = getaddrinfo(host, String(port), &hints, &result)
    guard r == 0, let info = result else {
        throw ProxyError.resolveFailed(host: host, errno: errno)
    }
    defer { freeaddrinfo(info) }

    let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw ProxyError.socketCreate(errno: errno) }

    let connectResult = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
    guard connectResult == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ProxyError.connectFailed(host: host, port: port, errno: e)
    }

    return fd
}
