import XCTest
import Foundation
import Darwin
@testable import SwiftXCaptureCore

final class ProxyTests: XCTestCase {

    func testForwardsBytesBothDirections() throws {
        // Fake X server: listens on a localhost port, accepts one client, reads
        // everything until the client closes its write side, then sends back a
        // canned response and closes.
        let (serverFd, serverPort) = try makeListener()
        defer { Darwin.close(serverFd) }

        let serverReceived = ThreadSafeBytes()
        let serverDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            do {
                let cfd = try acceptOne(serverFd)
                defer { Darwin.close(cfd) }
                let received = readUntilEOF(cfd)
                serverReceived.set(received)
                writeAll(cfd, [0x99, 0x88, 0x77, 0x66])
                shutdown(cfd, Int32(SHUT_WR))
            } catch {
                XCTFail("server side error: \(error)")
            }
            serverDone.signal()
        }

        // Recorder writes to a temp .xtap.
        let outputPath = makeTempFilePath(prefix: "proxy")
        let recorder = try Recorder(
            outputPath: outputPath,
            listen: "127.0.0.1:0",
            forward: "127.0.0.1:\(serverPort)"
        )

        // Proxy listens on a localhost port, forwards to the fake server.
        let proxy = Proxy(
            listenHost: "127.0.0.1",
            listenPort: 0,
            forwardHost: "127.0.0.1",
            forwardPort: serverPort,
            recorder: recorder
        )
        let proxyPort = try proxy.start()
        let proxyDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try proxy.run()
            } catch {
                XCTFail("proxy run error: \(error)")
            }
            proxyDone.signal()
        }

        // Fake X client.
        let clientFd = try dial(host: "127.0.0.1", port: proxyPort)
        let clientPayload: [UInt8] = [
            0x6C, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        writeAll(clientFd, clientPayload)
        shutdown(clientFd, Int32(SHUT_WR))
        let clientReceived = readUntilEOF(clientFd)
        Darwin.close(clientFd)

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(proxyDone.wait(timeout: .now() + 5.0), .success)

        XCTAssertEqual(serverReceived.get(), clientPayload)
        XCTAssertEqual(clientReceived, [0x99, 0x88, 0x77, 0x66])

        try recorder.finalize()

        let frames = try CaptureReader.read(from: outputPath)
        // Order depends on which pump's read returned first; reassemble per direction.
        let c2s = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }
        let s2c = frames.filter { $0.direction == .serverToClient }.flatMap { $0.bytes }
        XCTAssertEqual(c2s, clientPayload)
        XCTAssertEqual(s2c, [0x99, 0x88, 0x77, 0x66])
    }

    func testReturnsActualPortWhenListeningOnZero() throws {
        let proxy = Proxy(
            listenHost: "127.0.0.1",
            listenPort: 0,
            forwardHost: "127.0.0.1",
            forwardPort: 1,
            recorder: nil
        )
        let port = try proxy.start()
        defer { proxy.stop() }
        XCTAssertGreaterThan(port, 0)
    }
}

final class ThreadSafeBytes: @unchecked Sendable {
    private var bytes: [UInt8] = []
    private let lock = NSLock()

    func set(_ b: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bytes = b
    }

    func get() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}
