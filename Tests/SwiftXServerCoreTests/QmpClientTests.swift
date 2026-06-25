import XCTest
import Darwin
@testable import SwiftXServerCore

// QmpClient round-trip tests against an in-process mock QMP server over a unix
// socket. The mock sends the QMP greeting, answers id-stamped commands, and can
// inject async events -- so we exercise the real socket I/O, the greeting +
// qmp_capabilities handshake, id correlation, event demux, and the error path.

final class QmpClientTests: XCTestCase {

    func testConnectHandshakeAndQueryStatus() throws {
        let server = try MockQmpServer { cmd, _ in
            switch cmd["execute"] as? String {
            case "qmp_capabilities": return ["return": [:]]
            case "query-status":     return ["return": ["status": "running", "running": true]]
            default:                 return ["return": [:]]
            }
        }
        defer { server.stop() }
        server.start()

        let client = QmpClient(socketPath: server.socketPath, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertEqual(try client.queryStatus(), "running")

        // The handshake command goes first, then our query, each id-stamped.
        let names = server.commands.compactMap { $0["execute"] as? String }
        XCTAssertEqual(names, ["qmp_capabilities", "query-status"])
        XCTAssertNotNil(server.commands.last?["id"], "commands carry an id for correlation")
    }

    func testShutdownEventReachesHandler() throws {
        let server = try MockQmpServer { _, _ in ["return": [:]] }
        defer { server.stop() }
        server.start()

        let got = EventBox()
        let client = QmpClient(socketPath: server.socketPath, timeout: 5)
        client.onEvent { got.record($0) }
        try client.connect()
        defer { client.close() }

        server.emitEvent([
            "event": "SHUTDOWN",
            "data": ["guest": true, "reason": "guest-shutdown"],
        ])

        let event = try XCTUnwrap(got.wait(timeout: 2), "SHUTDOWN event should reach the handler")
        XCTAssertEqual(event["event"] as? String, "SHUTDOWN")
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual(data["guest"] as? Bool, true)
        XCTAssertEqual(data["reason"] as? String, "guest-shutdown")
    }

    // An event arriving *between* a command and its response must route to the
    // handler without stealing the response -- the whole reason QmpClient demuxes.
    func testEventInterleavedWithResponseIsDemuxed() throws {
        let server = try MockQmpServer { cmd, srv in
            if cmd["execute"] as? String == "query-status" {
                // Emit an event first, THEN answer the command.
                srv.emitEvent(["event": "RESET", "data": ["guest": true]])
                return ["return": ["status": "running"]]
            }
            return ["return": [:]]
        }
        defer { server.stop() }
        server.start()

        let got = EventBox()
        let client = QmpClient(socketPath: server.socketPath, timeout: 5)
        client.onEvent { got.record($0) }
        try client.connect()
        defer { client.close() }

        XCTAssertEqual(try client.queryStatus(), "running", "response still matched despite the event")
        let event = try XCTUnwrap(got.wait(timeout: 2))
        XCTAssertEqual(event["event"] as? String, "RESET")
    }

    func testCommandErrorThrows() throws {
        let server = try MockQmpServer { cmd, _ in
            if cmd["execute"] as? String == "qmp_capabilities" { return ["return": [:]] }
            return ["error": ["class": "GenericError", "desc": "the lever is stuck"]]
        }
        defer { server.stop() }
        server.start()

        let client = QmpClient(socketPath: server.socketPath, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertThrowsError(try client.execute("system_reset")) { error in
            XCTAssertEqual(error as? QmpClient.QmpError, .commandError("the lever is stuck"))
        }
    }

    // qemu may exit before/while replying to `quit`; the client treats a
    // connection close right after the request as success.
    func testQuitToleratesConnectionClose() throws {
        let server = try MockQmpServer { cmd, _ in
            if cmd["execute"] as? String == "qmp_capabilities" { return ["return": [:]] }
            return nil   // for `quit`: send nothing; the mock then closes (mimics qemu exit)
        }
        defer { server.stop() }
        server.start()

        let client = QmpClient(socketPath: server.socketPath, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertNoThrow(try client.quit())
    }

    func testConnectToMissingSocketFails() {
        let client = QmpClient(socketPath: "/tmp/qmp-does-not-exist-\(UUID().uuidString).sock", timeout: 2)
        XCTAssertThrowsError(try client.connect()) { error in
            guard case .connectionFailed = (error as? QmpClient.QmpError) else {
                return XCTFail("expected .connectionFailed, got \(error)")
            }
        }
    }
}

// MARK: - test helper: thread-safe single-event capture

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var event: [String: Any]?

    func record(_ e: [String: Any]) {
        lock.lock(); event = e; lock.unlock()
        sem.signal()
    }
    func wait(timeout: TimeInterval) -> [String: Any]? {
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return event
    }
}

// MARK: - in-process mock QMP server (unix socket)

/// A minimal one-connection QMP server: sends the greeting, records id-stamped
/// commands, and answers via `responder` (which also gets a handle to the server
/// so it can inject events mid-command). `@unchecked Sendable`: serves on its own
/// queue, guards shared state with locks.
final class MockQmpServer: @unchecked Sendable {
    let socketPath: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "mock-qmp-server")
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var _commands: [[String: Any]] = []
    private var clientFD: Int32 = -1
    /// (command, server) -> response without id (server stamps it), or nil to send nothing.
    private let responder: ([String: Any], MockQmpServer) -> [String: Any]?

    init(responder: @escaping ([String: Any], MockQmpServer) -> [String: Any]?) throws {
        self.responder = responder
        self.socketPath = "/tmp/qmp-test-\(UUID().uuidString.prefix(8)).sock"

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

    var commands: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    func start() { queue.async { [self] in serve() } }

    func stop() {
        lock.lock(); let c = clientFD; lock.unlock()
        if c >= 0 { Darwin.close(c) }
        Darwin.close(listenFD)
        unlink(socketPath)
    }

    func emitEvent(_ event: [String: Any]) {
        lock.lock(); let c = clientFD; lock.unlock()
        guard c >= 0 else { return }
        writeLine(c, event)
    }

    private func serve() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        lock.lock(); clientFD = cfd; lock.unlock()

        // QMP greeting first.
        writeLine(cfd, ["QMP": ["version": ["qemu": ["major": 9, "minor": 2, "micro": 4]],
                                "capabilities": []]])

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                guard let cmd = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any]
                else { continue }
                lock.lock(); _commands.append(cmd); lock.unlock()
                let isQuit = (cmd["execute"] as? String) == "quit"
                if var resp = responder(cmd, self) {
                    if let id = cmd["id"] { resp["id"] = id }
                    writeLine(cfd, resp)
                }
                if isQuit { break }   // mimic qemu exiting after a quit
                continue
            }
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(cfd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        Darwin.close(cfd)
        lock.lock(); clientFD = -1; lock.unlock()
    }

    private func writeLine(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }
}
