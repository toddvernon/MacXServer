import Foundation
import Darwin

// TCP listener glue.
//
// `runOne(...)` is the single-client path used by tests — bind, accept ONE
// connection, drive a ServerSession on it, return when the client closes.
//
// `runAccepting(...)` is the multi-client path used by the real server —
// loop accepting connections and spin a dedicated read+write thread pair
// per accepted client. The supplied `ServerCoordinator` hands out a fresh
// resource-id-base per accept so client-allocated IDs don't collide, and
// keeps atoms + selection ownership shared across all sessions (X11 spec
// requires both to be server-global).
//
// Per session, two I/O threads share the socket:
//   * Read thread: blocking POSIX read → feed session → write the bytes
//     `feed()` returns directly (replies generated during dispatch).
//   * Write thread: blocks on `outbound.waitAndDrain()` and writes whatever
//     async producers (the Cocoa bridge from the main thread) appended.
//
// Both writers for a given session serialise on a per-session lock so they
// don't interleave bytes within a single X11 message.

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

    /// Single-client: accept one connection, drive a ServerSession on it,
    /// return when the client closes or `stop()` is called. Used by tests
    /// and by any caller that wants a one-shot session.
    public func runOne(
        config: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        coordinator: ServerCoordinator = ServerCoordinator(),
        clipboardPrefs: ClipboardPreferencesProvider = StaticClipboardPreferencesProvider(),
        onSession: ((ServerSession) -> Void)? = nil
    ) throws {
        guard fd >= 0 else { throw ListenerError.acceptFailed(errno: 0) }
        let clientFd = try acceptConnection(fd: fd)
        setNoDelay(clientFd)

        let session = makeSession(
            template: config, bridge: bridge,
            coordinator: coordinator, clipboardPrefs: clipboardPrefs,
            sessionLog: log
        )
        onSession?(session)
        runConnection(session: session, clientFd: clientFd, sessionLog: log)
    }

    /// Multi-client: accept connections forever (until `stop()`) and spawn
    /// a dedicated read+write thread pair per accepted client. The supplied
    /// `coordinator` is shared across every spawned session so atoms +
    /// selection state are server-global. Per accept, `sessionLogFactory`
    /// (if supplied) builds a per-session log sink (e.g. a FileLogSink);
    /// otherwise the listener's own log is reused for everyone.
    /// `sessionDidStart` runs synchronously on the listener thread before
    /// the read loop kicks off, so callers can wire `onIdentified` etc.
    public func runAccepting(
        template: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        coordinator: ServerCoordinator,
        clipboardPrefs: ClipboardPreferencesProvider = StaticClipboardPreferencesProvider(),
        sessionLogFactory: ((Int) -> ServerLogSink)? = nil,
        sessionDidStart: ((ServerSession, Int, ServerLogSink?) -> Void)? = nil
    ) {
        while !stopRequested {
            let clientFd: Int32
            do {
                clientFd = try acceptConnection(fd: fd)
            } catch {
                if stopRequested { return }
                log?.log("accept error: \(error)")
                continue
            }
            setNoDelay(clientFd)

            let session = makeSession(
                template: template, bridge: bridge,
                coordinator: coordinator, clipboardPrefs: clipboardPrefs,
                sessionLog: nil
            )
            // sessionLogFactory builds a per-session sink keyed by the
            // client number we got from coordinator allocation; we read
            // that off the session's resourceIdBase tracking would be too
            // indirect, so just keep a local counter mirror.
            let clientNumber = Int((session.config.resourceIdBase &- template.resourceIdBase) / max(template.resourceIdMask &+ 1, 1)) + 1
            let sessionLog = sessionLogFactory?(clientNumber) ?? log
            session.log = sessionLog
            sessionDidStart?(session, clientNumber, sessionLog)

            let driver = Thread {
                self.runConnection(session: session, clientFd: clientFd, sessionLog: sessionLog)
            }
            driver.name = "swiftx.session.\(clientNumber)"
            driver.start()
        }
    }

    // MARK: - internals

    private func makeSession(
        template: ServerConfig,
        bridge: WindowBridge?,
        coordinator: ServerCoordinator,
        clipboardPrefs: ClipboardPreferencesProvider,
        sessionLog: ServerLogSink?
    ) -> ServerSession {
        let allocation = coordinator.allocateClientResourceIdBase(template: template)
        var sessionConfig = template
        sessionConfig.resourceIdBase = allocation.base
        sessionConfig.resourceIdMask = allocation.mask
        return ServerSession(
            config: sessionConfig, bridge: bridge,
            coordinator: coordinator, clipboardPrefs: clipboardPrefs,
            log: sessionLog
        )
    }

    /// Per-connection driver: spawns the write thread, runs the read loop
    /// on the calling thread, tears down on EOF/error. The write lock is
    /// per-connection so two concurrent sessions don't serialize against
    /// each other on socket writes.
    private func runConnection(
        session: ServerSession,
        clientFd: Int32,
        sessionLog: ServerLogSink?
    ) {
        let writeLock = NSLock()
        sessionLog?.log("client connected (resourceIdBase=0x\(String(session.config.resourceIdBase, radix: 16)))")

        let writeThread = Thread { [weak self] in
            guard let self = self else { return }
            while true {
                let bytes = session.outbound.waitAndDrain()
                if bytes.isEmpty { return }
                self.writeAll(clientFd, bytes, lock: writeLock)
            }
        }
        writeThread.name = "swiftx.write"
        writeThread.start()

        var readBuffer = [UInt8](repeating: 0, count: 65536)
        while !stopRequested {
            let n = readBuffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(clientFd, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                sessionLog?.log("client disconnected")
                break
            }
            if n < 0 {
                if errno == EINTR { continue }
                sessionLog?.log("read error: errno=\(errno)")
                break
            }
            let chunk = Array(readBuffer[0..<n])
            let outBytes = session.feed(chunk)
            writeAll(clientFd, outBytes, lock: writeLock)
        }

        session.outbound.stop()
        let deadline = Date().addingTimeInterval(0.25)
        while writeThread.isExecuting && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        Darwin.close(clientFd)
        sessionLog?.log("session: requests=\(session.requestsProcessed) windows=\(session.windows.count) colors=\(session.colors.count)")
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8], lock: NSLock) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
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

    guard Darwin.listen(fd, 8) == 0 else {
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
