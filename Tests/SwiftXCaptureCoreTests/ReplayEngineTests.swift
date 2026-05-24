import XCTest
import Foundation
import Darwin
@testable import SwiftXCaptureCore

// End-to-end tests for the GUI's ReplayEngine. Each test stands up
// a fake target X server on an ephemeral port, builds a tiny
// .xtap on disk via Recorder, runs the engine against the fake
// server, and asserts on the byte stream + progress callbacks.

final class ReplayEngineTests: XCTestCase {

    func testEngineDeliversC2SBytesToTarget() throws {
        // Build a .xtap with two C2S frames and one S2C frame. The
        // S2C frame must NOT be sent on replay — only client-to-
        // server traffic goes out.
        let xtapPath = makeTempFilePath(prefix: "replay-c2s")
        let recorder = try Recorder(outputPath: xtapPath, listen: ":1", forward: "h:2")
        recorder.record(direction: .clientToServer, bytes: [0xAA, 0xBB, 0xCC])
        recorder.record(direction: .serverToClient, bytes: [0xFF, 0xFE])
        recorder.record(direction: .clientToServer, bytes: [0xDD])
        try recorder.finalize()

        // Start a fake server: accept one connection, drain bytes.
        let server = try FakeServer.start()
        defer { server.stop() }

        let frames = try CaptureReader.read(from: xtapPath)
        let completion = expectation(description: "engine completes")
        let finalProgress = Holder<ReplayEngine.Progress?>(nil)
        let completionKind = Holder<String>("")

        let engine = ReplayEngine(
            frames: frames,
            targetHost: "127.0.0.1",
            targetPort: server.port,
            realtime: false,
            hold: false,
            onProgress: { _ in /* covered by other tests */ },
            onComplete: { outcome in
                switch outcome {
                case .finished(let p):
                    finalProgress.set(p)
                    completionKind.set("finished")
                case .cancelled(let p):
                    finalProgress.set(p)
                    completionKind.set("cancelled")
                case .failed(let msg, _):
                    completionKind.set("failed: \(msg)")
                }
                completion.fulfill()
            }
        )
        engine.start()
        wait(for: [completion], timeout: 5.0)

        XCTAssertEqual(completionKind.value, "finished")
        XCTAssertEqual(finalProgress.value?.framesSent, 2)
        XCTAssertEqual(finalProgress.value?.totalFrames, 2)
        XCTAssertEqual(finalProgress.value?.bytesSent, 4)         // 3 + 1

        // Server should have received the C2S bytes in order, S2C
        // bytes excluded.
        XCTAssertEqual(server.received(), [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testProgressCallbackFiresPerFrame() throws {
        let xtapPath = makeTempFilePath(prefix: "replay-progress")
        let recorder = try Recorder(outputPath: xtapPath, listen: ":1", forward: "h:2")
        for _ in 0..<5 {
            recorder.record(direction: .clientToServer, bytes: [0x01, 0x02, 0x03, 0x04])
        }
        try recorder.finalize()

        let server = try FakeServer.start()
        defer { server.stop() }

        let frames = try CaptureReader.read(from: xtapPath)
        let completion = expectation(description: "engine completes")
        let framesSentValues = Holder<[Int]>([])

        let engine = ReplayEngine(
            frames: frames,
            targetHost: "127.0.0.1",
            targetPort: server.port,
            realtime: false,
            hold: false,
            onProgress: { p in
                framesSentValues.mutate { $0.append(p.framesSent) }
            },
            onComplete: { _ in completion.fulfill() }
        )
        engine.start()
        wait(for: [completion], timeout: 5.0)

        let snapshot = framesSentValues.value
        // Expect 0 (initial), 1, 2, 3, 4, 5 to all appear. Drain
        // thread may interleave additional callbacks with the same
        // framesSent value when bytesReceived changes; the
        // monotonicity check is what matters.
        XCTAssertTrue(snapshot.contains(0))
        XCTAssertTrue(snapshot.contains(5))
        XCTAssertEqual(snapshot.last, 5)
        // Monotonically non-decreasing.
        for i in 1..<snapshot.count {
            XCTAssertGreaterThanOrEqual(snapshot[i], snapshot[i - 1])
        }
    }

    func testStopCancelsHoldOpenSession() throws {
        // hold=true means the engine waits indefinitely after the
        // last frame. stop() must wake it and report cancelled
        // (not finished). Without stop the test would hang.
        let xtapPath = makeTempFilePath(prefix: "replay-hold")
        let recorder = try Recorder(outputPath: xtapPath, listen: ":1", forward: "h:2")
        recorder.record(direction: .clientToServer, bytes: [0xAA])
        try recorder.finalize()

        let server = try FakeServer.start()
        defer { server.stop() }

        let frames = try CaptureReader.read(from: xtapPath)
        let completion = expectation(description: "engine completes")
        let completionKind = Holder<String>("")

        let engine = ReplayEngine(
            frames: frames,
            targetHost: "127.0.0.1",
            targetPort: server.port,
            realtime: false,
            hold: true,
            onProgress: { _ in },
            onComplete: { outcome in
                switch outcome {
                case .finished: completionKind.set("finished")
                case .cancelled: completionKind.set("cancelled")
                case .failed(let msg, _): completionKind.set("failed: \(msg)")
                }
                completion.fulfill()
            }
        )
        engine.start()

        // Give the engine ~200 ms to finish sending then enter the
        // hold wait. Stop should wake it.
        Thread.sleep(forTimeInterval: 0.2)
        engine.stop()

        wait(for: [completion], timeout: 5.0)
        XCTAssertEqual(completionKind.value, "cancelled")
    }

    func testFailedConnectionReportedAsFailed() throws {
        // Build a real .xtap and aim at a port nothing is listening
        // on. The dial should fail and the engine should fire
        // onComplete with .failed.
        let xtapPath = makeTempFilePath(prefix: "replay-noconnect")
        let recorder = try Recorder(outputPath: xtapPath, listen: ":1", forward: "h:2")
        recorder.record(direction: .clientToServer, bytes: [0xAA])
        try recorder.finalize()

        let frames = try CaptureReader.read(from: xtapPath)
        let completion = expectation(description: "engine completes")
        let completionKind = Holder<String>("")

        // Pick a port that's almost certainly unbound. Loopback,
        // privileged range (need root to bind there) — the OS will
        // refuse the connect.
        let engine = ReplayEngine(
            frames: frames,
            targetHost: "127.0.0.1",
            targetPort: 1,                 // commonly unbound on macOS
            realtime: false,
            hold: false,
            onProgress: { _ in },
            onComplete: { outcome in
                switch outcome {
                case .finished:        completionKind.set("finished")
                case .cancelled:       completionKind.set("cancelled")
                case .failed:          completionKind.set("failed")
                }
                completion.fulfill()
            }
        )
        engine.start()
        wait(for: [completion], timeout: 5.0)
        XCTAssertEqual(completionKind.value, "failed")
    }
}

// Small lock-guarded container so test bodies can capture mutable
// state from @Sendable completion closures without tripping
// strict-concurrency diagnostics.
final class Holder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ initial: T) { self.v = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ newValue: T) { lock.lock(); v = newValue; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

// MARK: - In-process fake X server

/// Minimal TCP server for ReplayEngine tests: listens on an
/// ephemeral port, accepts ONE connection, drains C2S bytes into a
/// lock-guarded buffer until the client half-closes. Used by the
/// engine tests as the "target" of a replay.
final class FakeServer: @unchecked Sendable {
    let port: UInt16
    private let listenFd: Int32
    private let lock = NSLock()
    private var receivedBytes: [UInt8] = []
    private let acceptGroup = DispatchGroup()

    private init(listenFd: Int32, port: UInt16) {
        self.listenFd = listenFd
        self.port = port
    }

    static func start() throws -> FakeServer {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeServerError.socketCreate }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian  // 127.0.0.1

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw FakeServerError.bind }
        guard Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); throw FakeServerError.listen }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)

        let server = FakeServer(listenFd: fd, port: port)

        server.acceptGroup.enter()
        DispatchQueue.global().async {
            defer { server.acceptGroup.leave() }
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFd = Darwin.accept(fd, &clientAddr, &clientLen)
            guard clientFd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(clientFd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                server.lock.lock()
                server.receivedBytes.append(contentsOf: buf[0..<n])
                server.lock.unlock()
            }
            Darwin.close(clientFd)
        }

        return server
    }

    func received() -> [UInt8] {
        acceptGroup.wait()
        lock.lock(); defer { lock.unlock() }
        return receivedBytes
    }

    func stop() {
        Darwin.close(listenFd)
    }
}

enum FakeServerError: Error {
    case socketCreate
    case bind
    case listen
}
