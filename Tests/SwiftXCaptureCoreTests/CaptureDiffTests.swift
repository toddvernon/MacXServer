import XCTest
import Foundation
import Framer
@testable import SwiftXCaptureCore

final class CaptureDiffTests: XCTestCase {

    // MARK: - Helpers

    private func capturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
    }

    private func goldDtcalc() throws -> String {
        let path = capturesDirectory().appendingPathComponent("dtcalc-sun.xtap").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("captures/dtcalc-sun.xtap not present")
        }
        return path
    }

    private func swiftxDtcalc() throws -> String {
        let path = capturesDirectory().appendingPathComponent("dtcalc-swiftx.xtap").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("captures/dtcalc-swiftx.xtap not present")
        }
        return path
    }

    // Write a prefix of an existing .xtap (header + first k frames) to a temp
    // path. Walks the .xtap framing manually because CaptureReader doesn't
    // expose per-frame byte offsets.
    private func writeTruncatedCapture(_ srcPath: String, keepFrames k: Int) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: srcPath))
        let bytes = Array(data)
        var offset = CaptureFile.headerSize
        for _ in 0..<k {
            guard offset + CaptureFile.frameHeaderSize <= bytes.count else { break }
            let len = Int(UInt32(bytes[offset + 9])
                | (UInt32(bytes[offset + 10]) << 8)
                | (UInt32(bytes[offset + 11]) << 16)
                | (UInt32(bytes[offset + 12]) << 24))
            offset += CaptureFile.frameHeaderSize + len
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-diff-test-\(UUID().uuidString).xtap")
        try Data(bytes[0..<offset]).write(to: tmp)
        return tmp.path
    }

    // MARK: - Tests

    func testSelfDiffIsAllSame() throws {
        let path = try goldDtcalc()
        let report = try CaptureDiff.compare(pathA: path, pathB: path)

        XCTAssertGreaterThan(report.c2sCounts.total, 0)
        XCTAssertGreaterThan(report.s2cCounts.total, 0)
        XCTAssertEqual(report.c2sCounts.different, 0, "self-diff has \(report.c2sCounts.different) different C2S rows")
        XCTAssertEqual(report.c2sCounts.onlyA, 0)
        XCTAssertEqual(report.c2sCounts.onlyB, 0)
        XCTAssertEqual(report.c2sCounts.same, report.c2sCounts.total)
        XCTAssertEqual(report.s2cCounts.different, 0, "self-diff has \(report.s2cCounts.different) different S2C rows")
        XCTAssertEqual(report.s2cCounts.onlyA, 0)
        XCTAssertEqual(report.s2cCounts.onlyB, 0)
        XCTAssertEqual(report.s2cCounts.same, report.s2cCounts.total)
    }

    func testTruncatedBProducesOnlyARowsAtTail() throws {
        let full = try goldDtcalc()
        let truncated = try writeTruncatedCapture(full, keepFrames: 20)
        defer { try? FileManager.default.removeItem(atPath: truncated) }

        let report = try CaptureDiff.compare(pathA: full, pathB: truncated)

        // B is a strict prefix, so onlyA must be > 0 and onlyB == 0.
        XCTAssertGreaterThan(report.c2sCounts.onlyA + report.s2cCounts.onlyA, 0,
                             "expected truncated B to produce onlyA rows")
        XCTAssertEqual(report.c2sCounts.onlyB, 0)
        XCTAssertEqual(report.s2cCounts.onlyB, 0)

        // The non-trailing rows that appear in both should all be `same` —
        // they're the same bytes from the same source file.
        XCTAssertEqual(report.c2sCounts.different, 0)
        XCTAssertEqual(report.s2cCounts.different, 0)
    }

    func testCorpusGoldVsSwiftxProducesNonTrivialDiff() throws {
        let gold = try goldDtcalc()
        let swiftx = try swiftxDtcalc()

        let report = try CaptureDiff.compare(pathA: gold, pathB: swiftx)

        XCTAssertGreaterThan(report.c2sCounts.total, 100)
        XCTAssertGreaterThan(report.s2cCounts.total, 100)

        // These are real gold-vs-swiftx captures; they must differ at least
        // somewhere or the test target is broken.
        let totalDelta = report.c2sCounts.different + report.c2sCounts.onlyA + report.c2sCounts.onlyB
                       + report.s2cCounts.different + report.s2cCounts.onlyA + report.s2cCounts.onlyB
        XCTAssertGreaterThan(totalDelta, 0)

        // Render check: markdown surface area present.
        let md = CaptureDiff.render(report)
        XCTAssertTrue(md.contains("# capture diff"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## C2S"))
        XCTAssertTrue(md.contains("## S2C"))
    }

    func testRenderOnlyDifferentSuppressesSameRows() throws {
        let path = try goldDtcalc()
        let report = try CaptureDiff.compare(pathA: path, pathB: path)

        let withSame = CaptureDiff.render(report, options: DiffRenderOptions(onlyDifferent: false))
        let withoutSame = CaptureDiff.render(report, options: DiffRenderOptions(onlyDifferent: true))

        // `| same | <line> | = |` is the per-row marker for matching rows.
        // The summary table also has `| same |` in its header, so match the
        // trailing `| = |` to specifically detect same-status diff rows.
        XCTAssertTrue(withSame.contains("| same |") && withSame.contains("| = |"))
        XCTAssertFalse(withoutSame.contains("| = |"))
        XCTAssertTrue(withoutSame.contains("_(no rows)_"))
    }

    func testRenderEscapesPipesInMessageLines() {
        // Synthesize a report by hand; defends against a line containing "|"
        // breaking the markdown table.
        let rows = [DiffRow(direction: .clientToServer, ordinal: 0,
                            aLine: "request foo|bar", bLine: "request foo|baz",
                            status: .different)]
        let report = DiffReport(pathA: "a", pathB: "b", c2sRows: rows, s2cRows: [])
        let md = CaptureDiff.render(report)
        XCTAssertTrue(md.contains("foo\\|bar"))
        XCTAssertTrue(md.contains("foo\\|baz"))
    }
}
