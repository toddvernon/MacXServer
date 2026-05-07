import Foundation
import Darwin

// TCP listener glue. Bind, accept one connection, drive a ServerSession on it.
// Multi-client comes post-M1 — see PRODUCT_2_SERVER.md.
//
// Two I/O threads share the socket:
//   * Read thread: blocking POSIX read → feed session → write the bytes
//     `feed()` returns directly (replies generated during dispatch).
//   * Write thread: blocks on `outbound.waitAndDrain()` and writes whatever
//     async producers (the Cocoa bridge from the main thread) appended.
//
// Both writers serialise on `writeLock` so they don't interleave bytes within
// a single message.

public enum ListenerError: Error, Sendable {
    case socketCreate(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case getsocknameFailed(errno: Int32)
    case invalidListenAddress(String)
}

public final class Listener: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public weak var log: ServerLogSink?

    private var fd: Int32 = -1
    private var stopRequested = false
    private let writeLock = NSLock()

    public init(host: String, port: UInt16, log: ServerLogSink? = nil) {
        self.host = host
        self.port = port
        self.log = log
    }

    public func bind() throws -> UInt16 {
        fd = try createListenSocket(host: host, port: port)
        return try getActualPort(fd: fd)
    }

    public func stop() {
        stopRequested = true
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Accept one connection and drive a ServerSession on it. Returns when
    /// the client closes or `stop()` is called.
    public func runOne(
        config: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        onSession: ((ServerSession) -> Void)? = nil
    ) throws {
        guard fd >= 0 else { throw ListenerError.acceptFailed(errno: 0) }

        let clientFd = try acceptConnection(fd: fd)
        setNoDelay(clientFd)
        defer { Darwin.close(clientFd) }
        log?.log("client connected")

        let session = ServerSession(config: config, bridge: bridge, log: log)
        onSession?(session)

        let writeThread = Thread { [weak self] in
            self?.runWriteLoop(session: session, clientFd: clientFd)
        }
        writeThread.name = "swiftx.write"
        writeThread.start()

        // Read loop runs on the calling thread (caller of runOne).
        var readBuffer = [UInt8](repeating: 0, count: 65536)
        while !stopRequested {
            let n = readBuffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(clientFd, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                log?.log("client disconnected")
                break
            }
            if n < 0 {
                if errno == EINTR { continue }
                log?.log("read error: errno=\(errno)")
                break
            }
            let chunk = Array(readBuffer[0..<n])
            let outBytes = session.feed(chunk)
            writeAll(clientFd, outBytes)
        }

        session.outbound.stop()
        // Give the write thread a moment to flush.
        let deadline = Date().addingTimeInterval(0.25)
        while writeThread.isExecuting && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        log?.log("session: requests=\(session.requestsProcessed) windows=\(session.windows.count) atoms=\(session.atoms.count) colors=\(session.colors.count)")
    }

    private func runWriteLoop(session: ServerSession, clientFd: Int32) {
        while true {
            let bytes = session.outbound.waitAndDrain()
            if bytes.isEmpty { return }      // stopped
            writeAll(clientFd, bytes)
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        var written = 0
        while written < bytes.count {
            let w = bytes.withUnsafeBufferPointer { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if w <= 0 { return }
            written += w
        }
    }
}

private func createListenSocket(host: String, port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ListenerError.socketCreate(errno: errno) }

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
            throw ListenerError.invalidListenAddress(host)
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
        throw ListenerError.bindFailed(errno: e)
    }

    guard Darwin.listen(fd, 1) == 0 else {
        let e = errno
        Darwin.close(fd)
        throw ListenerError.listenFailed(errno: e)
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
    guard result == 0 else { throw ListenerError.getsocknameFailed(errno: errno) }
    return UInt16(bigEndian: addr.sin_port)
}

private func acceptConnection(fd: Int32) throws -> Int32 {
    var addr = sockaddr()
    var len = socklen_t(MemoryLayout<sockaddr>.size)
    let cfd = Darwin.accept(fd, &addr, &len)
    guard cfd >= 0 else { throw ListenerError.acceptFailed(errno: errno) }
    return cfd
}

private func setNoDelay(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}
