import Foundation
import Darwin

// QmpClient -- Swift client for QEMU's QMP (QEMU Machine Protocol) over a unix
// socket. This is the *VM/hypervisor* control plane for the captive emulator
// (VM_CONTROL.md): clean-halt detection (the SHUTDOWN event), a qcow2-clean hard
// stop (quit), and VM liveness (query-status). It is deliberately NOT a
// HeliosClient variant -- HeliosClient is strict one-request-in-flight, but QMP
// interleaves asynchronous events (SHUTDOWN, RESET, STOP, RESUME) with command
// responses, so this client runs a background reader that demuxes events from
// id-correlated responses.
//
// Protocol shape (qemu QMP):
//   * connect to the unix socket qemu opened with `-qmp unix:<path>,server=on`
//   * the server immediately sends a greeting line: { "QMP": { ... } }
//   * the client sends { "execute": "qmp_capabilities" } to leave negotiation
//     mode, then may issue commands
//   * each command may carry an "id"; the response echoes it, so responses can
//     be matched even when events arrive in between
//   * events arrive at any time as { "event": "...", "data": {...} } (no id)
//
// Threading: connect() and execute() are blocking and called from a consumer
// queue (QemuEngine's). A private reader queue owns the socket read loop and
// routes incoming lines. The event handler is invoked ON THE READER QUEUE -- the
// consumer (QemuEngine) hops to its own queue inside the handler.

public final class QmpClient {

    public enum QmpError: Error, LocalizedError, Equatable {
        case notConnected
        case connectionFailed(String)
        case connectionClosed
        case timedOut
        case badGreeting(String)
        case malformedResponse(String)
        /// The server answered `{"error": {...}}`; the associated value is its `desc`.
        case commandError(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:            return "not connected to QMP"
            case .connectionFailed(let m): return "QMP connection failed: \(m)"
            case .connectionClosed:        return "QMP connection closed"
            case .timedOut:                return "QMP request timed out"
            case .badGreeting(let m):      return "QMP greeting was not understood: \(m)"
            case .malformedResponse(let m):return "malformed QMP message: \(m)"
            case .commandError(let m):     return "QMP command error: \(m)"
            }
        }
    }

    private let socketPath: String
    private let timeout: TimeInterval
    // userInitiated so close()'s reader-join (called from the engine queue on
    // shutdown) doesn't wait on a lower-QoS thread -- the Thread Performance
    // Checker flags that as a priority inversion.
    private let readerQueue = DispatchQueue(label: "swiftx.qmp.reader", qos: .userInitiated)
    private let lock = NSLock()

    private var fd: Int32 = -1
    private var reading = false
    private var nextID = 0
    /// id -> waiter, filled by the reader when the matching response lands.
    private var pending: [Int: (Result<[String: Any], QmpError>) -> Void] = [:]
    private var eventHandler: (([String: Any]) -> Void)?
    /// Bytes read past the end of the last line, kept for the next read.
    private var readBuffer: [UInt8] = []
    /// Signaled when the reader loop has fully exited (so close() can join it).
    private let readerDone = DispatchSemaphore(value: 0)

    public init(socketPath: String, timeout: TimeInterval = 5.0) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    deinit { close() }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 && reading
    }

    /// Set the async-event handler. Called on the reader queue for every QMP
    /// event (SHUTDOWN etc.). Set it before connect() so the greeting-adjacent
    /// events can't be missed.
    public func onEvent(_ handler: @escaping ([String: Any]) -> Void) {
        lock.lock(); eventHandler = handler; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Open the socket, read+verify the QMP greeting, start the reader loop, and
    /// complete the `qmp_capabilities` handshake. Throws if any step fails.
    public func connect() throws {
        guard fd < 0 else { return }

        let sock = try openUnixSocket()
        fd = sock

        // The greeting is the first line; read it synchronously before the loop
        // starts (no concurrency on readBuffer yet).
        let greetingLine: Data
        do {
            greetingLine = try readLineBlocking()
        } catch {
            Darwin.close(sock); fd = -1
            throw error
        }
        let greeting = (try? JSONSerialization.jsonObject(with: greetingLine)) as? [String: Any]
        guard greeting?["QMP"] != nil else {
            Darwin.close(sock); fd = -1
            throw QmpError.badGreeting(String(decoding: greetingLine, as: UTF8.self))
        }

        reading = true
        readerQueue.async { [weak self] in self?.readLoop() }

        // Leave capability-negotiation mode. Goes through the normal command path
        // (the loop is running), so its response is id-correlated.
        _ = try execute("qmp_capabilities")
    }

    public func close() {
        lock.lock()
        guard reading || fd >= 0 else { lock.unlock(); return }
        let wasReading = reading
        reading = false
        let f = fd
        lock.unlock()

        // Wake a blocked reader; the loop closes the fd and fails pending waiters.
        if f >= 0 { shutdown(f, SHUT_RDWR) }
        if wasReading {
            _ = readerDone.wait(timeout: .now() + 1.0)
        } else if f >= 0 {
            // connect() failed before the loop started; close here.
            Darwin.close(f)
            lock.lock(); fd = -1; lock.unlock()
        }
    }

    // MARK: - Commands

    /// Send one command and block until its id-matched response (or timeout).
    /// Must NOT be called from the reader queue (it would deadlock).
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> [String: Any] {
        lock.lock()
        guard fd >= 0, reading || command == "qmp_capabilities" else {
            lock.unlock(); throw QmpError.notConnected
        }
        nextID += 1
        let id = nextID
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[String: Any], QmpError> = .failure(.timedOut)
        pending[id] = { result in outcome = result; sem.signal() }
        lock.unlock()

        var obj: [String: Any] = ["execute": command, "id": id]
        if let arguments { obj["arguments"] = arguments }
        do {
            try writeJSONLine(obj)
        } catch {
            lock.lock(); pending[id] = nil; lock.unlock()
            throw error
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending[id] = nil; lock.unlock()
            throw QmpError.timedOut
        }
        return try outcome.get()
    }

    /// VM run state ("running", "paused", "shutdown", ...). The hypervisor-level
    /// liveness signal, distinct from Helios `hello` (which is OS-level).
    public func queryStatus() throws -> String {
        let r = try execute("query-status")
        guard let status = r["status"] as? String else {
            throw QmpError.malformedResponse("query-status had no status field")
        }
        return status
    }

    /// Clean hard-stop: qemu drains + closes the block layer (qcow2 consistent)
    /// then exits. The guest filesystem is still dirty (no init 5), but the
    /// container won't be torn mid-write like a SIGKILL. qemu may exit before the
    /// response lands, so a connection-close right after the request counts as
    /// success.
    public func quit() throws {
        do {
            _ = try execute("quit")
        } catch QmpError.connectionClosed {
            // qemu exited before/while replying -- that's the intended outcome.
        }
    }

    // MARK: - Reader loop

    private func readLoop() {
        while true {
            lock.lock(); let go = reading; lock.unlock()
            if !go { break }

            let line: Data
            do {
                line = try readLineBlocking()
            } catch QmpError.timedOut {
                continue                       // idle wakeup; re-check `reading`
            } catch {
                break                          // closed or errored
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                continue                       // skip an unparseable line
            }
            route(obj)
        }

        // Teardown: close the fd, fail every outstanding waiter, signal join.
        lock.lock()
        let f = fd; fd = -1
        let waiters = pending; pending.removeAll()
        lock.unlock()
        if f >= 0 { Darwin.close(f) }
        for (_, waiter) in waiters { waiter(.failure(.connectionClosed)) }
        readerDone.signal()
    }

    private func route(_ obj: [String: Any]) {
        if obj["event"] != nil {
            lock.lock(); let handler = eventHandler; lock.unlock()
            handler?(obj)
            return
        }
        // A command response: match by id.
        if let id = obj["id"] as? Int {
            lock.lock(); let waiter = pending.removeValue(forKey: id); lock.unlock()
            if let err = obj["error"] as? [String: Any] {
                let desc = (err["desc"] as? String) ?? "unknown QMP error"
                waiter?(.failure(.commandError(desc)))
            } else {
                waiter?(.success((obj["return"] as? [String: Any]) ?? [:]))
            }
            return
        }
        // A response with no id (shouldn't happen for our id-stamped commands) or
        // a stray greeting -- ignore.
    }

    // MARK: - Socket I/O

    private func openUnixSocket() throws -> Int32 {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw QmpError.connectionFailed("socket(): errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        guard pathBytes.count < cap else {
            Darwin.close(sock)
            throw QmpError.connectionFailed("socket path too long (\(pathBytes.count) >= \(cap))")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(sock)
            throw QmpError.connectionFailed("connect(\(socketPath)): errno \(e)")
        }

        // A bounded read timeout so the reader loop can poll `reading` and exit
        // cleanly even when the socket is idle.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }

    private func writeJSONLine(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let bytes = [UInt8](data)
        var offset = 0
        let f = { lock.lock(); defer { lock.unlock() }; return fd }()
        guard f >= 0 else { throw QmpError.notConnected }
        while offset < bytes.count {
            let w = bytes.withUnsafeBufferPointer { ptr -> Int in
                Darwin.write(f, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if w > 0 { offset += w; continue }
            if w < 0 && errno == EINTR { continue }
            throw QmpError.connectionClosed
        }
    }

    /// Read one '\n'-terminated line. Throws `.timedOut` on an idle SO_RCVTIMEO
    /// wakeup so the reader loop can re-check `reading`.
    private func readLineBlocking() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                var lineBytes = Array(readBuffer[..<nl])
                readBuffer.removeSubrange(...nl)
                if lineBytes.last == 0x0D { lineBytes.removeLast() }   // strip CR
                return Data(lineBytes)
            }
            let f = { lock.lock(); defer { lock.unlock() }; return fd }()
            guard f >= 0 else { throw QmpError.connectionClosed }
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(f, ptr.baseAddress, ptr.count)
            }
            if n > 0 { readBuffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { throw QmpError.connectionClosed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw QmpError.timedOut }
            throw QmpError.connectionFailed("read(): errno \(errno)")
        }
    }
}
