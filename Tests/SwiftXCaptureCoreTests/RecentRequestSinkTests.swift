import XCTest
import Foundation
import Framer
@testable import SwiftXCaptureCore

// Covers the live-feed building blocks used by swiftx-capture-app's
// Record window: the streaming C2S opcode parser, and the tee sink
// that wraps a Recorder with byte counters + a recent-requests
// window.

final class RecentRequestSinkTests: XCTestCase {

    // MARK: - C2SOpcodeStream

    func testStreamParsesSetupThenRequests() {
        var stream = C2SOpcodeStream()
        // SetupRequest with empty auth name and data: 12 bytes total.
        var bytes: [UInt8] = [
            0x6c, 0x00,             // 'l' = LSB-first
            0x0B, 0x00,             // major 11
            0x00, 0x00,             // minor 0
            0x00, 0x00,             // auth-name length 0
            0x00, 0x00,             // auth-data length 0
            0x00, 0x00,             // unused
        ]
        // CreateWindow (op 1) length 8 4-byte units = 32 bytes payload.
        bytes.append(contentsOf: makeRequest(op: 1, lenIn4: 8))
        // MapWindow (op 8) length 2 4-byte units = 8 bytes payload.
        bytes.append(contentsOf: makeRequest(op: 8, lenIn4: 2))

        let names = stream.feed(bytes)
        XCTAssertEqual(names, ["CreateWindow", "MapWindow"])
    }

    func testStreamHandlesChunkedInput() {
        // Same data as above, fed one byte at a time. Parser must
        // assemble across calls and only emit names at packet
        // boundaries.
        var bytes: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        bytes.append(contentsOf: makeRequest(op: 16, lenIn4: 2))   // InternAtom

        var stream = C2SOpcodeStream()
        var collected: [String] = []
        for b in bytes {
            collected.append(contentsOf: stream.feed([b]))
        }
        XCTAssertEqual(collected, ["InternAtom"])
    }

    func testStreamHonorsByteOrderFromSetupRequest() {
        // MSB-first variant: setup byte 0 is 'B' (0x42); length
        // fields in subsequent requests are big-endian.
        var bytes: [UInt8] = [
            0x42, 0x00,             // 'B' = MSB-first
            0x00, 0x0B,             // major 11 (big-endian)
            0x00, 0x00,             // minor 0
            0x00, 0x00, 0x00, 0x00, // auth lengths
            0x00, 0x00,             // unused
        ]
        // PolyFillRectangle (op 70) lenIn4 = 3 (12 bytes total),
        // encoded BIG-ENDIAN at bytes 2-3.
        bytes.append(contentsOf: [70, 0, 0x00, 0x03, 0, 0, 0, 0, 0, 0, 0, 0])

        var stream = C2SOpcodeStream()
        XCTAssertEqual(stream.feed(bytes), ["PolyFillRectangle"])
    }

    func testStreamSkipsVariableLengthSetup() {
        // Auth-name "MIT-MAGIC-COOKIE-1" (18 bytes → padded to 20),
        // auth-data 16 bytes (padded to 16). Setup total = 12 + 20 + 16 = 48.
        let authName = Array("MIT-MAGIC-COOKIE-1".utf8)
        var bytes: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            UInt8(authName.count), 0x00,
            16, 0x00,
            0x00, 0x00,
        ]
        bytes.append(contentsOf: authName)
        bytes.append(contentsOf: [0, 0])                  // pad authName to 20
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 16))
        bytes.append(contentsOf: makeRequest(op: 8, lenIn4: 2))    // MapWindow

        var stream = C2SOpcodeStream()
        XCTAssertEqual(stream.feed(bytes), ["MapWindow"])
    }

    func testStreamHoldsAtPacketBoundaryWaitingForRest() {
        // Send setup + an op header but only half its body. No name
        // should emit until the body arrives.
        var setup: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        var stream = C2SOpcodeStream()
        _ = stream.feed(setup)

        // op=43 (GetInputFocus, ironically a no-arg request),
        // lenIn4=1 → 4-byte total → header IS the whole request.
        // For this test pick a longer one: op=15 QueryTree, lenIn4=2
        // → 8 bytes total. Feed first 4, expect nothing; then the
        // last 4, expect "QueryTree".
        let header: [UInt8] = [15, 0, 0x02, 0x00]
        XCTAssertEqual(stream.feed(header), [])
        let body: [UInt8] = [0, 0, 0, 0]
        XCTAssertEqual(stream.feed(body), ["QueryTree"])
    }

    func testStreamBailsOnExtendedLengthSentinel() {
        // BIG-REQUESTS: length=0 means "32-bit extended length next."
        // We don't ship the extension; the stream gives up rather
        // than desyncing. Names emitted before the giveup stay valid.
        var stream = C2SOpcodeStream()
        _ = stream.feed([
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        XCTAssertEqual(stream.feed(makeRequest(op: 8, lenIn4: 2)), ["MapWindow"])
        // Now a length=0 packet. Stream should bail; further feeds
        // emit nothing.
        XCTAssertEqual(stream.feed([99, 0, 0, 0]), [])
        XCTAssertEqual(stream.feed(makeRequest(op: 1, lenIn4: 8)), [])
    }

    func testStreamUnknownOpcodeFallsBackToOpNotation() {
        var stream = C2SOpcodeStream()
        _ = stream.feed([
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        // Opcode 200 isn't a real X11 core opcode; the stream should
        // still emit a placeholder name so the UI doesn't go silent.
        let result = stream.feed(makeRequest(op: 200, lenIn4: 1))
        XCTAssertEqual(result, ["op(200)"])
    }

    // MARK: - RecentRequestSink

    func testSinkForwardsRecordAndFinalize() throws {
        let path = makeTempFilePath(prefix: "tee-fwd")
        let recorder = try Recorder(outputPath: path, listen: ":1", forward: "h:2")
        let sink = RecentRequestSink(wrapping: recorder)

        sink.record(direction: .clientToServer, bytes: [0x6c, 0x00])
        sink.record(direction: .serverToClient, bytes: [0xAA, 0xBB, 0xCC])
        try sink.finalize()

        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].direction, .clientToServer)
        XCTAssertEqual(frames[1].direction, .serverToClient)
    }

    func testSinkCountsBytesPerDirection() throws {
        let path = makeTempFilePath(prefix: "tee-count")
        let recorder = try Recorder(outputPath: path, listen: ":1", forward: "h:2")
        let sink = RecentRequestSink(wrapping: recorder)

        sink.record(direction: .clientToServer, bytes: [UInt8](repeating: 0, count: 100))
        sink.record(direction: .serverToClient, bytes: [UInt8](repeating: 0, count: 250))
        sink.record(direction: .clientToServer, bytes: [UInt8](repeating: 0, count: 5))

        let snap = sink.snapshot()
        XCTAssertEqual(snap.bytesIn, 105)
        XCTAssertEqual(snap.bytesOut, 250)
        try sink.finalize()
    }

    func testSinkSurfacesRecentOpcodeNames() throws {
        let path = makeTempFilePath(prefix: "tee-recent")
        let recorder = try Recorder(outputPath: path, listen: ":1", forward: "h:2")
        let sink = RecentRequestSink(wrapping: recorder)

        var setup: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        setup.append(contentsOf: makeRequest(op: 1, lenIn4: 8))   // CreateWindow
        setup.append(contentsOf: makeRequest(op: 8, lenIn4: 2))   // MapWindow
        sink.record(direction: .clientToServer, bytes: setup)

        let snap = sink.snapshot()
        XCTAssertEqual(snap.recent, ["CreateWindow", "MapWindow"])
        try sink.finalize()
    }

    func testSinkCapsRecentRequestsList() throws {
        let path = makeTempFilePath(prefix: "tee-cap")
        let recorder = try Recorder(outputPath: path, listen: ":1", forward: "h:2")
        let sink = RecentRequestSink(wrapping: recorder, maxRecent: 4)

        var bytes: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        for _ in 0..<20 {
            bytes.append(contentsOf: makeRequest(op: 8, lenIn4: 2))   // MapWindow x 20
        }
        sink.record(direction: .clientToServer, bytes: bytes)

        let snap = sink.snapshot()
        XCTAssertEqual(snap.recent.count, 4, "max-recent cap should kick in")
        XCTAssertEqual(snap.recent, ["MapWindow", "MapWindow", "MapWindow", "MapWindow"])
        try sink.finalize()
    }

    // MARK: - Helpers

    /// Build a minimal X11 request header padded out to `lenIn4 * 4`
    /// bytes. Body is zeros; for the streaming parser only the
    /// opcode at byte 0 and length at bytes 2-3 matter.
    private func makeRequest(op: UInt8, lenIn4: UInt16) -> [UInt8] {
        var b: [UInt8] = [op, 0, UInt8(lenIn4 & 0xFF), UInt8(lenIn4 >> 8)]
        let pad = Int(lenIn4) * 4 - 4
        b.append(contentsOf: [UInt8](repeating: 0, count: pad))
        return b
    }
}
