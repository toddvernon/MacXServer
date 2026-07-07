import XCTest
import Darwin
@testable import SwiftXServerCore

// HeliosClient round-trip tests, driven against an in-process mock daemon that
// speaks the same newline-JSON protocol the real heliosAgent does. The mock
// binds 127.0.0.1:<ephemeral>, accepts one connection, and answers each request
// line with a response the test supplies -- so we exercise the actual socket
// read/write, the framing, base64 encode/decode, and the error path.

final class HeliosClientTests: XCTestCase {

    // MARK: hello

    func testHelloRoundTripParsesAllFields() throws {
        let server = try MockHeliosServer { req, id in
            XCTAssertEqual(req["verb"] as? String, "hello")
            return ["id": id, "ok": true, "result": [
                "agent": "heliosAgent", "version": "0.1.0", "protocol": 1,
                "host": "sparcplug", "uptime": 42,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let hello = try client.hello()
        XCTAssertEqual(hello, HelloResult(agent: "heliosAgent", version: "0.1.0",
                                          protocol: 1, host: "sparcplug", uptime: 42))
    }

    // MARK: sysinfo

    /// Full response, mirroring the real NetBSD 9.2 capture from the 0.2.0
    /// agent validation (2026-07-07).
    func testSysInfoParsesFullResponse() throws {
        let server = try MockHeliosServer { req, id in
            XCTAssertEqual(req["verb"] as? String, "sysinfo")
            return ["id": id, "ok": true, "result": [
                "uname": ["sysname": "NetBSD", "release": "9.2",
                          "machine": "sparc", "nodename": "netbsd.localdomain"],
                "hostid": "80eff4e5",
                "memMB": 239.875,
                "swap": ["totalKB": 1049600, "usedKB": 0],
                "load": [0.48, 0.35, 0.15],
                "disks": [["mount": "/", "sizeKB": 40253548, "usedPct": 2]],
                "time": 1783453848,
                "agentUptime": 15,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let sys = try client.sysinfo()
        XCTAssertEqual(sys.uname?.sysname, "NetBSD")
        XCTAssertEqual(sys.uname?.machine, "sparc")
        XCTAssertEqual(sys.hostid, "80eff4e5")
        XCTAssertEqual(sys.memMB ?? 0, 239.875, accuracy: 0.001)
        XCTAssertEqual(sys.swap?.totalKB ?? 0, 1_049_600, accuracy: 0.5)
        XCTAssertEqual(sys.load?.count, 3)
        XCTAssertEqual(sys.disks?.first?.mount, "/")
        XCTAssertEqual(sys.disks?.first?.usedPct ?? 0, 2, accuracy: 0.001)
        XCTAssertGreaterThan(sys.time, 0)
    }

    /// The fields-optional contract: the SunOS fault-drill shape (kmem
    /// unavailable -> memMB/load/swap absent) must decode, not throw. Callers
    /// never infer "agent down" from missing fields.
    func testSysInfoToleratesAbsentFields() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "uname": ["sysname": "SunOS", "release": "4.1.4",
                          "machine": "sun4m", "nodename": "sunos"],
                "hostid": "80eff3e5",
                "disks": [["mount": "/", "sizeKB": 986095, "usedPct": 5]],
                "time": 1783454875,
                "agentUptime": 9,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let sys = try client.sysinfo()
        XCTAssertEqual(sys.uname?.release, "4.1.4")
        XCTAssertNil(sys.memMB)
        XCTAssertNil(sys.load)
        XCTAssertNil(sys.swap)
        XCTAssertEqual(sys.disks?.count, 1)
    }

    /// A pre-0.2.0 agent answers "unknown verb": surfaced as .protocolError,
    /// which callers treat as "no sysinfo", never as unreachable.
    func testSysInfoUnknownVerbSurfacesAsProtocolError() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": false, "error": "unknown verb: sysinfo"]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertThrowsError(try client.sysinfo()) { error in
            guard case HeliosClient.HeliosError.protocolError(let m) = error else {
                return XCTFail("expected protocolError, got \(error)")
            }
            XCTAssertTrue(m.contains("unknown verb"))
        }
    }

    func testIdIncrementsAndIsSentOnTheWire() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": ["status": "shutting down"]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        _ = try client.shutdownNoDrop()
        _ = try client.shutdownNoDrop()
        let ids = server.requests.map { $0["id"] as? Int }
        XCTAssertEqual(ids, [1, 2])
    }

    // MARK: run_command -- optional-field omission

    func testRunCommandOmitsNilOptionalFields() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "exit_code": 0, "output": "ok\n", "timed_out": false,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let result = try client.runCommand("ls")
        XCTAssertEqual(result, RunResult(exitCode: 0, output: "ok\n", timedOut: false))

        let req = server.requests[0]
        XCTAssertEqual(req["cmd"] as? String, "ls")
        XCTAssertNil(req["cwd"], "nil cwd must be omitted from the request")
        XCTAssertNil(req["timeout_ms"], "nil timeout must be omitted from the request")
    }

    func testRunCommandIncludesSetOptionalFields() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "exit_code": 2, "output": "boom", "timed_out": false,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let result = try client.runCommand("cc x.c", cwd: "/tmp", timeoutMs: 60000)
        XCTAssertEqual(result.exitCode, 2, "nonzero exit is data, not an error")

        let req = server.requests[0]
        XCTAssertEqual(req["cwd"] as? String, "/tmp")
        XCTAssertEqual(req["timeout_ms"] as? Int, 60000)
    }

    // MARK: read_file / write_file -- byte-exact base64

    func testReadFileBase64DecodesByteExact() throws {
        // Bytes a JSON string can't carry safely: NUL and high bytes.
        let payload = Data([0x00, 0x01, 0xFF, 0x41, 0x42, 0x0A, 0x80])
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/etc/x", "size": payload.count, "mode": 420,
                "encoding": "base64", "content": payload.base64EncodedString(),
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let file = try client.readFile("/etc/x")
        XCTAssertEqual(file.data, payload)
        XCTAssertEqual(file.mode, 420)
        XCTAssertEqual(file.size, payload.count)
    }

    func testWriteFileEncodesContentAsBase64() throws {
        let payload = Data([0x00, 0x9F, 0x10, 0x44])
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/etc/x", "bytes_written": 4, "mode": 420, "created": true,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let result = try client.writeFile("/etc/x", data: payload, mode: 0o644)
        XCTAssertEqual(result, WriteResult(path: "/etc/x", bytesWritten: 4,
                                           mode: 420, created: true))

        let req = server.requests[0]
        let b64 = try XCTUnwrap(req["content"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64), payload, "content must round-trip byte-exact")
        XCTAssertEqual(req["mode"] as? Int, 420, "0o644 == 420 decimal on the wire")
    }

    func testWriteFileOmitsModeWhenNil() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/etc/x", "bytes_written": 1, "mode": 420, "created": false,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        _ = try client.writeFile("/etc/x", data: Data([0x41]))
        XCTAssertNil(server.requests[0]["mode"], "nil mode preserves the file's existing mode")
    }

    // MARK: stat -- optional symlink target

    func testStatSymlinkCarriesTarget() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/usr/lib/x", "type": "symlink", "size": 8, "mode": 511,
                "uid": 0, "gid": 0, "mtime": 1000, "target": "../real",
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let s = try client.stat("/usr/lib/x")
        XCTAssertEqual(s.type, "symlink")
        XCTAssertEqual(s.target, "../real")
    }

    func testStatRegularFileHasNilTarget() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/etc/passwd", "type": "file", "size": 1234, "mode": 420,
                "uid": 0, "gid": 3, "mtime": 999,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertNil(try client.stat("/etc/passwd").target)
    }

    // MARK: list_dir / search -- nested arrays

    func testListDirParsesEntries() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "path": "/etc", "count": 2, "entries": [
                    ["name": "hosts", "type": "file", "size": 80, "mode": 420, "mtime": 1],
                    ["name": "rc.d", "type": "dir", "size": 512, "mode": 493, "mtime": 2],
                ],
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let list = try client.listDir("/etc")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.entries.map(\.name), ["hosts", "rc.d"])
        XCTAssertEqual(list.entries[1].type, "dir")
    }

    func testSearchParsesMatchesAndTruncation() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": true, "result": [
                "pattern": "TODO", "path": "src", "count": 1, "truncated": true,
                "exit_code": 0, "timed_out": false,
                "matches": [["file": "a.c", "line": 12, "text": "// TODO"]],
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let r = try client.search("TODO", path: "src", ignoreCase: true, max: 1)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.matches, [SearchMatch(file: "a.c", line: 12, text: "// TODO")])
        XCTAssertEqual(server.requests[0]["ignore_case"] as? Bool, true)
        XCTAssertEqual(server.requests[0]["max"] as? Int, 1)
    }

    // MARK: streaming get_file / put_file

    func testGetFileStreamsBodyToDiskByteExact() throws {
        // Bytes a JSON string can't carry: NUL + high bytes. Stream path is raw,
        // so it must round-trip exactly.
        let payload = Data([0x00, 0x01, 0xFF, 0x41, 0x42, 0x0A, 0x80, 0x00, 0x7F])
        let server = try MockHeliosServer { req, id in
            XCTAssertEqual(req["verb"] as? String, "get_file")
            return ["id": id, "ok": true, "result": [
                "path": "/src/blob", "bytes": payload.count, "mode": 420,
            ]]
        }
        server.downloadBody = payload
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("helios-get-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        let header = try client.getFile("/src/blob", toLocalURL: dest)
        XCTAssertEqual(header, GetResult(path: "/src/blob", bytes: payload.count, mode: 420))
        XCTAssertEqual(try Data(contentsOf: dest), payload, "downloaded bytes must be byte-exact")
    }

    func testGetFileForwardsUserAndPermissionErrorThrows() throws {
        let server = try MockHeliosServer { req, id in
            XCTAssertEqual(req["user"] as? String, "alice")
            return ["id": id, "ok": false, "error": "get_file: Permission denied: /root/secret"]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("helios-get-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertThrowsError(try client.getFile("/root/secret", toLocalURL: dest, user: "alice")) { error in
            guard case .protocolError = (error as? HeliosClient.HeliosError) else {
                return XCTFail("expected .protocolError, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "no local file should be created when the daemon refuses")
    }

    func testPutFileStreamsBodyFromDiskAndForwardsUser() throws {
        let payload = Data([0x00, 0x9F, 0x10, 0x44, 0xFF, 0x00, 0x41])
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("helios-put-\(UUID().uuidString).bin")
        try payload.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let server = try MockHeliosServer { req, id in
            XCTAssertEqual(req["verb"] as? String, "put_file")
            return ["id": id, "ok": true, "result": [
                "path": "/home/alice/blob", "bytes_written": payload.count,
                "mode": 420, "created": true,
            ]]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        let result = try client.putFile(fromLocalURL: src, toRemotePath: "/home/alice/blob",
                                        mode: 0o644, user: "alice")
        XCTAssertEqual(result, WriteResult(path: "/home/alice/blob", bytesWritten: payload.count,
                                           mode: 420, created: true))
        XCTAssertEqual(server.uploadedBody, payload, "uploaded bytes must be byte-exact")

        let req = server.requests[0]
        XCTAssertEqual(req["bytes"] as? Int, payload.count)
        XCTAssertEqual(req["mode"] as? Int, 420)
        XCTAssertEqual(req["user"] as? String, "alice")
    }

    // MARK: user passthrough on the line verbs

    func testFileVerbsForwardUserAndOmitWhenNil() throws {
        let server = try MockHeliosServer { req, id in
            switch req["verb"] as? String {
            case "list_dir":
                return ["id": id, "ok": true, "result": ["path": "/h", "count": 0, "entries": []]]
            case "stat":
                return ["id": id, "ok": true, "result": [
                    "path": "/h", "type": "dir", "size": 0, "mode": 493,
                    "uid": 1, "gid": 1, "mtime": 0]]
            default:
                return ["id": id, "ok": false, "error": "unexpected"]
            }
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        _ = try client.listDir("/h", user: "bob")
        _ = try client.stat("/h")   // nil user

        XCTAssertEqual(server.requests[0]["user"] as? String, "bob", "user must reach the wire")
        XCTAssertNil(server.requests[1]["user"], "nil user must be omitted")
    }

    // MARK: persistence -- many requests on one connection

    func testMultipleCallsOnOnePersistentConnection() throws {
        let server = try MockHeliosServer { req, id in
            switch req["verb"] as? String {
            case "hello":
                return ["id": id, "ok": true, "result": [
                    "agent": "heliosAgent", "version": "0.1.0", "protocol": 1,
                    "host": "h", "uptime": 1]]
            case "stat":
                return ["id": id, "ok": true, "result": [
                    "path": "/x", "type": "file", "size": 0, "mode": 420,
                    "uid": 0, "gid": 0, "mtime": 0]]
            default:
                return ["id": id, "ok": false, "error": "unexpected"]
            }
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertEqual(try client.hello().host, "h")
        XCTAssertEqual(try client.stat("/x").type, "file")
        XCTAssertEqual(server.requests.count, 2)
    }

    // MARK: error paths

    func testDaemonErrorBecomesProtocolError() throws {
        let server = try MockHeliosServer { _, id in
            ["id": id, "ok": false, "error": "no such file"]
        }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertThrowsError(try client.readFile("/nope")) { error in
            XCTAssertEqual(error as? HeliosClient.HeliosError, .protocolError("no such file"))
        }
    }

    func testConnectionClosedMidRequestThrows() throws {
        // Empty response dict is the mock's signal to drop the connection.
        let server = try MockHeliosServer { _, _ in [:] }
        defer { server.stop() }
        server.start()

        let client = HeliosClient(host: "127.0.0.1", port: server.port, timeout: 5)
        try client.connect()
        defer { client.close() }

        XCTAssertThrowsError(try client.hello()) { error in
            XCTAssertEqual(error as? HeliosClient.HeliosError, .connectionClosed)
        }
    }

    func testCallWithoutConnectThrowsNotConnected() {
        let client = HeliosClient(host: "127.0.0.1", port: 2125, timeout: 1)
        XCTAssertThrowsError(try client.hello()) { error in
            XCTAssertEqual(error as? HeliosClient.HeliosError, .notConnected)
        }
    }

    func testConnectToClosedPortFails() throws {
        // Grab a port, then close it so nothing is listening -> connect refused.
        let probe = try MockHeliosServer { _, id in ["id": id, "ok": true, "result": [:]] }
        let deadPort = probe.port
        probe.stop()

        let client = HeliosClient(host: "127.0.0.1", port: deadPort, timeout: 2)
        XCTAssertThrowsError(try client.connect()) { error in
            guard case .connectionFailed = (error as? HeliosClient.HeliosError) else {
                return XCTFail("expected .connectionFailed, got \(error)")
            }
        }
    }
}

// MARK: - shutdown helper that doesn't expect the connection to drop

private extension HeliosClient {
    /// `shutdown()` semantically precedes the guest going down; in these tests
    /// the mock stays up, so this is just a plain shutdown call we can issue
    /// twice to check id sequencing.
    func shutdownNoDrop() throws -> ShutdownResult { try shutdown() }
}

// MARK: - In-process mock daemon

/// A minimal one-connection TCP server speaking the Helios newline-JSON
/// protocol. `@unchecked Sendable`: it serves on its own queue and guards its
/// request log with a lock, so it can be handed to that queue safely.
final class MockHeliosServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "mock-helios-server")
    private let lock = NSLock()
    private var _requests: [[String: Any]] = []
    private var clientFD: Int32 = -1
    /// Maps (request object, echoed id) -> the full response object to send.
    /// Returning an empty dictionary drops the connection (EOF) instead.
    private let responder: ([String: Any], Int) -> [String: Any]

    /// Streaming support. `downloadBody` (set before `start()`) is the raw body
    /// the mock writes after a `get_file` response header. `uploadedBody` is the
    /// raw body the mock consumed after a `put_file` header, for assertions.
    var downloadBody: Data?
    private var _uploadedBody = Data()
    var uploadedBody: Data {
        lock.lock(); defer { lock.unlock() }
        return _uploadedBody
    }

    init(responder: @escaping ([String: Any], Int) -> [String: Any]) throws {
        self.responder = responder

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        _ = inet_aton("127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func start() {
        queue.async { [self] in serve() }
    }

    func stop() {
        if clientFD >= 0 { Darwin.close(clientFD) }
        Darwin.close(listenFD)
    }

    private func serve() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        clientFD = cfd

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)

        // Pull exactly `count` raw bytes: leftover line buffer first, then the
        // socket. nil if the peer closes early. Used for a put_file body.
        func readExact(_ count: Int) -> Data? {
            var out = Data()
            if !buffer.isEmpty {
                let take = min(count, buffer.count)
                out.append(contentsOf: buffer[..<take])
                buffer.removeSubrange(..<take)
            }
            while out.count < count {
                let n = chunk.withUnsafeMutableBufferPointer {
                    Darwin.read(cfd, $0.baseAddress, Swift.min($0.count, count - out.count))
                }
                if n <= 0 { return nil }
                out.append(contentsOf: chunk[0..<n])
            }
            return out
        }

        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any] else {
                    continue
                }
                lock.lock(); _requests.append(obj); lock.unlock()
                let id = obj["id"] as? Int ?? 0
                let verb = obj["verb"] as? String

                // put_file: the raw body follows the header on the wire. Consume
                // it before answering (the client writes header+body, then reads).
                if verb == "put_file", let bytes = obj["bytes"] as? Int {
                    if let body = readExact(bytes) {
                        lock.lock(); _uploadedBody = body; lock.unlock()
                    }
                }

                let response = responder(obj, id)
                if response.isEmpty {
                    Darwin.close(cfd)
                    return
                }
                var data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
                data.append(0x0A)
                _ = data.withUnsafeBytes { Darwin.write(cfd, $0.baseAddress, data.count) }

                // get_file: the raw body follows our header response. Send it now.
                if verb == "get_file", let body = downloadBody {
                    _ = body.withUnsafeBytes { Darwin.write(cfd, $0.baseAddress, body.count) }
                }
                continue
            }
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(cfd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        Darwin.close(cfd)
    }
}
