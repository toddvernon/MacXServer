import XCTest
import Foundation
import Framer
@testable import SwiftXCaptureCore

// SessionCapture is the per-session sink wrapper the server uses.
// It owns the in-progress-then-rename file lifecycle on top of Recorder.

final class SessionCaptureTests: XCTestCase {

    // MARK: - File lifecycle

    func testCreatesDirectoryOnInit() throws {
        let dir = uniqueTempDirPath()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        let _ = try SessionCapture(sessionId: 1, directory: dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testFinalizeWithoutRenameUsesUnidentifiedFallback() throws {
        // A session that disconnects before sending WM_CLASS (e.g.,
        // xclock bailing on an unimplemented opcode) should still
        // produce a visible .xtap, NOT one hidden behind a dot prefix.
        // finalize() renames to <timestamp>-unidentified-<id>.xtap.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 42, directory: dir)
        cap.record(direction: .clientToServer, bytes: [0xAA, 0xBB])
        try cap.finalize()

        // The .in-progress path must NOT be the final resting place.
        let inProgress = (dir as NSString).appendingPathComponent(".in-progress-42.xtap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgress))

        // The fallback name should be the only .xtap in the directory.
        let landed = try files(in: dir)
        XCTAssertEqual(landed.count, 1)
        XCTAssertTrue(landed[0].hasSuffix("-unidentified-42.xtap"),
                      "expected unidentified-42 fallback, got: \(landed[0])")
        XCTAssertFalse(landed[0].hasPrefix("."))

        let path = (dir as NSString).appendingPathComponent(landed[0])
        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].bytes, [0xAA, 0xBB])
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testRenameSwitchesOutputPath() throws {
        // After rename(toClientName:), finalize() must land at the new
        // path, NOT at the in-progress path.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 7, directory: dir)
        cap.record(direction: .clientToServer, bytes: [0x01])
        cap.rename(toClientName: "xterm")
        cap.record(direction: .serverToClient, bytes: [0x02, 0x03])
        try cap.finalize()

        // In-progress file should not exist.
        let inProgress = (dir as NSString).appendingPathComponent(".in-progress-7.xtap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgress))

        // Some `*-xterm.xtap` should — exact timestamp varies per run.
        let renamed = try files(in: dir).filter { $0.hasSuffix("-xterm.xtap") }
        XCTAssertEqual(renamed.count, 1)

        let path = (dir as NSString).appendingPathComponent(renamed[0])
        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].bytes, [0x01])
        XCTAssertEqual(frames[1].bytes, [0x02, 0x03])
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testRenameIsIdempotent() throws {
        // First identify signal wins. A later WM_NAME mustn't override
        // the WM_CLASS that already named the file.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 1, directory: dir)
        cap.rename(toClientName: "xterm")
        cap.rename(toClientName: "should-be-ignored")
        try cap.finalize()

        let captured = try files(in: dir)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].hasSuffix("-xterm.xtap"))
        XCTAssertFalse(captured[0].contains("ignored"))
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testRenameWithEmptySanitizedNameFallsThroughToUnidentified() throws {
        // Garbage-only client names sanitize to empty; SessionCapture
        // refuses to rename to `<timestamp>-.xtap`. The session stays
        // unrenamed, so finalize() applies the unidentified fallback
        // — a visible filename, not the hidden in-progress one.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 9, directory: dir)
        cap.rename(toClientName: "///")    // sanitize → "_"  trimmed → ""
        try cap.finalize()

        let landed = try files(in: dir)
        XCTAssertEqual(landed.count, 1)
        XCTAssertTrue(landed[0].hasSuffix("-unidentified-9.xtap"),
                      "expected unidentified-9 fallback, got: \(landed[0])")
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - decodeToText

    func testDecodeToTextWritesSiblingTxt() throws {
        // With decodeToText on, finalize() writes a decoded chrono .txt next
        // to the .xtap (same basename), and the .xtap is still authoritative.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 5, directory: dir, decodeToText: true)
        cap.record(direction: .clientToServer, bytes: SetupRequest(byteOrder: .lsbFirst).encode())
        cap.rename(toClientName: "xeyes")
        try cap.finalize()

        let all = try FileManager.default.contentsOfDirectory(atPath: dir)
        let xtaps = all.filter { $0.hasSuffix(".xtap") }
        let txts  = all.filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(xtaps.count, 1)
        XCTAssertEqual(txts.count, 1, "decodeToText should write one sibling .txt")
        XCTAssertEqual((xtaps[0] as NSString).deletingPathExtension,
                       (txts[0] as NSString).deletingPathExtension,
                       ".txt should share the .xtap's basename")
        let content = try String(contentsOfFile: (dir as NSString).appendingPathComponent(txts[0]), encoding: .utf8)
        XCTAssertFalse(content.isEmpty, "decoded log should not be empty")
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testDecodeToTextOffWritesNoTxt() throws {
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 6, directory: dir)   // default: off
        cap.record(direction: .clientToServer, bytes: SetupRequest(byteOrder: .lsbFirst).encode())
        try cap.finalize()
        let txts = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") }
        XCTAssertTrue(txts.isEmpty, "decodeToText off must not write a .txt")
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - sanitize()

    func testSanitizeAllowsAlphanumericUnderscoreDotHyphen() {
        XCTAssertEqual(SessionCapture.sanitize("xterm"), "xterm")
        XCTAssertEqual(SessionCapture.sanitize("xeyes-2"), "xeyes-2")
        XCTAssertEqual(SessionCapture.sanitize("foo.bar_baz"), "foo.bar_baz")
        XCTAssertEqual(SessionCapture.sanitize("Quickplot"), "Quickplot")
    }

    func testSanitizeReplacesDisallowedWithUnderscore() {
        XCTAssertEqual(SessionCapture.sanitize("foo bar"), "foo_bar")
        XCTAssertEqual(SessionCapture.sanitize("xterm/bash"), "xterm_bash")
        XCTAssertEqual(SessionCapture.sanitize("a:b"), "a_b")
    }

    func testSanitizeTrimsLeadingTrailingUnderscores() {
        // Trimming keeps filenames tidy when the original had a space
        // prefix/suffix that would otherwise become _xterm_.
        XCTAssertEqual(SessionCapture.sanitize(" xterm "), "xterm")
        XCTAssertEqual(SessionCapture.sanitize("/foo/"), "foo")
    }

    func testSanitizeEmptyAndAllJunk() {
        XCTAssertEqual(SessionCapture.sanitize(""), "")
        XCTAssertEqual(SessionCapture.sanitize("///"), "")
        XCTAssertEqual(SessionCapture.sanitize("   "), "")
    }

    // MARK: - timestampString

    func testTimestampShape() {
        // YYYY-MM-DDTHH-MM-SS — filename-legal (no colons).
        let s = SessionCapture.timestampString(now: Date(timeIntervalSince1970: 1716480000))
        XCTAssertEqual(s.count, 19)
        XCTAssertTrue(s.contains("T"))
        XCTAssertFalse(s.contains(":"))
        // Three hyphen-separated date components + three hyphen-separated
        // time components = at least 4 hyphens.
        XCTAssertGreaterThanOrEqual(s.filter { $0 == "-" }.count, 4)
    }

    // MARK: - Helpers

    private func uniqueTempDirPath() -> String {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("session-capture-\(UUID().uuidString)")
            .path
    }

    private func files(in dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".xtap") }
            .sorted()
    }
}
