import XCTest
import Foundation
import Darwin
import Framer
import SwiftXCaptureCore
@testable import SwiftXServerCore

// End-to-end integration test for server-side capture. Boots a real
// Listener on an ephemeral port with a SessionCapture sink installed,
// drives a synthetic X client through a real TCP socket, verifies
// the resulting .xtap lands on disk and round-trips through the
// framer.
//
// This is the cross-cutting test from PRODUCT_1_CAPTURE.md § v2
// step 4 — it covers the byte-tee wiring in Listener.runConnection
// that the SessionCaptureTests can't reach (they exercise the sink
// in isolation, not via the network path).

final class CaptureIntegrationTests: XCTestCase {

    func testServerCaptureWritesXtapWithBothDirections() throws {
        let captureDir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(atPath: captureDir) }

        // Listener bound on an ephemeral port. runOne blocks until the
        // client closes, so it runs on a background queue while the
        // test thread plays the client.
        let listener = Listener(host: "127.0.0.1", port: 0)
        let actualPort = try listener.bind()

        let capture = try SessionCapture(sessionId: 1, directory: captureDir)

        let listenerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try listener.runOne(captureSink: capture)
            } catch {
                XCTFail("listener.runOne error: \(error)")
            }
            listenerDone.signal()
        }

        // Synthetic client: dial, send a SetupRequest, half-close so
        // the server sees EOF and finalizes the capture, drain the
        // reply, full-close.
        let clientFd = try dial(host: "127.0.0.1", port: actualPort)
        defer { Darwin.close(clientFd) }
        let setupBytes = SetupRequest(byteOrder: .lsbFirst).encode()
        writeAll(clientFd, setupBytes)
        shutdown(clientFd, Int32(SHUT_WR))
        let reply = readUntilEOF(clientFd)

        XCTAssertEqual(listenerDone.wait(timeout: .now() + 5.0), .success,
                       "listener didn't finish in time")
        XCTAssertGreaterThan(reply.count, 0, "server should have replied with SetupAccepted bytes")

        // Verify the .xtap landed.
        let captureFile = try lonelyCaptureFile(in: captureDir)
        let frames = try CaptureReader.read(from: captureFile)
        XCTAssertGreaterThan(frames.count, 0, "capture must contain at least one frame")

        // Both directions captured.
        let c2sBytes = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }
        let s2cBytes = frames
            .filter { $0.direction == .serverToClient }
            .flatMap { $0.bytes }
        XCTAssertEqual(c2sBytes, Array(setupBytes),
                       "C2S frames must reconstruct the SetupRequest exactly")
        XCTAssertEqual(s2cBytes, reply,
                       "S2C frames must reconstruct the server's reply exactly")
    }

    func testCaptureRenamesOnIdentifyAndFinalizesOnDisconnect() throws {
        // Cover the in-progress-then-rename lifecycle through the real
        // Listener path. Pre-rename: file name is .in-progress-N.xtap.
        // We trigger the rename manually since a SetupRequest alone
        // doesn't populate WM_CLASS; the production hook is
        // session.onIdentified in main.swift's sessionDidStart.
        let captureDir = uniqueTempDir()
        defer { try? FileManager.default.removeItem(atPath: captureDir) }

        let listener = Listener(host: "127.0.0.1", port: 0)
        let actualPort = try listener.bind()

        let capture = try SessionCapture(sessionId: 7, directory: captureDir)
        capture.rename(toClientName: "synthetic-test-client")

        let listenerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? listener.runOne(captureSink: capture)
            listenerDone.signal()
        }

        let clientFd = try dial(host: "127.0.0.1", port: actualPort)
        writeAll(clientFd, SetupRequest(byteOrder: .lsbFirst).encode())
        shutdown(clientFd, Int32(SHUT_WR))
        _ = readUntilEOF(clientFd)
        Darwin.close(clientFd)

        XCTAssertEqual(listenerDone.wait(timeout: .now() + 5.0), .success)

        // The in-progress filename must NOT remain.
        let inProgress = (captureDir as NSString)
            .appendingPathComponent(".in-progress-7.xtap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgress))

        // A `<ts>-synthetic-test-client.xtap` must exist.
        let captures = try FileManager.default.contentsOfDirectory(atPath: captureDir)
            .filter { $0.hasSuffix("-synthetic-test-client.xtap") }
        XCTAssertEqual(captures.count, 1, "expected one renamed capture, got: \(captures)")
    }

    // MARK: - Helpers

    private func uniqueTempDir() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-integration-\(UUID().uuidString)")
            .path
    }

    private func lonelyCaptureFile(in dir: String) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".xtap") }
        XCTAssertEqual(names.count, 1,
                       "expected exactly one .xtap in \(dir), got: \(names)")
        return (dir as NSString).appendingPathComponent(names[0])
    }
}

// MARK: - TCP test helpers

private func dial(host: String, port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CaptureIntegrationError.socketCreateFailed }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    _ = inet_aton(host, &addr.sin_addr)
    let rc = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else {
        Darwin.close(fd)
        throw CaptureIntegrationError.dialFailed(errno: errno)
    }
    return fd
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var off = 0
    while off < bytes.count {
        let w = bytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress!.advanced(by: off), bytes.count - off)
        }
        if w <= 0 { return }
        off += w
    }
}

private func readUntilEOF(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { return out }
        out.append(contentsOf: buf[0..<n])
    }
}

private enum CaptureIntegrationError: Error {
    case socketCreateFailed
    case dialFailed(errno: Int32)
}
