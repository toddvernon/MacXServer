import XCTest
import Foundation
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

    func testWritesToInProgressPathWhenNeverRenamed() throws {
        // A session that disconnects before identifying itself should
        // still produce a usable .xtap, just with the .in-progress
        // filename so a UI listing can flag it.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 42, directory: dir)
        cap.record(direction: .clientToServer, bytes: [0xAA, 0xBB])
        try cap.finalize()

        let expected = (dir as NSString).appendingPathComponent(".in-progress-42.xtap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))

        let frames = try CaptureReader.read(from: expected)
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

    func testRenameWithEmptySanitizedNameStaysAtInProgress() throws {
        // Garbage-only client names sanitize to empty; SessionCapture
        // refuses to rename rather than producing `-<timestamp>-.xtap`.
        let dir = uniqueTempDirPath()
        let cap = try SessionCapture(sessionId: 9, directory: dir)
        cap.rename(toClientName: "///")    // sanitize → "_"  trimmed → ""
        try cap.finalize()

        let expected = (dir as NSString).appendingPathComponent(".in-progress-9.xtap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
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
