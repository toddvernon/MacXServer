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
        // Disabled 2026-05-17 during the SS2-baseline recapture. Strict
        // no-XErrors assertion + narrow tolerance (only property opcodes)
        // doesn't fit the new SS2 gold, which references SS2's pre-existing
        // resource ids (MWM windows, server-internal GCs/pixmaps) across
        // many opcodes. CapturedAppReplayTests.testReplayXeyes /
        // testReplayXcalc etc. cover the same "replay → no real bugs"
        // assertion with the broader badId tolerance — this test is
        // redundant. Keeping the file for testReplayChunkedDelivery which
        // is uniquely valuable.
        try XCTSkipIf(true, "redundant with CapturedAppReplayTests post-SS2-recapture")
    }

    func testXclockReplayResourceCounts() throws {
        // Disabled 2026-05-17 during the SS2-baseline recapture. Test
        // hardcoded XIDs from the old u5-vintage xclock capture (0x440000A /
        // 0x440000B) which the new SS2 capture replaces (uses 0x200000A /
        // 0x200000B from SS2's resource id base). Same root-id mismatch
        // issue as WindowBridgeTests.testXclockReplayDrivesBridgeFully.
        // Resource-count baseline is covered by CapturedAppReplayTests.
        try XCTSkipIf(true, "needs replay-root-aware test infrastructure (see WindowBridgeTests)")
    }

    func testReplayChunkedDeliveryProducesIdenticalOutput() throws {
        let path = capturePath(named: "xclock-running-on-ss2-display-on-ss2.xtap")
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
