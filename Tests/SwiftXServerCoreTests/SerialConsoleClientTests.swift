import XCTest
import Darwin
@testable import SwiftXServerCore

// SerialConsoleClient tests against an in-process mock serial server over a unix
// socket. The mock accepts one connection and pushes raw bytes; we exercise the
// real socket I/O, the streaming reader, multi-chunk delivery, and clean close.

final class SerialConsoleClientTests: XCTestCase {

    func testStreamsBytesToHandler() throws {
        let server = try MockSerialServer()
        defer { server.stop() }
        server.start()

        let sink = DataSink()
        let client = SerialConsoleClient(socketPath: server.socketPath)
        client.onData { sink.append($0) }
        try client.connect()
        defer { client.close() }

        server.send("SPARCstation 5\n")
        XCTAssertTrue(sink.wait(forSubstring: "SPARCstation 5", timeout: 2),
                      "console bytes should reach the handler")
    }

    // Bytes pushed in separate writes accumulate in order -- the console is a
    // raw stream, so the client must not lose or reorder chunks.
    func testMultipleChunksAccumulate() throws {
        let server = try MockSerialServer()
        defer { server.stop() }
        server.start()

        let sink = DataSink()
        let client = SerialConsoleClient(socketPath: server.socketPath)
        client.onData { sink.append($0) }
        try client.connect()
        defer { client.close() }

        server.send("Probing ")
        server.send("/iommu")
        server.send("/sbus\n")
        XCTAssertTrue(sink.wait(forSubstring: "Probing /iommu/sbus", timeout: 2))
    }

    func testConnectToMissingSocketFails() {
        let client = SerialConsoleClient(
            socketPath: "/tmp/console-does-not-exist-\(UUID().uuidString).sock")
        XCTAssertThrowsError(try client.connect()) { error in
            guard case .connectionFailed = (error as? SerialConsoleClient.ConsoleError) else {
                return XCTFail("expected .connectionFailed, got \(error)")
            }
        }
    }

    func testIsConnectedReflectsLifecycle() throws {
        let server = try MockSerialServer()
        defer { server.stop() }
        server.start()

        let client = SerialConsoleClient(socketPath: server.socketPath)
        XCTAssertFalse(client.isConnected)
        try client.connect()
        XCTAssertTrue(client.isConnected)
        client.close()
        XCTAssertFalse(client.isConnected)
    }

    // close() must join the reader and be safe to call more than once.
    func testCloseIsIdempotent() throws {
        let server = try MockSerialServer()
        defer { server.stop() }
        server.start()

        let client = SerialConsoleClient(socketPath: server.socketPath)
        try client.connect()
        client.close()
        XCTAssertNoThrow(client.close())   // second close is a no-op, no hang
        XCTAssertFalse(client.isConnected)
    }
}

// MARK: - test helper: thread-safe byte accumulator with substring wait

private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ d: Data) {
        lock.lock(); bytes.append(d); lock.unlock()
    }

    /// Poll until the accumulated bytes contain `substring` (UTF-8), or timeout.
    func wait(forSubstring substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let text = String(decoding: bytes, as: UTF8.self)
            lock.unlock()
            if text.contains(substring) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}

// MARK: - in-process mock serial server (unix socket)

/// A minimal one-connection serial server: accepts a client and pushes raw bytes
/// on demand. `@unchecked Sendable`: serves on its own queue, guards the client
/// fd with a lock.
final class MockSerialServer: @unchecked Sendable {
    let socketPath: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "mock-serial-server")
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var clientFD: Int32 = -1

    init() throws {
        self.socketPath = "/tmp/con-test-\(UUID().uuidString.prefix(8)).sock"

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }

        unlink(socketPath)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        self.listenFD = fd
    }

    func start() { queue.async { [self] in serve() } }

    func stop() {
        lock.lock(); let c = clientFD; lock.unlock()
        if c >= 0 { Darwin.close(c) }
        Darwin.close(listenFD)
        unlink(socketPath)
    }

    /// Push raw bytes to the connected client. Spin briefly if the accept hasn't
    /// landed yet so a send right after connect isn't dropped.
    func send(_ text: String) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock(); let c = clientFD; lock.unlock()
            if c >= 0 {
                let data = Data(text.utf8)
                writeLock.lock()
                _ = data.withUnsafeBytes { Darwin.write(c, $0.baseAddress, data.count) }
                writeLock.unlock()
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func serve() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        lock.lock(); clientFD = cfd; lock.unlock()
        // Hold the connection open; the test drives sends and tears down via stop().
        // Block on a read so the thread parks until the socket closes.
        var scratch = [UInt8](repeating: 0, count: 256)
        while true {
            let n = scratch.withUnsafeMutableBufferPointer { Darwin.read(cfd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
        }
        Darwin.close(cfd)
        lock.lock(); clientFD = -1; lock.unlock()
    }
}
