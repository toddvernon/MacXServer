import Foundation
import Darwin
import SwiftXCaptureCore

// TCP listener glue.
//
// `runOne(...)` is the single-client path used by tests — bind, accept ONE
// connection, drive a ServerSession on it, return when the client closes.
//
// `runAccepting(...)` is the multi-client path used by the real server —
// loop accepting connections and start a `DispatchSourceRead` on each
// accepted client. The supplied `ServerCoordinator` hands out a fresh
// resource-id-base per accept so client-allocated IDs don't collide, and
// keeps atoms + selection ownership shared across all sessions (X11 spec
// requires both to be server-global).
//
// Per session, ONE thread (the session's `protocolQueue`) owns:
//   * the client socket (read + write)
//   * all session state mutation
//   * all event synthesis (AppKit-side callbacks hop onto this queue
//     before touching state — see ServerSession.init)
//
// This matches R6's single-thread `Dispatch()` model; see
// SERVER_CONCURRENCY.md for the rationale and migration. There is no
// write thread, no OutboundQueue producer/consumer split, no writeLock.

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
        captureSink: CaptureSink? = nil,
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
        // runConnection is non-blocking (sets up a DispatchSourceRead and
        // returns), so block here on a semaphore until the cancel handler
        // fires on EOF/error. That matches the old runOne semantics.
        let done = DispatchSemaphore(value: 0)
        runConnection(
            session: session,
            clientFd: clientFd,
            sessionLog: log,
            captureSink: captureSink
        ) {
            done.signal()
        }
        done.wait()
    }

    /// Multi-client: accept connections forever (until `stop()`) and start
    /// a `DispatchSourceRead` on each accepted client targeting that
    /// session's `protocolQueue`. The supplied `coordinator` is shared
    /// across every accepted session so atoms + selection state are
    /// server-global. Per accept, `sessionLogFactory` (if supplied) builds
    /// a per-session log sink (e.g. a FileLogSink); otherwise the
    /// listener's own log is reused for everyone. `sessionDidStart` runs
    /// synchronously on the listener thread before the dispatch source
    /// resumes, so callers can wire `onIdentified` etc.
    ///
    /// `captureSinkFactory`, when present, builds a per-session
    /// CaptureSink (typically a SessionCapture writing to `/tmp/swift-x-
    /// captures/`). The listener tees client-to-server bytes after each
    /// socket read and server-to-client bytes before each socket write
    /// to the sink, and calls `finalize()` on disconnect. `nil` factory
    /// or factory returning `nil` disables capture for that session.
    public func runAccepting(
        template: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        coordinator: ServerCoordinator,
        clipboardPrefs: ClipboardPreferencesProvider = StaticClipboardPreferencesProvider(),
        sessionLogFactory: ((Int) -> ServerLogSink)? = nil,
        captureSinkFactory: ((Int) -> CaptureSink?)? = nil,
        sessionDidStart: ((ServerSession, Int, ServerLogSink?, CaptureSink?) -> Void)? = nil
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
            let captureSink = captureSinkFactory?(clientNumber) ?? nil
            sessionDidStart?(session, clientNumber, sessionLog, captureSink)

            // Non-blocking — dispatch source registers itself on the
            // session's protocolQueue and returns immediately. The
            // listener thread loops back to accept the next connection.
            runConnection(
                session: session,
                clientFd: clientFd,
                sessionLog: sessionLog,
                captureSink: captureSink
            )
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

    /// Per-connection setup. Non-blocking: registers a DispatchSourceRead
    /// on the client socket targeting `session.protocolQueue`, installs
    /// the session's `writeCallback` so AppKit-side handlers can push
    /// bytes, then returns. The dispatch source's cancel handler does
    /// teardown on EOF / error; `onClose` fires last for callers (runOne)
    /// that want to block on the session lifetime.
    ///
    /// `captureSink`, when non-nil, gets every C2S byte after each
    /// successful socket read and every S2C byte before each socket
    /// write. The sink is finalized in the cancel handler so the
    /// `.xtap` lands on disk regardless of whether disconnect was clean
    /// or dirty. Both read and write paths run on the session's
    /// protocolQueue, so the sink sees calls in wire order and
    /// single-threaded.
    private func runConnection(
        session: ServerSession,
        clientFd: Int32,
        sessionLog: ServerLogSink?,
        captureSink: CaptureSink? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) {
        sessionLog?.log("client connected (resourceIdBase=0x\(String(session.config.resourceIdBase, radix: 16)))")

        // Single writer: protocolQueue. The closure captures clientFd and
        // pushes whatever bytes the session hands it directly to the
        // socket via writeAll. No lock needed — every call to this
        // closure runs on protocolQueue. Capture sink (if set) sees the
        // bytes immediately before they go on the wire.
        session.writeCallback = { bytes in
            captureSink?.record(direction: .serverToClient, bytes: bytes)
            writeAllToSocket(clientFd, bytes)
        }

        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: clientFd,
            queue: session.protocolQueue
        )
        // Use a ref-cycle-breaking holder so the cancel handler can clear
        // the source after firing. Without it the source captures itself.
        let sourceHolder = ReadSourceHolder(source: readSource)

        readSource.setEventHandler {
            var readBuffer = [UInt8](repeating: 0, count: 65536)
            let n = readBuffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(clientFd, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                sourceHolder.source?.cancel()
                return
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
                sessionLog?.log("read error: errno=\(errno)")
                sourceHolder.source?.cancel()
                return
            }
            let chunk = Array(readBuffer[0..<n])
            captureSink?.record(direction: .clientToServer, bytes: chunk)
            let outBytes = session.feed(chunk)
            if !outBytes.isEmpty {
                captureSink?.record(direction: .serverToClient, bytes: outBytes)
                writeAllToSocket(clientFd, outBytes)
            }
            // Session marked itself unrecoverable (e.g., a bogus request
            // length wedged the parse stream). Drain any outbound bytes
            // we just queued (the trailing XError) and tear down.
            if session.shouldClose {
                sessionLog?.log("session signaled close after feed — cancelling read source")
                sourceHolder.source?.cancel()
                return
            }
        }

        readSource.setCancelHandler {
            sessionLog?.log("client disconnected")
            // Per X11 spec, default close-down mode is DestroyAll — the
            // server destroys all the client's resources. The most visible
            // effect for us: every top-level NSWindow the client mapped
            // should close, so quitting an X client doesn't leave its
            // windows on screen. Runs on the read source's queue
            // (== session.protocolQueue), so session-state mutation here
            // is in-thread.
            session.cleanupOnDisconnect()
            Darwin.close(clientFd)
            sessionLog?.log("session: requests=\(session.requestsProcessed) windows=\(session.windows.count) colors=\(session.colors.count)")
            if let sink = captureSink {
                do {
                    try sink.finalize()
                } catch {
                    sessionLog?.log("capture finalize error: \(error)")
                }
            }
            sourceHolder.source = nil
            onClose?()
        }

        readSource.resume()
    }
}

/// Heap-allocated holder so the dispatch source's event/cancel handlers
/// can refer to it without forming a retain cycle on the source itself.
private final class ReadSourceHolder: @unchecked Sendable {
    var source: DispatchSourceRead?
    init(source: DispatchSourceRead) { self.source = source }
}

/// Free-function socket writer. Called only from a session's protocolQueue
/// (either from the read source's event handler after `feed`, or from
/// `flushOutbound` invoked at the tail of an AppKit-side handler), so no
/// locking is needed.
private func writeAllToSocket(_ fd: Int32, _ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    WireTrace.shared?.wrote(byteCount: bytes.count, peek: Array(bytes.prefix(8)))
    var written = 0
    while written < bytes.count {
        let w = bytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress!.advanced(by: written), bytes.count - written)
        }
        if w <= 0 { return }
        written += w
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
