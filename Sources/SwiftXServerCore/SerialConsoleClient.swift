import Foundation
import Darwin

// SerialConsoleClient -- streams the captive qemu's serial console from a unix
// socket (qemu's `-serial unix:<path>,server=on,wait=off`). VM_CONTROL.md
// Stage 2: this replaces the `-nographic` stdio pipe. Two payoffs:
//   * an orphaned qemu (its parent process gone) no longer busy-spins at 100%
//     CPU on a hung-up stdio console fd -- with the console on a listening
//     socket, our disconnect just drops the client and qemu keeps serving;
//   * the console becomes reconnectable -- a later process can re-attach the
//     observation view to a still-running VM (the Stage 3 orphan recovery).
//
// Unlike QmpClient this is a raw byte stream, not line-oriented JSON: the
// console is the guest's serial TTY, so there are no requests, responses, or
// events -- a background reader just delivers bytes to the data handler as they
// arrive. The socket I/O (unix connect, SO_RCVTIMEO poll loop, reader-join on
// close) mirrors QmpClient deliberately; the two clients stay separate because
// their payloads are unrelated.
public final class SerialConsoleClient {

    public enum ConsoleError: Error, LocalizedError, Equatable {
        case connectionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "console connection failed: \(m)"
            }
        }
    }

    private let socketPath: String
    private let readerQueue = DispatchQueue(label: "swiftx.console.reader")
    private let lock = NSLock()

    private var fd: Int32 = -1
    private var reading = false
    private var dataHandler: ((Data) -> Void)?
    /// Signaled when the reader loop has fully exited (so close() can join it).
    private let readerDone = DispatchSemaphore(value: 0)

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { close() }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 && reading
    }

    /// Set the byte handler. Called on the reader queue for each chunk that
    /// arrives. Set it before connect() so no early console output is missed.
    public func onData(_ handler: @escaping (Data) -> Void) {
        lock.lock(); dataHandler = handler; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Open the socket and start the background reader. Throws if the connect
    /// fails (e.g. qemu hasn't opened the listening socket yet -- the caller
    /// retries).
    public func connect() throws {
        guard fd < 0 else { return }
        let sock = try openUnixSocket()
        lock.lock(); fd = sock; reading = true; lock.unlock()
        readerQueue.async { [weak self] in self?.readLoop() }
    }

    public func close() {
        lock.lock()
        guard reading || fd >= 0 else { lock.unlock(); return }
        let wasReading = reading
        reading = false
        let f = fd
        lock.unlock()

        // Wake a blocked reader; the loop closes the fd and signals join.
        if f >= 0 { shutdown(f, SHUT_RDWR) }
        if wasReading {
            _ = readerDone.wait(timeout: .now() + 1.0)
        } else if f >= 0 {
            // connect() opened the fd but the loop never started; close here.
            Darwin.close(f)
            lock.lock(); fd = -1; lock.unlock()
        }
    }

    // MARK: - Reader loop

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock(); let go = reading; let f = fd; lock.unlock()
            if !go || f < 0 { break }

            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(f, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                let data = Data(chunk[0..<n])
                lock.lock(); let h = dataHandler; lock.unlock()
                h?(data)
                continue
            }
            if n == 0 { break }                                  // qemu closed (exited)
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }   // idle SO_RCVTIMEO wakeup
            break                                                // hard error
        }

        // Teardown: mark not-reading, close the fd, signal join.
        lock.lock()
        reading = false
        let f = fd; fd = -1
        lock.unlock()
        if f >= 0 { Darwin.close(f) }
        readerDone.signal()
    }

    // MARK: - Socket I/O

    private func openUnixSocket() throws -> Int32 {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw ConsoleError.connectionFailed("socket(): errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        guard pathBytes.count < cap else {
            Darwin.close(sock)
            throw ConsoleError.connectionFailed("socket path too long (\(pathBytes.count) >= \(cap))")
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
            throw ConsoleError.connectionFailed("connect(\(socketPath)): errno \(e)")
        }

        // A bounded read timeout so the reader loop can poll `reading` and exit
        // cleanly even when the console is idle (no guest output).
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }
}
