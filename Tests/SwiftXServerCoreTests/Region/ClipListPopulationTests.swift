import XCTest
@testable import SwiftXServerCore
@testable import SwiftXCaptureCore
import Framer

// Step B coverage: WindowEntry.clipList and .borderClip get populated
// correctly when ClipListEngine.recomputeClips runs over the tree.
// Pure WindowTable manipulation — no NSWindow, no dispatch, no
// rendering. The four scenarios named in WHAT_TO_DO_THIS_WEEK.md anchor
// the suite; additional cases probe multi-level descendants and the
// dispatch-handler wiring.

final class ClipListPopulationTests: XCTestCase {

    // MARK: - Helpers

    /// Create a window entry with sane defaults. Borders default to 0 so
    /// the tests can assert exact rects without doing border bookkeeping
    /// for every case; the border-aware behavior is covered separately.
    private func makeWindow(
        id: UInt32, parent: UInt32,
        x: Int16 = 0, y: Int16 = 0,
        width: UInt16, height: UInt16,
        borderWidth: UInt16 = 0,
        mapped: Bool = false
    ) -> WindowEntry {
        WindowEntry(
            id: id, parent: parent, depth: 8,
            x: x, y: y, width: width, height: height,
            borderWidth: borderWidth, windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: [],
            mapped: mapped
        )
    }

    /// Convenience: build a table with the given entries and immediately
    /// recompute. Returns the table so tests can read post-compute state.
    /// Entries must be in topological order (parent before child) so
    /// SiblingChain.linkAtTop can find each new window's parent. Mirrors
    /// what real CreateWindow dispatch does (insert + linkAtTop).
    private func recompute(_ entries: [WindowEntry], topLevel: UInt32) -> WindowTable {
        let table = WindowTable()
        for e in entries {
            table.insert(e)
            SiblingChain.linkAtTop(e.id, parent: e.parent, in: table)
        }
        ClipListEngine.recomputeClips(forTopLevel: topLevel, in: table)
        return table
    }

    private func box(_ x1: Int32, _ y1: Int32, _ x2: Int32, _ y2: Int32) -> BoxRec {
        BoxRec(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    // MARK: - Doc case 1: child subtracted from parent

    func testDocCase1_TopLevelWithMappedChild() {
        // A at top-level (0,0,100,100) — i.e. NSWindow content area.
        // B child of A at (10,10) sized 50x50.
        // After recompute:
        //   A.clipList = A's interior minus B's borderClip
        //                = 4-rect frame around B
        //   A.borderClip = A's interior (no border, no parent obscuring)
        //   B.clipList = B's interior (full rect)
        //   B.borderClip = same (border=0)
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 100, height: 100, mapped: true),
            makeWindow(id: bId, parent: aId, x: 10, y: 10, width: 50, height: 50, mapped: true),
        ]
        let t = recompute(entries, topLevel: aId)

        let a = t.get(aId)!
        let b = t.get(bId)!

        // A's clipList: 4-rect frame around B.
        XCTAssertEqual(a.clipList.rects, [
            BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 10),
            BoxRec(x1: 0,  y1: 10, x2: 10,  y2: 60),
            BoxRec(x1: 60, y1: 10, x2: 100, y2: 60),
            BoxRec(x1: 0,  y1: 60, x2: 100, y2: 100),
        ])
        XCTAssertEqual(a.borderClip, Region(box: box(0, 0, 100, 100)))
        XCTAssertNil(a.clipList.validate())

        // B's clipList: B's own interior (no children).
        XCTAssertEqual(b.clipList, Region(box: box(10, 10, 60, 60)))
        XCTAssertEqual(b.borderClip, Region(box: box(10, 10, 60, 60)))
    }

    // MARK: - Doc case 2: two siblings — in our model, two children
    // of a single top-level (rootless top-levels don't overlap).

    func testDocCase2_TwoMappedSiblingsBothSubtractFromParent() {
        // A (0,0,200,100). Children B (0,0,100,100) and C (50,0,100,100)
        // — B and C overlap in x=50..100. Without stacking awareness,
        // BOTH subtract from A, but A.clipList ends up the same in either
        // order: A - B - C with B ∪ C covering x=0..150 → A.clipList is
        // the right strip x=150..200.
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let cId: UInt32 = 0x102
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 200, height: 100, mapped: true),
            makeWindow(id: bId, parent: aId, x: 0,  y: 0, width: 100, height: 100, mapped: true),
            makeWindow(id: cId, parent: aId, x: 50, y: 0, width: 100, height: 100, mapped: true),
        ]
        let t = recompute(entries, topLevel: aId)

        let a = t.get(aId)!
        XCTAssertEqual(a.clipList, Region(box: box(150, 0, 200, 100)))
        XCTAssertNil(a.clipList.validate())
    }

    // MARK: - Doc case 3: re-map after unmap → expose full rect

    func testDocCase3_UnmappedWindowHasEmptyClipList() {
        // Just verify unmapped semantics: a window that's not mapped has
        // empty clipList and borderClip, and its parent's clipList
        // doesn't shrink because of it.
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 100, height: 100, mapped: true),
            // B exists but is not mapped.
            makeWindow(id: bId, parent: aId, x: 10, y: 10, width: 50, height: 50, mapped: false),
        ]
        let t = recompute(entries, topLevel: aId)

        let a = t.get(aId)!
        let b = t.get(bId)!

        // A's clipList = full A interior (B doesn't obscure).
        XCTAssertEqual(a.clipList, Region(box: box(0, 0, 100, 100)))
        // B's clip regions are empty (unmapped).
        XCTAssertTrue(b.clipList.isEmpty)
        XCTAssertTrue(b.borderClip.isEmpty)
    }

    func testDocCase3_MapAfterUnmapRefreshesClipList() {
        // Build, recompute, unmap, recompute, map again, recompute.
        // After the final recompute clipList must equal the first-map state.
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let table = WindowTable()
        table.insert(makeWindow(id: aId, parent: rootId, width: 100, height: 100, mapped: true))
        SiblingChain.linkAtTop(aId, parent: rootId, in: table)
        table.insert(makeWindow(id: bId, parent: aId, x: 10, y: 10, width: 50, height: 50, mapped: true))
        SiblingChain.linkAtTop(bId, parent: aId, in: table)
        ClipListEngine.recomputeClips(forTopLevel: aId, in: table)
        let firstClipA = table.get(aId)!.clipList

        // Unmap A.
        table.setMapped(aId, false)
        ClipListEngine.recomputeClips(forTopLevel: aId, in: table)
        XCTAssertTrue(table.get(aId)!.clipList.isEmpty)
        XCTAssertTrue(table.get(bId)!.clipList.isEmpty)

        // Re-map A.
        table.setMapped(aId, true)
        ClipListEngine.recomputeClips(forTopLevel: aId, in: table)
        XCTAssertEqual(table.get(aId)!.clipList, firstClipA)
    }

    // MARK: - Doc case 4: A maps with B already mapped underneath

    func testDocCase4_MapAWithPreExistingMappedChild() {
        // Initial state: A unmapped, B (child of A) already mapped.
        // (X allows mapping a descendant before its parent — common in
        // Motif's bottom-up Realize pattern.) After the A-map recompute:
        //   A.clipList = A interior - B
        //   B.clipList = B interior (full)
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let table = WindowTable()
        table.insert(makeWindow(id: aId, parent: rootId, width: 100, height: 100, mapped: false))
        SiblingChain.linkAtTop(aId, parent: rootId, in: table)
        table.insert(makeWindow(id: bId, parent: aId, x: 10, y: 10, width: 50, height: 50, mapped: true))
        SiblingChain.linkAtTop(bId, parent: aId, in: table)

        // Recompute while A is unmapped. Both should have empty clip.
        ClipListEngine.recomputeClips(forTopLevel: aId, in: table)
        XCTAssertTrue(table.get(aId)!.clipList.isEmpty)
        XCTAssertTrue(table.get(bId)!.clipList.isEmpty)

        // Now map A.
        table.setMapped(aId, true)
        ClipListEngine.recomputeClips(forTopLevel: aId, in: table)

        let a = table.get(aId)!
        let b = table.get(bId)!
        XCTAssertEqual(a.clipList.rectCount, 4)              // frame around B
        XCTAssertEqual(b.clipList, Region(box: box(10, 10, 60, 60)))
    }

    // MARK: - Multi-level descendants

    func testGrandchildSubtractsFromBothAncestors() {
        // A (top-level, 200x200) → B (child at 50,50 sized 100x100) →
        // C (grandchild at 10,10 sized 30x30 within B = (60,60..90,90)
        // in top-level coords). After recompute:
        //   A.clipList = A interior minus B (frame around B)
        //   B.clipList = B interior minus C (frame around C in tl coords)
        //   C.clipList = C interior (full)
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let cId: UInt32 = 0x102
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 200, height: 200, mapped: true),
            makeWindow(id: bId, parent: aId, x: 50, y: 50, width: 100, height: 100, mapped: true),
            makeWindow(id: cId, parent: bId, x: 10, y: 10, width: 30, height: 30, mapped: true),
        ]
        let t = recompute(entries, topLevel: aId)

        let a = t.get(aId)!
        let b = t.get(bId)!
        let c = t.get(cId)!

        XCTAssertEqual(a.clipList.rectCount, 4)  // frame around B
        XCTAssertEqual(b.clipList.rectCount, 4)  // frame around C (in top-level coords)
        XCTAssertEqual(b.clipList.boundingBox, BoxRec(x1: 50, y1: 50, x2: 150, y2: 150))
        XCTAssertEqual(c.clipList, Region(box: box(60, 60, 90, 90)))
        XCTAssertNil(a.clipList.validate())
        XCTAssertNil(b.clipList.validate())
    }

    func testOffScreenChildIsClippedToParent() {
        // A (100x100). Child B at (80,80) sized 50x50 — extends past A's
        // bottom-right corner. B's borderClip should be clipped to A's
        // interior; the part outside is gone.
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 100, height: 100, mapped: true),
            makeWindow(id: bId, parent: aId, x: 80, y: 80, width: 50, height: 50, mapped: true),
        ]
        let t = recompute(entries, topLevel: aId)

        let b = t.get(bId)!
        // B sized 50x50 at (80,80) clipped to A's 100x100 → (80,80..100,100).
        XCTAssertEqual(b.clipList, Region(box: box(80, 80, 100, 100)))
        XCTAssertEqual(b.borderClip, Region(box: box(80, 80, 100, 100)))
    }

    // MARK: - Border handling

    func testWindowWithBorderHasLargerBorderClip() {
        // A top-level. Child B with borderWidth=2 at (50,50,20x20)
        // inside it. borderClip extends 2px on each side; clipList does
        // not include the border.
        let aId: UInt32 = 0x100
        let bId: UInt32 = 0x101
        let rootId: UInt32 = 0x28
        let entries = [
            makeWindow(id: aId, parent: rootId, width: 200, height: 200, mapped: true),
            makeWindow(id: bId, parent: aId, x: 50, y: 50, width: 20, height: 20,
                       borderWidth: 2, mapped: true),
        ]
        let t = recompute(entries, topLevel: aId)

        let b = t.get(bId)!
        XCTAssertEqual(b.clipList, Region(box: box(50, 50, 70, 70)))
        XCTAssertEqual(b.borderClip, Region(box: box(48, 48, 72, 72)))

        // A's clipList is its interior minus B's borderClip (the border
        // ring also obscures A).
        let a = t.get(aId)!
        let expectedAClip = Region(box: box(0, 0, 200, 200))
            .subtracting(Region(box: box(48, 48, 72, 72)))
        XCTAssertEqual(a.clipList, expectedAClip)
    }

    // MARK: - Dispatch wiring (drives a real ServerSession)

    func testMapWindowDispatchPopulatesClipList() {
        // End-to-end check that the handler wiring calls
        // recomputeClipsForSubtreeContaining. Feed CreateWindow +
        // MapWindow bytes through a real session and assert clipList
        // came out populated.
        let session = ServerSession()
        // Drive setup so the session reaches running phase.
        let setupBytes = setupRequestBytes()
        _ = session.feed(setupBytes)
        XCTAssertTrue(session.setupAcceptedSent)
        guard let byteOrder = session.byteOrder else {
            XCTFail("setup not complete"); return
        }

        let topId: UInt32 = 0x4400001
        let create = createWindowBytes(
            wid: topId, parent: 0x28,
            x: 0, y: 0, width: 100, height: 100,
            borderWidth: 0, byteOrder: byteOrder
        )
        _ = session.feed(create)
        let map = mapWindowBytes(window: topId, byteOrder: byteOrder)
        _ = session.feed(map)

        let entry = session.windows.get(topId)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.clipList, Region(box: box(0, 0, 100, 100)))
        XCTAssertEqual(entry?.borderClip, Region(box: box(0, 0, 100, 100)))
    }

    func testReplayCaptureProducesPopulatedClipLists() {
        // After replaying a captured app's full C2S byte stream, the
        // recompute wiring must fire — i.e. at least one mapped window
        // ends up with a non-empty clipList, and clip regions validate
        // their banding invariants. (Individual windows can legitimately
        // have empty clipList — a fully-covered parent does — so a
        // global "anyPopulated" check is the right shape here.)
        let path = capturePath(named: "xcalc.xtap")
        guard let frames = try? CaptureReader.read(from: path) else {
            XCTFail("could not read \(path)"); return
        }
        let c2s = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }

        let session = ServerSession()
        _ = session.feed(c2s)

        var anyPopulated = false
        var validatedCount = 0
        for w in session.windows.windows.values where w.mapped {
            if !w.clipList.isEmpty { anyPopulated = true }
            XCTAssertNil(w.clipList.validate(),
                         "0x\(String(w.id, radix: 16)) clipList invariants failed")
            XCTAssertNil(w.borderClip.validate(),
                         "0x\(String(w.id, radix: 16)) borderClip invariants failed")
            validatedCount += 1
        }
        XCTAssertTrue(anyPopulated, "no mapped window has populated clipList — wiring missed")
        XCTAssertGreaterThan(validatedCount, 10, "xcalc should have mapped many windows")
    }

    // MARK: - Byte builders

    private func setupRequestBytes() -> [UInt8] {
        // Minimal SetupRequest in little-endian: 'l', 0, 11, 0, 0, 0, 0, 0,
        // then 8 bytes of empty auth name/data plus pad.
        // Easier to crib from XclockReplayTests pattern, but that test
        // reuses xclock.xtap C2S bytes which include real setup. The
        // simplest reliable path is to use a tiny SetupRequest by hand.
        var b: [UInt8] = []
        b.append(0x6c)            // 'l' little-endian
        b.append(0)               // pad
        b.append(11); b.append(0) // protocol major
        b.append(0);  b.append(0) // protocol minor
        b.append(0);  b.append(0) // auth-name length
        b.append(0);  b.append(0) // auth-data length
        b.append(0);  b.append(0) // pad
        return b
    }

    private func createWindowBytes(
        wid: UInt32, parent: UInt32,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        borderWidth: UInt16, byteOrder: ByteOrder
    ) -> [UInt8] {
        // CreateWindow opcode 1; request length 8 (32-byte header, no value list).
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(1)                 // opcode
        w.writeUInt8(0)                 // depth = CopyFromParent
        w.writeUInt16(8)                // request length in 4-byte units
        w.writeUInt32(wid)
        w.writeUInt32(parent)
        w.writeUInt16(UInt16(bitPattern: x)); w.writeUInt16(UInt16(bitPattern: y))
        w.writeUInt16(width); w.writeUInt16(height)
        w.writeUInt16(borderWidth)
        w.writeUInt16(0)                // class = CopyFromParent
        w.writeUInt32(0)                // visual = CopyFromParent
        w.writeUInt32(0)                // value-mask = 0
        return w.bytes
    }

    private func mapWindowBytes(window: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        var w = ByteWriter(byteOrder: byteOrder)
        w.writeUInt8(8)                 // MapWindow opcode
        w.writeUInt8(0)
        w.writeUInt16(2)                // 2 * 4 bytes
        w.writeUInt32(window)
        return w.bytes
    }

    private func capturePath(named filename: String) -> String {
        // Tests/SwiftXServerCoreTests/Region/ClipListPopulationTests.swift
        // → four parent traversals reaches the repo root.
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
