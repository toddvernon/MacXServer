import XCTest
@testable import SwiftXCaptureCore
import Framer

// Resource registry behavior: create/free bookkeeping, leak counting,
// session-end summary line shape, and the use-after-free / lineage
// annotation flow through LandmarkDetector's errorLandmark path.

final class ResourceRegistryTests: XCTestCase {

    // MARK: - Bookkeeping

    func testCreateAndFreeBookkeeping() {
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .pixmap, atSeq: 5)
        r.registerCreate(0x200, kind: .pixmap, atSeq: 6)
        r.registerCreate(0x300, kind: .gc, atSeq: 7)
        r.registerFree(0x100, atSeq: 99)

        XCTAssertEqual(r.entry(0x100)?.kind, .pixmap)
        XCTAssertEqual(r.entry(0x100)?.createdAtSeq, 5)
        XCTAssertEqual(r.entry(0x100)?.freedAtSeq, 99)
        XCTAssertTrue(r.entry(0x100)?.isFreed ?? false)
        XCTAssertNil(r.entry(0x200)?.freedAtSeq)
        XCTAssertEqual(r.createdCount(.pixmap), 2)
        XCTAssertEqual(r.freedCount(.pixmap), 1)
        XCTAssertEqual(r.leakedCount(.pixmap), 1)
        XCTAssertEqual(r.createdCount(.gc), 1)
    }

    func testZeroIdIgnored() {
        var r = ResourceRegistry()
        r.registerCreate(0, kind: .window, atSeq: 1)
        XCTAssertNil(r.entry(0))
        XCTAssertEqual(r.createdCount(.window), 0)
    }

    func testFreeOfUnknownIdDoesNotIncrement() {
        var r = ResourceRegistry()
        r.registerFree(0xDEAD, atSeq: 50)
        XCTAssertEqual(r.freedCount(.pixmap), 0)
        XCTAssertEqual(r.freedCount(.gc), 0)
    }

    func testDoubleFreeOnlyCountedOnce() {
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .gc, atSeq: 5)
        r.registerFree(0x100, atSeq: 10)
        r.registerFree(0x100, atSeq: 11) // ignored
        XCTAssertEqual(r.freedCount(.gc), 1)
        XCTAssertEqual(r.entry(0x100)?.freedAtSeq, 10)
    }

    func testIdReuseOverwritesEntry() {
        // X11 lets clients re-use freed resource ids. The new creation wins.
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .pixmap, atSeq: 5)
        r.registerFree(0x100, atSeq: 10)
        r.registerCreate(0x100, kind: .pixmap, atSeq: 20)
        XCTAssertEqual(r.entry(0x100)?.createdAtSeq, 20)
        XCTAssertNil(r.entry(0x100)?.freedAtSeq)
        // Monotonic totals: 2 created, 1 freed across the session.
        XCTAssertEqual(r.createdCount(.pixmap), 2)
        XCTAssertEqual(r.freedCount(.pixmap), 1)
        XCTAssertEqual(r.leakedCount(.pixmap), 1)
    }

    // MARK: - Summary

    func testSummaryEmptyReturnsNil() {
        XCTAssertNil(ResourceRegistry().summaryLine())
    }

    func testSummaryHidesZeroCountKinds() {
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .gc, atSeq: 1)
        r.registerCreate(0x200, kind: .gc, atSeq: 2)
        r.registerFree(0x100, atSeq: 3)
        XCTAssertEqual(r.summaryLine(), "2 GCs (1 freed, 1 leaked)")
    }

    func testSummaryHonorsKindOrder() {
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .pixmap, atSeq: 1)
        r.registerCreate(0x200, kind: .window, atSeq: 2)
        r.registerCreate(0x300, kind: .gc, atSeq: 3)
        r.registerCreate(0x400, kind: .font, atSeq: 4)
        r.registerCreate(0x500, kind: .cursor, atSeq: 5)
        r.registerCreate(0x600, kind: .colormap, atSeq: 6)
        // window, pixmap, gc, font, cursor, colormap.
        XCTAssertEqual(r.summaryLine(),
                       "1 window (0 freed, 1 leaked), 1 pixmap (0 freed, 1 leaked), 1 GC (0 freed, 1 leaked), 1 font (0 freed, 1 leaked), 1 cursor (0 freed, 1 leaked), 1 colormap (0 freed, 1 leaked)")
    }

    func testSummaryHidesLeakedClauseWhenFullyFreed() {
        var r = ResourceRegistry()
        r.registerCreate(0x100, kind: .gc, atSeq: 1)
        r.registerFree(0x100, atSeq: 2)
        XCTAssertEqual(r.summaryLine(), "1 GC (1 freed)")
    }

    // MARK: - LandmarkDetector lineage annotation

    private func badGCError(seq: UInt16, id: UInt32) -> ServerMessage {
        // BadGC = code 13. Bad resource id sits at bytes 4..7. Build a
        // minimal 32-byte XError frame.
        var bytes: [UInt8] = [
            0,                              // type = Error
            13,                             // code = BadGC
            UInt8(seq >> 8), UInt8(seq & 0xFF),
            UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF),
            UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF),
            0, 0,                           // minor
            55,                             // major = CreateGC (arbitrary)
        ]
        bytes += Array(repeating: 0, count: 32 - bytes.count)
        return .xError(XError(bytes: bytes))
    }

    func testErrorLandmarkAnnotatesLineageForKnownLiveResource() {
        var registry = ResourceRegistry()
        registry.registerCreate(0x300, kind: .gc, atSeq: 42)
        var detector = LandmarkDetector()
        let landmarks = detector.afterServerMessage(badGCError(seq: 100, id: 0x300),
                                                    byteOrder: .msbFirst,
                                                    resources: registry)
        XCTAssertEqual(landmarks.count, 1)
        let text = landmarks[0].text
        XCTAssertTrue(text.contains("BadGC at seq=100"), text)
        XCTAssertTrue(text.contains("(created at seq=42)"), text)
        XCTAssertFalse(text.contains("freed"), text)
    }

    func testErrorLandmarkAnnotatesUseAfterFree() {
        var registry = ResourceRegistry()
        registry.registerCreate(0x300, kind: .gc, atSeq: 42)
        registry.registerFree(0x300, atSeq: 88)
        var detector = LandmarkDetector()
        let landmarks = detector.afterServerMessage(badGCError(seq: 100, id: 0x300),
                                                    byteOrder: .msbFirst,
                                                    resources: registry)
        let text = landmarks[0].text
        XCTAssertTrue(text.contains("BadGC at seq=100"), text)
        XCTAssertTrue(text.contains("(freed at seq=88, created at seq=42)"), text)
    }

    func testErrorLandmarkSilentForUnknownResource() {
        var detector = LandmarkDetector()
        // Empty registry — bad id is server-allocated or pre-capture.
        let landmarks = detector.afterServerMessage(badGCError(seq: 100, id: 0x999),
                                                    byteOrder: .msbFirst,
                                                    resources: ResourceRegistry())
        let text = landmarks[0].text
        // The existing resource phrase ("(bad resource 0x999)") still
        // renders, but no lineage annotation gets added.
        XCTAssertFalse(text.contains("created at"), text)
        XCTAssertFalse(text.contains("freed at"), text)
    }
}
