import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore
@testable import SwiftXCaptureCore

// Drives the M1 server core with the captured C2S byte stream from xclock on
// u5. The point of this test is to assert "M1 done" semantically:
//
//   * SetupAccepted is sent.
//   * Every captured client request decodes and dispatches.
//   * Every emitted server-to-client message is a Reply (no XError).
//   * Resource state at end matches the trace's expected counts.
//
// The reason this works as a test (where it didn't for testing the framer):
// the framer's correctness is grounded in its own round-trip; the *server*
// is the new thing under test. By replaying captured C2S bytes into it and
// inspecting the response and end-state, we get a substantive correctness
// check that doesn't need a Sun on the LAN to run.
final class XclockReplayTests: XCTestCase {

    func testReplayingXclockCaptureProducesNoXErrors() throws {
        let path = capturePath(named: "xclock.xtap")
        let frames = try CaptureReader.read(from: path)
        let c2s = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }
        XCTAssertFalse(c2s.isEmpty)

        let session = ServerSession()
        let allOutput = session.feed(c2s)
        XCTAssertTrue(session.setupAcceptedSent, "SetupAccepted should have been emitted")

        let byteOrder = try XCTUnwrap(session.byteOrder, "session should be in running phase")

        // Slice the output: the SetupAccepted reply, then a sequence of
        // 32-byte-or-larger Replies.
        let setupReply = try SetupReply.decode(from: allOutput, byteOrder: byteOrder)
        guard case .accepted(let accepted) = setupReply else {
            XCTFail("first message should be SetupAccepted, got \(setupReply)")
            return
        }
        let setupBytes = accepted.encode(byteOrder: byteOrder)

        var offset = setupBytes.count
        var replyCount = 0
        var eventCount = 0
        var errorCount = 0
        while offset < allOutput.count {
            let remaining = Array(allOutput[offset...])
            let msg = try ServerMessage.decodeOne(from: remaining, byteOrder: byteOrder)
            switch msg {
            case .reply: replyCount += 1
            case .event: eventCount += 1
            case .xError(let err):
                errorCount += 1
                XCTFail("server emitted XError code=\(err.errorCode) majorOp=\(err.majorOpcode) seq=\(err.sequenceNumber(byteOrder: byteOrder))")
            }
            offset += msg.bytes.count
        }
        XCTAssertEqual(errorCount, 0, "must not emit XErrors during xclock replay")
        XCTAssertGreaterThan(replyCount, 0, "expected some replies (InternAtom, AllocColor, etc.)")
        // Events expected: M2 map sequence (Reparent, Configure, Map, plus
        // descendant MapNotify on inner) + M3 Expose on inner from each
        // ConfigureWindow size change in the captured resize bursts.
        XCTAssertGreaterThan(eventCount, 0, "expected map / expose events")
        XCTAssertEqual(offset, allOutput.count, "output should parse cleanly with no trailing bytes")
    }

    func testXclockReplayResourceCounts() throws {
        let path = capturePath(named: "xclock.xtap")
        let frames = try CaptureReader.read(from: path)
        let c2s = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }

        let session = ServerSession()
        _ = session.feed(c2s)

        // From captures/xclock_transcript.md:
        //   - 2 windows created (parent at 0x440000A, child at 0x440000B)
        //   - 2 colors allocated (gray and black)
        //   - 4 drawing GCs created (cid=0x4400006..0x4400009) plus the initial
        //     one at cid=0x4400000, plus 2 stipple GCs that get freed before the
        //     window dies (so their net contribution to the table is 0).
        //   - 2 pixmaps created (icon + mask)
        //   - 1 font opened
        //   - At least 4 atoms interned (WM_CONFIGURE_DENIED, WM_MOVED,
        //     WM_DELETE_WINDOW, WM_PROTOCOLS) on top of the 68 predefined.

        XCTAssertEqual(session.windows.count, 2)
        XCTAssertGreaterThanOrEqual(session.colors.count, 4) // 2 + the 2 pre-seeded (black, white)
        XCTAssertEqual(session.pixmaps.count, 2)
        XCTAssertEqual(session.fonts.count, 1)
        XCTAssertGreaterThanOrEqual(session.atoms.count, 68 + 4)
        XCTAssertGreaterThan(session.gcs.count, 0)

        // Outer window (0x440000A) should still exist and have child.
        XCTAssertNotNil(session.windows.get(0x440000A))
        let child = session.windows.get(0x440000B)
        XCTAssertNotNil(child)
        XCTAssertEqual(child?.parent, 0x440000A)

        // The MapWindow request was issued for the outer window — it should be marked mapped.
        XCTAssertEqual(session.windows.get(0x440000A)?.mapped, true)

        // No unknown opcodes should have shown up in the xclock trace.
        XCTAssertTrue(session.unknownOpcodes.isEmpty, "unexpected unknown opcodes: \(session.unknownOpcodes)")
    }

    func testReplayChunkedDeliveryProducesIdenticalOutput() throws {
        let path = capturePath(named: "xclock.xtap")
        let frames = try CaptureReader.read(from: path)
        let c2s = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }

        // Feed in one big chunk.
        let oneShot = ServerSession()
        let oneShotOutput = oneShot.feed(c2s)

        // Feed byte-by-byte (the worst case for the buffering logic).
        let drip = ServerSession()
        var dripOutput: [UInt8] = []
        for byte in c2s {
            dripOutput.append(contentsOf: drip.feed([byte]))
        }

        XCTAssertEqual(oneShotOutput, dripOutput, "output must be identical regardless of chunk boundaries")
        XCTAssertEqual(oneShot.requestsProcessed, drip.requestsProcessed)
        XCTAssertEqual(oneShot.windows.count, drip.windows.count)
    }

    // MARK: - Helpers

    private func capturePath(named filename: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
            .appendingPathComponent(filename)
            .path
    }
}
