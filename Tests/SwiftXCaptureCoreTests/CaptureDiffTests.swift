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
        let path = capturesDirectory().appendingPathComponent("dtcalc-running-on-u5-display-on-ss2.xtap").path
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

    func testLCSAlignsCommonPrefixAndSuffixAroundMiddleDivergence() {
        // Two synthetic line lists: identical except A has [X, Y] in the
        // middle where B has [Z]. LCS should match the prefix and suffix as
        // `same`, pair up X vs Z as a `different` row, and emit Y as `onlyA`.
        let common = ["L0", "L1", "L2", "L3", "L4"]
        let aLines = ["L0", "L1", "X", "Y", "L2", "L3", "L4"]
        let bLines = ["L0", "L1", "Z",      "L2", "L3", "L4"]
        _ = common

        let alignment = longestCommonSubsequence(a: aLines, b: bLines)

        // Sanity: matched pairs match
        for p in alignment {
            if let i = p.aIdx, let j = p.bIdx {
                XCTAssertEqual(aLines[i], bLines[j])
            }
        }
        // Five matched lines (the L0..L4 in both)
        let matched = alignment.filter { $0.aIdx != nil && $0.bIdx != nil }
        XCTAssertEqual(matched.count, 5)
        // One a-only (one of X/Y depending on LCS path)
        let onlyA = alignment.filter { $0.aIdx != nil && $0.bIdx == nil }
        let onlyB = alignment.filter { $0.aIdx == nil && $0.bIdx != nil }
        XCTAssertEqual(onlyA.count, 2)
        XCTAssertEqual(onlyB.count, 1)
    }

    func testSeqPrefixStrippedForAlignment() throws {
        // Same semantic request with different seq numbers (the post-divergence
        // case): should align as `same`, not be flagged as different.
        let a = [
            MessageEntry(direction: .clientToServer, timestamp: 0, line: "[seq=5   ] InternAtom \"WM_PROTOCOLS\""),
        ]
        let b = [
            MessageEntry(direction: .clientToServer, timestamp: 0, line: "[seq=3   ] InternAtom \"WM_PROTOCOLS\""),
        ]
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b)
        XCTAssertEqual(report.c2sCounts.same, 1)
        XCTAssertEqual(report.c2sCounts.different, 0)

        // But the displayed line should still carry the original seq prefix
        // so the user can find the right request in either capture.
        XCTAssertEqual(report.c2sRows.first?.aLine, "[seq=5   ] InternAtom \"WM_PROTOCOLS\"")
        XCTAssertEqual(report.c2sRows.first?.bLine, "[seq=3   ] InternAtom \"WM_PROTOCOLS\"")
    }

    func testStripSeqPrefixHandlesEdgeCases() {
        XCTAssertEqual(stripSeqPrefix("[seq=5   ] InternAtom \"WM_PROTOCOLS\""), "InternAtom \"WM_PROTOCOLS\"")
        XCTAssertEqual(stripSeqPrefix("[seq=12345] Reply (InternAtom) atom=0x1F"), "Reply (InternAtom) atom=0x1F")
        XCTAssertEqual(stripSeqPrefix("SetupRequest msbFirst proto=11.0"), "SetupRequest msbFirst proto=11.0")
        XCTAssertEqual(stripSeqPrefix("Expose window=0x4400001"), "Expose window=0x4400001")
    }

    // MARK: - Tolerance rules

    func testToleranceRulesNormalizeInternAtomReply() {
        let gold = "Reply (InternAtom)      atom=0x82 (WM_CONFIGURE_DENIED)"
        let swiftx = "Reply (InternAtom)      atom=0x1F (WM_CONFIGURE_DENIED)"
        XCTAssertEqual(applyToleranceRules(gold), applyToleranceRules(swiftx))
        // "None" atoms should also normalize identically.
        let goldNone = "Reply (InternAtom)      atom=None (SCREEN_RESOURCES)"
        let swiftxNone = "Reply (InternAtom)      atom=0x0 (SCREEN_RESOURCES)"
        // Both should be tolerance-equal (left already canonical "None",
        // right is hex zero — we want them to compare same).
        XCTAssertEqual(applyToleranceRules(goldNone), applyToleranceRules(swiftxNone))
    }

    func testToleranceRulesNormalizeQueryExtensionReply() {
        let gold = "Reply (QueryExtension)  name=SHAPE present=true major=128 firstEvent=64 firstError=0"
        let swiftx = "Reply (QueryExtension)  name=SHAPE present=true major=132 firstEvent=72 firstError=10"
        XCTAssertEqual(applyToleranceRules(gold), applyToleranceRules(swiftx))
    }

    func testToleranceRulesNormalizeAllocColorPixel() {
        let gold = "Reply (AllocColor)      → pixel=0x13 rgb=(65535,0,0)"
        let swiftx = "Reply (AllocColor)      → pixel=0x2A rgb=(65535,0,0)"
        XCTAssertEqual(applyToleranceRules(gold), applyToleranceRules(swiftx))
    }

    func testToleranceRulesNormalizeAllocNamedColorPixel() {
        let gold = "Reply (AllocNamedColor) → pixel=0x42 exact=(0,32896,32896)"
        let swiftx = "Reply (AllocNamedColor) → pixel=0xC1 exact=(0,32896,32896)"
        XCTAssertEqual(applyToleranceRules(gold), applyToleranceRules(swiftx))
    }

    func testToleranceRulesLeaveCanonicalContentAlone() {
        // Identity transform on lines that don't carry server-allocated IDs.
        let line = "CreateWindow            wid=0x4400001 parent=0x2B 500x600 at (0,0)"
        XCTAssertEqual(applyToleranceRules(line), line)
    }

    func testToleranceRulesAlignInternAtomRepliesAcrossDifferentServerAtomIDs() {
        // Same name, different server-allocated atom — must align as `same`,
        // not `different`. This is the bedrock gold-vs-swiftx use case.
        let a = [
            MessageEntry(direction: .serverToClient, timestamp: 0,
                         line: "[seq=4     ] Reply (InternAtom)      atom=0x82 (WM_CONFIGURE_DENIED)"),
        ]
        let b = [
            MessageEntry(direction: .serverToClient, timestamp: 0,
                         line: "[seq=4     ] Reply (InternAtom)      atom=0x1F (WM_CONFIGURE_DENIED)"),
        ]
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b)
        XCTAssertEqual(report.s2cCounts.same, 1)
        XCTAssertEqual(report.s2cCounts.different, 0)
        // Displayed line must keep the raw atom value so the user can read it.
        XCTAssertEqual(report.s2cRows.first?.aLine,
                       "[seq=4     ] Reply (InternAtom)      atom=0x82 (WM_CONFIGURE_DENIED)")
        XCTAssertEqual(report.s2cRows.first?.bLine,
                       "[seq=4     ] Reply (InternAtom)      atom=0x1F (WM_CONFIGURE_DENIED)")
    }

    // MARK: - Identifier normalization

    private func goldStyleMeta() -> StreamMetadata {
        StreamMetadata(
            resourceIdBase: 0x2800000, resourceIdMask: 0x1FFFFF,
            rootWindowIds: [0x2B], rootVisualIds: [0x23], defaultColormapIds: [0x21]
        )
    }

    private func swiftxStyleMeta() -> StreamMetadata {
        StreamMetadata(
            resourceIdBase: 0x5400000, resourceIdMask: 0x1FFFFF,
            rootWindowIds: [0x28], rootVisualIds: [0x25], defaultColormapIds: [0x22]
        )
    }

    func testNormalizeIdentifiersRewritesClientAllocatedIds() {
        let gold = "CreateGC                cid=0x2800009 drawable=0x2B mask=0x4 [fg=0x1]"
        let swiftx = "CreateGC                cid=0x5400009 drawable=0x28 mask=0x4 [fg=0x1]"
        XCTAssertEqual(
            normalizeIdentifiers(gold, metadata: goldStyleMeta()),
            normalizeIdentifiers(swiftx, metadata: swiftxStyleMeta())
        )
    }

    func testNormalizeIdentifiersHandlesRootWindowsAndColormaps() {
        let gold = "AllocNamedColor         cmap=0x21 name=\"Gray\""
        let swiftx = "AllocNamedColor         cmap=0x22 name=\"Gray\""
        let g = normalizeIdentifiers(gold, metadata: goldStyleMeta())
        let s = normalizeIdentifiers(swiftx, metadata: swiftxStyleMeta())
        XCTAssertEqual(g, s)
        XCTAssertTrue(g.contains("0xCMAP"))
    }

    func testNormalizeIdentifiersLeavesAtomIdsAloneOutsideClientRange() {
        // An atom value like 0x82 is server-allocated, outside the client range,
        // and not a root/colormap. Leave it alone here — the tolerance rules
        // above handle the InternAtom-reply line specifically.
        let line = "ChangeProperty          window=0x2800019 prop=WM_PROTOCOLS type=ATOM format=32 data=4b"
        let out = normalizeIdentifiers(line, metadata: goldStyleMeta())
        XCTAssertTrue(out.contains("0xC19"))      // client-allocated window
        XCTAssertFalse(out.contains("0x2800019")) // got rewritten
    }

    func testNormalizeIdentifiersIsIdentityForEmptyMetadata() {
        // Without setup-reply context (tests that drive `diff(...)` directly
        // and pass synthetic entries without metadata), normalization is a
        // no-op so existing test expectations still hold.
        let line = "CreateGC                cid=0x2800009 drawable=0x2B mask=0x4 [fg=0x1]"
        XCTAssertEqual(normalizeIdentifiers(line, metadata: .empty), line)
    }

    func testIdentifierNormalizationAlignsClientResourceIdsAcrossServers() {
        let metaA = goldStyleMeta()
        let metaB = swiftxStyleMeta()
        let a = [
            MessageEntry(direction: .clientToServer, timestamp: 0,
                         line: "[seq=1] CreateGC                cid=0x2800009 drawable=0x2B mask=0x4 [fg=0x1]"),
        ]
        let b = [
            MessageEntry(direction: .clientToServer, timestamp: 0,
                         line: "[seq=1] CreateGC                cid=0x5400009 drawable=0x28 mask=0x4 [fg=0x1]"),
        ]
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b, metaA: metaA, metaB: metaB)
        XCTAssertEqual(report.c2sCounts.same, 1)
        XCTAssertEqual(report.c2sCounts.different, 0)
    }

    func testToleranceRulesDontMaskRealAtomNameDifferences() {
        // Two replies with same value but different names: must NOT align as
        // same. The name in parens is what carries the canonical identity.
        let a = [
            MessageEntry(direction: .serverToClient, timestamp: 0,
                         line: "[seq=4] Reply (InternAtom)      atom=0x82 (WM_CONFIGURE_DENIED)"),
        ]
        let b = [
            MessageEntry(direction: .serverToClient, timestamp: 0,
                         line: "[seq=4] Reply (InternAtom)      atom=0x82 (WM_PROTOCOLS)"),
        ]
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b)
        XCTAssertEqual(report.s2cCounts.same, 0)
        XCTAssertEqual(report.s2cCounts.different, 1)
    }

    func testEmitRowsPairsUnmatchedRunsAsDifferent() throws {
        // Drive end-to-end: synthesize two MessageEntry arrays where the
        // middle differs by content but lengths match — should produce a
        // `different` row, not separate onlyA/onlyB.
        let a = ["setup", "r1", "X1", "X2", "r4"].map { MessageEntry(direction: .clientToServer, timestamp: 0, line: $0) }
        let b = ["setup", "r1", "Y1", "Y2", "r4"].map { MessageEntry(direction: .clientToServer, timestamp: 0, line: $0) }
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b)

        XCTAssertEqual(report.c2sCounts.same, 3)        // setup, r1, r4
        XCTAssertEqual(report.c2sCounts.different, 2)   // (X1,Y1) and (X2,Y2)
        XCTAssertEqual(report.c2sCounts.onlyA, 0)
        XCTAssertEqual(report.c2sCounts.onlyB, 0)
    }

    func testEmitRowsSpillsExcessAsOnly() throws {
        // A has 3 extra entries in the middle; B has 0. Should be 1
        // matched run on both sides plus 3 onlyA rows.
        let a = ["setup", "X1", "X2", "X3", "tail"].map { MessageEntry(direction: .clientToServer, timestamp: 0, line: $0) }
        let b = ["setup", "tail"].map { MessageEntry(direction: .clientToServer, timestamp: 0, line: $0) }
        let report = CaptureDiff.diff(pathA: "a", pathB: "b", a: a, b: b)

        XCTAssertEqual(report.c2sCounts.same, 2)      // setup, tail
        XCTAssertEqual(report.c2sCounts.different, 0)
        XCTAssertEqual(report.c2sCounts.onlyA, 3)
        XCTAssertEqual(report.c2sCounts.onlyB, 0)
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
