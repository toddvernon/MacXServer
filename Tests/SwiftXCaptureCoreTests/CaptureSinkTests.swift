import XCTest
import Foundation
@testable import SwiftXCaptureCore

// Locks in the protocol contract for CaptureSink. The existing
// Recorder satisfies it (covered by RecorderTests and ProxyTests);
// this file adds a mock-based contract test so the protocol's shape
// stays a stable extension point for the server-side capture work
// (step 2 of the capture v2 plan in PRODUCT_1_CAPTURE.md).

final class CaptureSinkTests: XCTestCase {

    func testRecorderConformsToCaptureSink() throws {
        // Compile-time conformance check: assignment to the protocol
        // type must succeed. The cast also exercises the Sendable
        // requirement of the protocol.
        let path = makeTempFilePath(prefix: "sink-conformance")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        let sink: CaptureSink = recorder
        sink.record(direction: .clientToServer, bytes: [0x6c])
        try sink.finalize()

        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].direction, .clientToServer)
        XCTAssertEqual(frames[0].bytes, [0x6c])
    }

    func testMockSinkReceivesRecordCalls() throws {
        // A test-only mock sink — exercised here so future contributors
        // see the pattern for plugging a non-Recorder sink in (the
        // server will do the same).
        let mock = CountingSink()
        mock.record(direction: .clientToServer, bytes: [0x01, 0x02, 0x03])
        mock.record(direction: .serverToClient, bytes: [0xff])
        mock.record(direction: .clientToServer, bytes: [0x04])
        try mock.finalize()

        XCTAssertEqual(mock.calls.count, 3)
        XCTAssertEqual(mock.calls[0].direction, .clientToServer)
        XCTAssertEqual(mock.calls[0].bytes, [0x01, 0x02, 0x03])
        XCTAssertEqual(mock.calls[1].direction, .serverToClient)
        XCTAssertEqual(mock.calls[2].bytes, [0x04])
        XCTAssertTrue(mock.finalized)
    }
}

// Small thread-safe sink for the contract test above. Mirrors the
// concurrency model the real Recorder uses (lock-protected mutation).
final class CountingSink: CaptureSink, @unchecked Sendable {
    struct Call: Equatable {
        let direction: Direction
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private(set) var finalized = false

    func record(direction: Direction, bytes: [UInt8]) {
        lock.lock()
        calls.append(Call(direction: direction, bytes: bytes))
        lock.unlock()
    }

    func finalize() throws {
        lock.lock()
        finalized = true
        lock.unlock()
    }
}
