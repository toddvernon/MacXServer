import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore
@testable import SwiftXCaptureCore

// Locks the number of Expose events the server emits during replay of
// each captured app. The "before" snapshot for Region Step E1 — once the
// first-map Expose path consults clipList instead of emitting one
// per-window-rect, these counts will drop (most dramatically for the
// dt-Motif apps with their 451 → 7 territory). The E1 commit updates
// these numbers in the same change so the behavioral diff lives at the
// test layer.
//
// Baselines captured 2026-05-13 against ServerSession at f34f064 (Step
// B landed, Step E not yet). Per-app numbers logged via print so a
// fresh run can re-baseline easily if the counts drift for unrelated
// reasons.

final class ExposeCountBaselineTests: XCTestCase {

    // Baselines after Step E1. The "before" column captures the Step B
    // state when Expose was still emitted as one event per full window
    // rect (and per-mapped-descendant on map). E1 enumerates each
    // window's clipList rect-list in window-local coords — fully-covered
    // descendants emit zero Expose events; partially-covered ones emit
    // one Expose per visible rect instead of one covering the obscured
    // areas too. Net: big drops for dt-Motif (deep widget trees with
    // lots of full coverage); small drops or net-neutral elsewhere.
    //
    // Before / after:
    //   xclock          1 →   1
    //   xterm_session   1 →   1
    //   xeyes-sun       0 →   0
    //   xcalc          47 →  47
    //   xfontsel-sun    4 →   2
    //   dthelpview      4 →   5  (one window's clipList has 2 rects now)
    //   dtterm-sun     15 →  10
    //   quickplot-sun  85 →  55
    //   dticon-sun     62 →  53
    //   dtcalc-sun    248 → 144  (the headline number)
    //
    // Gold Sun X server emits ~7 for dtcalc boot, so we're still over by
    // 20×. The remaining gap closes as more region-aware behavior lands:
    // E2 (resize Expose uses clipList delta), E1.5 (descendant-move
    // repaint), Step D (stacking-aware sibling clipping).

    func testXclockExposeCount() throws {
        try assertExposeCount(capture: "xclock.xtap", expected: 1)
    }

    func testXcalcExposeCount() throws {
        try assertExposeCount(capture: "xcalc.xtap", expected: 47)
    }

    func testXtermExposeCount() throws {
        try assertExposeCount(capture: "xterm_session.xtap", expected: 1)
    }

    func testXfontselExposeCount() throws {
        try assertExposeCount(capture: "xfontsel-sun.xtap", expected: 2)
    }

    func testXeyesExposeCount() throws {
        try assertExposeCount(capture: "xeyes-sun.xtap", expected: 0)
    }

    func testQuickplotExposeCount() throws {
        try assertExposeCount(capture: "quickplot-sun.xtap", expected: 55)
    }

    func testDtcalcExposeCount() throws {
        try assertExposeCount(capture: "dtcalc-sun.xtap", expected: 144)
    }

    func testDttermExposeCount() throws {
        try assertExposeCount(capture: "dtterm-sun.xtap", expected: 10)
    }

    func testDthelpviewExposeCount() throws {
        try assertExposeCount(capture: "dthelpview-sun.xtap", expected: 5)
    }

    func testDticonExposeCount() throws {
        try assertExposeCount(capture: "dticon-sun.xtap", expected: 53)
    }

    // MARK: - Harness

    private func assertExposeCount(
        capture filename: String,
        expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let path = capturePath(named: filename)
        let frames = try CaptureReader.read(from: path)
        let c2s = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }
        XCTAssertFalse(c2s.isEmpty, "\(filename): no C2S bytes", file: file, line: line)

        let session = ServerSession()
        let output = session.feed(c2s)

        guard let byteOrder = session.byteOrder else {
            XCTFail("\(filename): session never reached running phase", file: file, line: line)
            return
        }

        // Skip the SetupAccepted reply.
        let setup = try SetupReply.decode(from: output, byteOrder: byteOrder)
        guard case .accepted(let accepted) = setup else {
            XCTFail("\(filename): first reply is not SetupAccepted", file: file, line: line)
            return
        }
        var offset = accepted.encode(byteOrder: byteOrder).count

        // Walk the remaining output counting Expose events (code 12).
        var exposeCount = 0
        while offset < output.count {
            let remaining = Array(output[offset...])
            let msg = try ServerMessage.decodeOne(from: remaining, byteOrder: byteOrder)
            if case .event(let ev) = msg, ev.code == 12 {
                exposeCount += 1
            }
            offset += msg.bytes.count
        }

        print("[\(filename)] Expose events emitted: \(exposeCount)")
        XCTAssertEqual(exposeCount, expected,
                       "\(filename): Expose count drift (expected \(expected), saw \(exposeCount))",
                       file: file, line: line)
    }

    private func capturePath(named filename: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
            .appendingPathComponent(filename)
            .path
    }
}
