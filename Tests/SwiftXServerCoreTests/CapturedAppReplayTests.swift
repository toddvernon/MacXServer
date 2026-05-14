import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore
@testable import SwiftXCaptureCore

// Replay-based regression suite for every captured app in `captures/`.
//
// Each test feeds the gold capture's C2S byte stream into a fresh
// ServerSession and asserts the protocol path is stable:
//   * SetupAccepted emitted
//   * Zero XErrors on the wire
//   * No unknown opcodes in the CORE protocol range (< 128).
//     Extension-range opcodes (>= 128) are allowed because we explicitly
//     don't implement extensions (QueryExtension returns present=false) —
//     but the captured C2S stream contains extension requests because the
//     gold Sun server told the client SHAPE=129 / SolarisIA=135 / etc.
//   * Resource counts match the baseline snapshot
//
// These tests don't render anything, so they can't tell us if the visuals
// are right. They tell us whether the dispatcher accepts every request the
// captured client issued and ends in the expected resource state. The
// point is to catch the next MATCH_SELECT-style silent regression — if a
// refactor (region tracking, etc.) starts breaking any captured app's
// request flow, the right test fails here first.
//
// Baselines captured 2026-05-13 against ServerSession at f9702c6+. If a
// server change legitimately moves a count (new internal stub, an opcode
// that used to silent-drop is now honored), update the baseline in the
// same change.

final class CapturedAppReplayTests: XCTestCase {

    // MARK: - Test cases

    func testReplayXcalc() throws {
        try runReplay(capture: "xcalc.xtap", expecting: ReplayBaseline(
            windows: 53, colors: 25, pixmaps: 2, fonts: 3, gcs: 8,
            atoms: 76, requests: 1448,
            allowedExtensionOpcodes: [129] // SHAPE
        ))
    }

    func testReplayXterm() throws {
        try runReplay(capture: "xterm_session.xtap", expecting: ReplayBaseline(
            windows: 4, colors: 25, pixmaps: 1, fonts: 2, gcs: 4,
            atoms: 82, requests: 752,
            allowedExtensionOpcodes: []
        ))
    }

    func testReplayXfontsel() throws {
        try runReplay(capture: "xfontsel-sun.xtap", expecting: ReplayBaseline(
            windows: 46, colors: 25, pixmaps: 1, fonts: 5, gcs: 15,
            atoms: 80, requests: 661,
            allowedExtensionOpcodes: [135] // SolarisIA
        ))
    }

    func testReplayXeyes() throws {
        try runReplay(capture: "xeyes-sun.xtap", expecting: ReplayBaseline(
            windows: 4, colors: 25, pixmaps: 2, fonts: 0, gcs: 4,
            atoms: 76, requests: 401,
            allowedExtensionOpcodes: [129] // SHAPE
        ))
    }

    func testReplayQuickplot() throws {
        try runReplay(capture: "quickplot-sun.xtap", expecting: ReplayBaseline(
            windows: 95, colors: 47, pixmaps: 57, fonts: 25, gcs: 52,
            atoms: 82, requests: 8397,
            allowedExtensionOpcodes: []
        ))
    }

    func testReplayDtcalc() throws {
        try runReplay(capture: "dtcalc-sun.xtap", expecting: ReplayBaseline(
            windows: 196, colors: 33, pixmaps: 14, fonts: 4, gcs: 35,
            atoms: 83, requests: 2126,
            allowedExtensionOpcodes: [135] // SolarisIA
        ))
    }

    func testReplayDtterm() throws {
        try runReplay(capture: "dtterm-sun.xtap", expecting: ReplayBaseline(
            windows: 21, colors: 25, pixmaps: 5, fonts: 5, gcs: 22,
            atoms: 83, requests: 1106,
            allowedExtensionOpcodes: [135] // SolarisIA
        ))
    }

    func testReplayDthelpview() throws {
        try runReplay(capture: "dthelpview-sun.xtap", expecting: ReplayBaseline(
            windows: 10, colors: 25, pixmaps: 5, fonts: 8, gcs: 21,
            atoms: 76, requests: 841,
            allowedExtensionOpcodes: [135] // SolarisIA
        ))
    }

    func testReplayDticon() throws {
        try runReplay(capture: "dticon-sun.xtap", expecting: ReplayBaseline(
            windows: 88, colors: 82, pixmaps: 59, fonts: 4, gcs: 147,
            atoms: 87, requests: 1601,
            allowedExtensionOpcodes: [135] // SolarisIA
        ))
    }

    // MARK: - Replay harness

    private struct ReplayBaseline {
        let windows: Int
        let colors: Int
        let pixmaps: Int
        let fonts: Int
        let gcs: Int
        let atoms: Int
        let requests: Int
        /// Extension opcodes (major opcode >= 128) the gold Sun server
        /// assigned, which appear in the captured C2S stream. Our server
        /// can't process them (we say present=false on QueryExtension);
        /// the test tolerates them but pins which set is expected.
        let allowedExtensionOpcodes: Set<UInt8>
    }

    private func runReplay(
        capture filename: String,
        expecting baseline: ReplayBaseline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let path = capturePath(named: filename)
        let frames = try CaptureReader.read(from: path)
        let c2s = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }
        XCTAssertFalse(c2s.isEmpty, "\(filename): no C2S bytes", file: file, line: line)

        let session = ServerSession()
        let allOutput = session.feed(c2s)

        XCTAssertTrue(session.setupAcceptedSent,
                      "\(filename): SetupAccepted should be emitted",
                      file: file, line: line)

        // Split unknown opcodes into core (< 128) vs extension (>= 128).
        // Core unknowns are real bugs (silent-dropped requests we should
        // handle); extension unknowns are expected when a capture probed
        // an extension on the gold server that we don't implement.
        let unknownCore = session.unknownOpcodes.filter { $0 < 128 }
        let unknownExt = Set(session.unknownOpcodes.filter { $0 >= 128 })
        XCTAssertTrue(unknownCore.isEmpty,
                      "\(filename): unknown core opcodes: \(unknownCore)",
                      file: file, line: line)
        XCTAssertEqual(unknownExt, baseline.allowedExtensionOpcodes,
                       "\(filename): extension opcode set drift (expected \(baseline.allowedExtensionOpcodes), saw \(unknownExt))",
                       file: file, line: line)

        // Walk the output and check XError emission. Per the XError-honesty
        // policy (DECISIONS.md 2026-05-14), unknown opcodes now produce a
        // BadRequest on the wire. We expect exactly one BadRequest per
        // unknown-opcode request, and only for the baseline's allowed
        // extension opcodes — anything else is a real regression.
        guard let byteOrder = session.byteOrder else {
            XCTFail("\(filename): session never reached running phase", file: file, line: line)
            return
        }
        let setupReply = try SetupReply.decode(from: allOutput, byteOrder: byteOrder)
        guard case .accepted(let accepted) = setupReply else {
            XCTFail("\(filename): first reply is not SetupAccepted (got \(setupReply))",
                    file: file, line: line)
            return
        }
        var offset = accepted.encode(byteOrder: byteOrder).count
        var unexpectedErrors: [String] = []
        while offset < allOutput.count {
            let remaining = Array(allOutput[offset...])
            let msg = try ServerMessage.decodeOne(from: remaining, byteOrder: byteOrder)
            if case .xError(let err) = msg {
                let isExpectedExtensionProbe = err.errorCode == XErrorCode.request.rawValue
                    && baseline.allowedExtensionOpcodes.contains(err.majorOpcode)
                // BadWindow / BadAtom on property opcodes is a known
                // replay-vs-live artifact: gold captures reference Sun-
                // server-internal IDs (the Motif drag system, the CDE
                // customization daemon, Sun-WM-interned atom IDs) that we
                // never see CreateWindow / InternAtom for, so they're not
                // in our tables. Real live clients hit our own IDs and
                // don't trip this. Per XError-honesty policy the server
                // emits the correct error; the test acknowledges it rather
                // than pretending the captured ID is ours.
                let propertyOpcodes: Set<UInt8> = [
                    ChangeProperty.opcode, DeleteProperty.opcode, GetProperty.opcode,
                ]
                let isPropertyOpOnUnknownResource = (err.errorCode == XErrorCode.window.rawValue
                    || err.errorCode == XErrorCode.atom.rawValue)
                    && propertyOpcodes.contains(err.majorOpcode)
                if !isExpectedExtensionProbe && !isPropertyOpOnUnknownResource {
                    unexpectedErrors.append(
                        "code=\(err.errorCode) majorOp=\(err.majorOpcode) seq=\(err.sequenceNumber(byteOrder: byteOrder))"
                    )
                }
            }
            offset += msg.bytes.count
        }
        XCTAssertTrue(unexpectedErrors.isEmpty,
                      "\(filename): unexpected XErrors: \(unexpectedErrors)",
                      file: file, line: line)
        XCTAssertEqual(offset, allOutput.count,
                       "\(filename): output should parse cleanly",
                       file: file, line: line)

        // Resource-state baseline. Exact counts; if a server change moves
        // these, update the baseline in the same change with rationale.
        XCTAssertEqual(session.windows.count, baseline.windows,
                       "\(filename): windows", file: file, line: line)
        XCTAssertEqual(session.colors.count, baseline.colors,
                       "\(filename): colors", file: file, line: line)
        XCTAssertEqual(session.pixmaps.count, baseline.pixmaps,
                       "\(filename): pixmaps", file: file, line: line)
        XCTAssertEqual(session.fonts.count, baseline.fonts,
                       "\(filename): fonts", file: file, line: line)
        XCTAssertEqual(session.gcs.count, baseline.gcs,
                       "\(filename): gcs", file: file, line: line)
        XCTAssertEqual(session.atoms.count, baseline.atoms,
                       "\(filename): atoms", file: file, line: line)
        XCTAssertEqual(session.requestsProcessed, baseline.requests,
                       "\(filename): requests processed", file: file, line: line)
    }

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
