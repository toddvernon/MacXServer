import Foundation
import Darwin

// HeliosClient -- Swift client for the Helios agent wire protocol (Phase C, C1).
//
// heliosAgent runs inside the SPARCplug guest and speaks a line-oriented JSON
// request/response protocol over one persistent TCP connection (see the daemon's
// PROTOCOL.md). macXserver reaches it directly over the qemu hostfwd at
// 127.0.0.1:`QemuEngine.heliosHostPort` -- no ssh tunnel. This is the Swift
// twin of the Python `helios_client.py` bridge.
//
// Protocol shape:
//   * one JSON object per line, terminated by '\n'
//   * one request in flight: write a request line, read the response line, repeat
//   * the connection is persistent (many request/response pairs)
//   * file content travels base64 in a JSON string (byte-exact, NUL-safe);
//     metadata stays plain JSON
//
// Threading: this class is NOT thread-safe. It holds a single connection with
// one-request-in-flight semantics, so a consumer must drive it from one thread
// or serial queue at a time (the readiness poll, the shutdown action, and the
// launcher each own their own queue). It is deliberately blocking: callers run
// it off the main thread. Connect and per-request read/write are bounded by the
// `timeout` so a hung guest surfaces as `.timedOut` instead of wedging forever.

public final class HeliosClient {

    /// A transport failure, a timeout, or an `ok:false` response from the daemon.
    public enum HeliosError: Error, LocalizedError, Equatable {
        case notConnected
        case connectionFailed(String)
        case connectionClosed
        case timedOut
        /// The daemon answered `ok:false`; the associated value is its message.
        case protocolError(String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:            return "not connected to the Helios daemon"
            case .connectionFailed(let m): return "Helios connection failed: \(m)"
            case .connectionClosed:        return "Helios connection closed by the daemon"
            case .timedOut:                return "Helios request timed out"
            case .protocolError(let m):    return "Helios error: \(m)"
            case .malformedResponse(let m):return "malformed Helios response: \(m)"
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    /// Shared secret stamped into every request's `auth` field. nil = omit it
    /// (fine against a daemon running open; rejected by one that requires auth).
    private let secret: String?
    private var fd: Int32 = -1
    private var nextID = 0
    /// Bytes read past the end of the last response line, kept for the next read.
    private var readBuffer: [UInt8] = []

    /// `host`/`port` default to the loopback hostfwd the qemu launch opens for the
    /// guest daemon. `timeout` bounds the connect and every read/write.
    public init(host: String = "127.0.0.1",
                port: UInt16 = QemuEngine.heliosHostPort,
                timeout: TimeInterval = 30.0,
                secret: String? = nil) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.secret = secret
    }

    deinit { close() }

    // MARK: - Connection lifecycle

    /// Open the TCP connection. Throws `.timedOut` if the connect doesn't
    /// complete within `timeout`, `.connectionFailed` on any other socket error.
    public func connect() throws {
        if fd >= 0 { return }
        fd = try openConnection()
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        readBuffer.removeAll(keepingCapacity: false)
    }

    public var isConnected: Bool { fd >= 0 }

    // MARK: - Verbs

    public func hello() throws -> HelloResult {
        try call("hello", as: HelloResult.self)
    }

    /// Graceful guest shutdown (the daemon runs `init 5`). The daemon ACKs
    /// `{status:"shutting down"}` first, then runs the command, so this returns
    /// before the guest actually goes down; the connection drops afterward.
    public func shutdown() throws -> ShutdownResult {
        try call("shutdown", as: ShutdownResult.self)
    }

    /// Run a shell command on the guest. `ok:true`/no throw means the command
    /// *ran*; a nonzero exit is reported in `exitCode`, not as an error.
    /// `user` (optional) drops privileges to that user before exec -- the daemon
    /// runs as root and `getpwnam`-validates it (an unknown user throws
    /// `.protocolError`); absent/nil runs as the daemon (root).
    public func runCommand(_ cmd: String,
                           cwd: String? = nil,
                           timeoutMs: Int? = nil,
                           user: String? = nil) throws -> RunResult {
        var fields: [String: Any] = ["cmd": cmd]
        if let cwd { fields["cwd"] = cwd }
        if let timeoutMs { fields["timeout_ms"] = timeoutMs }
        if let user { fields["user"] = user }
        return try call("run_command", fields, as: RunResult.self)
    }

    /// Read a whole regular file. Content arrives base64 and is decoded here, so
    /// the returned `Data` is byte-exact.
    public func readFile(_ path: String) throws -> FileContent {
        let raw = try call("read_file", ["path": path], as: ReadResultRaw.self)
        guard let data = Data(base64Encoded: raw.content) else {
            throw HeliosError.malformedResponse("read_file content was not valid base64")
        }
        return FileContent(data: data, path: raw.path, size: raw.size, mode: raw.mode)
    }

    /// Write a whole regular file atomically. `data` is base64-encoded on the
    /// wire. An explicit `mode` wins; omitting it preserves an existing file's
    /// mode (and owner, when the daemon runs as root) or defaults a new file to 0644.
    @discardableResult
    public func writeFile(_ path: String, data: Data, mode: Int? = nil) throws -> WriteResult {
        var fields: [String: Any] = ["path": path, "content": data.base64EncodedString()]
        if let mode { fields["mode"] = mode }
        return try call("write_file", fields, as: WriteResult.self)
    }

    public func stat(_ path: String) throws -> StatResult {
        try call("stat", ["path": path], as: StatResult.self)
    }

    public func listDir(_ path: String) throws -> ListResult {
        try call("list_dir", ["path": path], as: ListResult.self)
    }

    public func search(_ pattern: String,
                       path: String = ".",
                       ignoreCase: Bool? = nil,
                       max: Int? = nil,
                       timeoutMs: Int? = nil) throws -> SearchResult {
        var fields: [String: Any] = ["pattern": pattern, "path": path]
        if let ignoreCase { fields["ignore_case"] = ignoreCase }
        if let max { fields["max"] = max }
        if let timeoutMs { fields["timeout_ms"] = timeoutMs }
        return try call("search", fields, as: SearchResult.self)
    }

    // MARK: - Request/response core

    /// Send one request (verb + auto-incrementing id + verb fields), read one
    /// response line, and decode its `result` into `R`. Throws on transport
    /// failure, timeout, a malformed line, or an `ok:false` daemon response.
    private func call<R: Decodable>(_ verb: String,
                                    _ fields: [String: Any] = [:],
                                    as _: R.Type) throws -> R {
        guard fd >= 0 else { throw HeliosError.notConnected }
        nextID += 1
        var object: [String: Any] = ["verb": verb, "id": nextID]
        if let secret { object["auth"] = secret }
        for (key, value) in fields { object[key] = value }

        var line = try JSONSerialization.data(withJSONObject: object)
        line.append(0x0A) // '\n'
        try writeAll(line)

        let responseLine = try readLine()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: Envelope<R>
        do {
            envelope = try decoder.decode(Envelope<R>.self, from: responseLine)
        } catch {
            throw HeliosError.malformedResponse(String(decoding: responseLine, as: UTF8.self))
        }
        if !envelope.ok {
            throw HeliosError.protocolError(envelope.error ?? "unknown error")
        }
        guard let result = envelope.result else {
            throw HeliosError.malformedResponse("ok:true but no result field")
        }
        return result
    }

    // MARK: - Socket I/O (Darwin POSIX, matching Listener.swift's house style)

    private func openConnection() throws -> Int32 {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw HeliosError.connectionFailed("socket(): errno \(errno)")
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_aton(host, &addr.sin_addr) != 0 else {
            Darwin.close(sock)
            throw HeliosError.connectionFailed("bad host address \"\(host)\"")
        }

        // Non-blocking connect so we can bound it with poll(); the daemon may be
        // slow to come up (or a hung guest may never answer) and we won't wedge.
        let savedFlags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, savedFlags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                let e = errno
                Darwin.close(sock)
                throw HeliosError.connectionFailed("connect(): errno \(e)")
            }
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let ms = Int32((timeout * 1000).rounded())
            let polled = poll(&pfd, 1, ms)
            if polled == 0 {
                Darwin.close(sock)
                throw HeliosError.timedOut
            }
            if polled < 0 {
                let e = errno
                Darwin.close(sock)
                throw HeliosError.connectionFailed("poll(): errno \(e)")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 {
                Darwin.close(sock)
                throw HeliosError.connectionFailed("connect(): errno \(soError)")
            }
        }

        // Back to blocking, with read/write timeouts so a stalled daemon trips
        // `.timedOut` instead of hanging the calling queue.
        _ = fcntl(sock, F_SETFL, savedFlags & ~O_NONBLOCK)
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
        return sock
    }

    private func writeAll(_ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let w = bytes.withUnsafeBufferPointer { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if w > 0 {
                offset += w
                continue
            }
            if w < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw HeliosError.timedOut }
            }
            throw HeliosError.connectionClosed
        }
    }

    /// Read one '\n'-terminated line, returning the bytes before the newline.
    /// Any bytes read past it are buffered for the next call.
    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = Array(readBuffer[..<nl])
                readBuffer.removeSubrange(...nl)
                return Data(line)
            }
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                readBuffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 { throw HeliosError.connectionClosed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw HeliosError.timedOut }
            throw HeliosError.connectionFailed("read(): errno \(errno)")
        }
    }
}

// MARK: - Response envelope and typed results

/// The success/failure wrapper every response shares. `result` is absent on
/// `ok:false`, so it's optional and checked after `ok`.
private struct Envelope<R: Decodable>: Decodable {
    let id: Int
    let ok: Bool
    let result: R?
    let error: String?
}

public struct HelloResult: Decodable, Equatable, Sendable {
    public let agent: String
    public let version: String
    public let `protocol`: Int
    public let host: String
    /// Seconds the daemon has been running.
    public let uptime: Int
}

public struct ShutdownResult: Decodable, Equatable, Sendable {
    public let status: String
}

public struct RunResult: Decodable, Equatable, Sendable {
    /// 128+signal if the command was killed.
    public let exitCode: Int
    /// Combined stdout+stderr.
    public let output: String
    public let timedOut: Bool
}

/// A decoded `read_file` response: the raw bytes plus the file's metadata.
public struct FileContent: Equatable, Sendable {
    public let data: Data
    public let path: String
    public let size: Int
    /// Low 12 permission bits, decimal (e.g. 420 == 0644).
    public let mode: Int
}

public struct WriteResult: Decodable, Equatable, Sendable {
    public let path: String
    public let bytesWritten: Int
    public let mode: Int
    public let created: Bool
}

public struct StatResult: Decodable, Equatable, Sendable {
    public let path: String
    /// One of file/dir/symlink/fifo/chardev/blockdev/socket/other.
    public let type: String
    public let size: Int
    public let mode: Int
    public let uid: Int
    public let gid: Int
    public let mtime: Int
    /// Present only when `type == "symlink"`: the link's literal target.
    public let target: String?
}

public struct DirEntry: Decodable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let size: Int
    public let mode: Int
    public let mtime: Int
}

public struct ListResult: Decodable, Equatable, Sendable {
    public let path: String
    public let count: Int
    public let entries: [DirEntry]
}

public struct SearchMatch: Decodable, Equatable, Sendable {
    public let file: String
    public let line: Int
    public let text: String
}

public struct SearchResult: Decodable, Equatable, Sendable {
    public let pattern: String
    public let path: String
    public let count: Int
    /// True when `max` was hit -- matches were capped, not silently dropped.
    public let truncated: Bool
    public let exitCode: Int
    public let timedOut: Bool
    public let matches: [SearchMatch]
}

/// Internal: the on-the-wire `read_file` result before base64 decode.
private struct ReadResultRaw: Decodable {
    let path: String
    let size: Int
    let mode: Int
    let encoding: String
    let content: String
}
