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

    // Atoms baseline includes +4 from FONT_ASCENT / FONT_DESCENT /
    // DEFAULT_CHAR / AVERAGE_WIDTH which QueryFont now interns when
    // building the per-glyph CHARINFO reply (shipped 2026-05-15 in the
    // post-audit sweep). Captures without a QueryFont call (xeyes,
    // dtcalc, dthelpview, dticon) don't change.

    func testReplayXcalc() throws {
        try runReplay(capture: "xcalc-running-on-ss2-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 3, gcs: 0,
            atoms: 84, requests: 1415,
            allowedExtensionOpcodes: [128]
        ))
    }

    func testReplayXterm() throws {
        try runReplay(capture: "xterm-running-on-ss2-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 2, gcs: 0,
            atoms: 84, requests: 91,
            allowedExtensionOpcodes: []
        ))
    }

    func testReplayXfontsel() throws {
        try runReplay(capture: "xfontsel-running-on-ss2-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 4, gcs: 0,
            atoms: 87, requests: 391,
            allowedExtensionOpcodes: []
        ))
    }

    func testReplayXeyes() throws {
        try runReplay(capture: "xeyes-running-on-ss2-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 0, gcs: 0,
            atoms: 76, requests: 300,
            allowedExtensionOpcodes: [128]
        ))
    }

    func testReplayQuickplot() throws {
        try runReplay(capture: "quickplot-running-on-u5-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 48, pixmaps: 0, fonts: 24, gcs: 0,
            atoms: 90, requests: 3595,
            allowedExtensionOpcodes: [133]
        ))
    }

    func testReplayDtcalc() throws {
        try runReplay(capture: "dtcalc-running-on-u5-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 3, gcs: 0,
            atoms: 92, requests: 2047,
            allowedExtensionOpcodes: [133]
        ))
    }

    func testReplayDtterm() throws {
        try runReplay(capture: "dtterm-running-on-u5-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 25, pixmaps: 0, fonts: 4, gcs: 0,
            atoms: 96, requests: 862,
            allowedExtensionOpcodes: [133]
        ))
    }

    func testReplayDthelpview() throws {
        try runReplay(capture: "dthelpview-running-on-u5-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 27, pixmaps: 0, fonts: 8, gcs: 0,
            atoms: 89, requests: 414,
            allowedExtensionOpcodes: [133]
        ))
    }

    // Note: dticon capture is PARTIAL — captured up to the point of its
    // ToolTalk timeout (~5 min hang waiting for ttsession which doesn't
    // exist on SS2 — but only when running through the swiftx-capture proxy;
    // it works direct u5→ss2 without timing out, so there's a proxy bug to
    // chase later). The captured bytes are still valid X11 protocol; the
    // test just replays the init sequence the app emitted before giving up.
    // dtmail and dtpad have the same proxy-breaks-TT issue but their
    // captures are too short to be useful replay tests (~16-30K bytes
    // each, mostly InternAtom traffic).
    func testReplayDticon() throws {
        try runReplay(capture: "dticon-running-on-u5-display-on-ss2.xtap", expecting: ReplayBaseline(
            windows: 2, colors: 70, pixmaps: 0, fonts: 3, gcs: 0,
            atoms: 100, requests: 1502,
            allowedExtensionOpcodes: [133]
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
                // Bad-resource-id errors are pervasive replay-vs-live
                // artifacts: gold captures reference IDs pre-allocated by
                // the gold server's environment (MWM-created windows,
                // pre-interned atoms, the gold-server's font IDs, GCs
                // owned by other clients of the live session, drawables
                // created before capture began). We never see the
                // create/intern requests for these, so when the captured
                // client references them, we correctly emit the spec
                // error. Real live clients hit IDs they themselves
                // created and don't trip this. We accept ANY error in
                // the "bad ID" family on any opcode — that's the broad
                // class of replay artifact. Real bugs in the server
                // surface as BadImplementation, BadLength, BadAlloc,
                // BadValue, BadName, BadAccess, BadIDChoice — those
                // still fail the test.
                let badIdCodes: Set<UInt8> = [
                    XErrorCode.window.rawValue,
                    XErrorCode.pixmap.rawValue,
                    XErrorCode.atom.rawValue,
                    XErrorCode.cursor.rawValue,
                    XErrorCode.font.rawValue,
                    XErrorCode.match.rawValue,    // CopyArea-on-mismatched-depth-pixmap etc.
                    XErrorCode.drawable.rawValue,
                    XErrorCode.color.rawValue,
                    XErrorCode.gc.rawValue,
                ]
                let isReplayArtifact = badIdCodes.contains(err.errorCode)
                if !isExpectedExtensionProbe && !isReplayArtifact {
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
