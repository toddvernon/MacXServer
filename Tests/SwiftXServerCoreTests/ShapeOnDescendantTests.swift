import XCTest
@testable import SwiftXServerCore
import Framer

// Tests for descendant-window SHAPE rendering — the work that closes
// SHORTCUTS.md "SHAPE: bounding-on-top-level only" for descendants.
//
// Wire side already worked before this change (region stored, queryable
// via ShapeQueryExtents/ShapeGetRectangles). The change is that the
// stored shape now folds into ClipListEngine: a descendant's
// boundingShape narrows its borderClip; its clipShape narrows the
// interior portion of its clipList before children-subtract.
//
// Motivating client: xcalc emits 80 ShapeMask calls (40 buttons × 2:
// Bounding Set + Clip Set) targeting descendant button widgets. Before
// the fix the buttons rendered rectangular; after, the clipList reflects
// the rounded shape and the renderer respects it.

final class ShapeOnDescendantTests: XCTestCase {

    private let major: UInt8 = 128
    private let root = ServerConfig.default.rootWindowId

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    /// Create a top-level + one mapped child, return both ids. The child
    /// is positioned at (10,10) inside the 200×200 top-level.
    private func makeParentAndChild(_ session: ServerSession) -> (parent: UInt32, child: UInt32) {
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 1
        let child: UInt32 = ServerConfig.default.resourceIdBase + 2
        _ = session.feed(CreateWindow(
            depth: 0, wid: parent, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: parent).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: child, parent: parent,
            x: 10, y: 10, width: 40, height: 40, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: child).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return (parent, child)
    }

    /// Apply a Set/Bounding (or Set/Clip) shape made from `rects` to the
    /// target window. Rects are window-local; the server translates
    /// internally to top-level coords during clip recompute.
    private func applyShape(_ session: ServerSession, to dest: UInt32, kind: UInt8, rects: [Rectangle]) {
        let req = ShapeRectangles(
            op: ShapeOp.set, destKind: kind, ordering: 0, dest: dest,
            xOff: 0, yOff: 0, rectangles: rects
        )
        _ = session.feed(req.encode(majorOpcode: major, byteOrder: .lsbFirst))
        _ = session.outbound.drain()
    }

    func testDescendantBoundingShapeNarrowsBorderClip() throws {
        let session = runningSession()
        let (_, child) = makeParentAndChild(session)

        // Pre-shape: child's borderClip covers its full 40×40 at top-level (10,10).
        guard let preEntry = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(preEntry.borderClip), 40 * 40,
                       "unshaped child should have a 40×40 borderClip")

        // Apply a bounding shape of a single 20×20 sub-rect (window-local).
        applyShape(session, to: child, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 0, y: 0, width: 20, height: 20)])

        // Post-shape: borderClip is narrowed to 20×20 (still at top-level (10,10)).
        guard let postEntry = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(postEntry.borderClip), 20 * 20,
                       "bounding-shaped child's borderClip should be 20×20")
    }

    func testDescendantClipShapeNarrowsClipListNotBorderClip() throws {
        let session = runningSession()
        let (_, child) = makeParentAndChild(session)

        // Clip shape per spec restricts the interior, NOT the bounding extent.
        // So borderClip should still be 40×40, but clipList should be 25×25.
        applyShape(session, to: child, kind: ShapeKind.clip,
                   rects: [Rectangle(x: 0, y: 0, width: 25, height: 25)])

        guard let entry = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(entry.borderClip), 40 * 40,
                       "clip shape must not narrow borderClip")
        XCTAssertEqual(regionArea(entry.clipList), 25 * 25,
                       "clip-shaped child's clipList should be 25×25")
    }

    func testBoundingAndClipShapeBothNarrowToTheirIntersection() throws {
        // xcalc's pattern: each button gets Bounding Set + Clip Set, often
        // with the same source. Verify both fold in.
        let session = runningSession()
        let (_, child) = makeParentAndChild(session)

        applyShape(session, to: child, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 0, y: 0, width: 30, height: 30)])
        applyShape(session, to: child, kind: ShapeKind.clip,
                   rects: [Rectangle(x: 0, y: 0, width: 30, height: 30)])

        guard let entry = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(entry.borderClip), 30 * 30)
        XCTAssertEqual(regionArea(entry.clipList), 30 * 30)
    }

    func testDescendantShapeRecomputesAfterMutation() throws {
        // Issuing a second shape that REPLACES the first should reflect
        // the new state — the recompute hook fires on each shape change.
        let session = runningSession()
        let (_, child) = makeParentAndChild(session)

        applyShape(session, to: child, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 0, y: 0, width: 20, height: 20)])
        applyShape(session, to: child, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 0, y: 0, width: 35, height: 35)])

        guard let entry = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(entry.borderClip), 35 * 35,
                       "second bounding shape should fully replace the first")
    }

    func testTopLevelBoundingShapeStillWorksUnchanged() throws {
        // The existing top-level shape path masks the NSWindow via bridge;
        // changing the descendant path mustn't break it. We just verify
        // the top-level's borderClip narrows (the NSWindow side is a
        // bridge concern covered elsewhere).
        let session = runningSession()
        let top: UInt32 = ServerConfig.default.resourceIdBase + 1
        _ = session.feed(CreateWindow(
            depth: 0, wid: top, parent: root,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: top).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        applyShape(session, to: top, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 0, y: 0, width: 50, height: 50)])

        guard let entry = session.windows.get(top) else { return XCTFail() }
        XCTAssertEqual(regionArea(entry.borderClip), 50 * 50)
    }

    /// Regression for SHORTCUTS line 52 (closed 2026-06-02): the OUTER
    /// border-ring rect in `paintRectsForWindow` was painted unclipped
    /// over the full (w+2*bw, h+2*bw) box. With b849a3d's descendant
    /// SHAPE in place, the inner bg was correctly shape-narrowed but the
    /// border ring still painted over the full rect — xcalc symptom:
    /// each button looked like a black rectangle with a thin grey strip
    /// down the middle. Post-fix, the border ring is emitted from
    /// `entry.borderClip.rects`, so a shape-narrowed border ring covers
    /// only the visible border area and the parent shows through where
    /// the shape clipped the window away.
    func testBorderRingPaintsClippedToBorderClip() throws {
        let session = runningSession()
        // Top-level (parent) is 200×200, no bg/border so it doesn't add paints.
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 1
        let child: UInt32  = ServerConfig.default.resourceIdBase + 2
        _ = session.feed(CreateWindow(
            depth: 0, wid: parent, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: parent).encode(byteOrder: .lsbFirst))
        // Child mimics an Athena Command button: bw=1, bg=some, border=black,
        // mapped at (10,10), 40×20.
        func u32le(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        var values: [UInt8] = []
        values.append(contentsOf: u32le(0xFFFFFF))  // backPixel
        values.append(contentsOf: u32le(1))         // borderPixel = blackPixel
        _ = session.feed(CreateWindow(
            depth: 0, wid: child, parent: parent,
            x: 10, y: 10, width: 40, height: 20, borderWidth: 1,
            windowClass: .inputOutput, visual: 0,
            valueMask: CW.backPixel | CW.borderPixel, valueList: values
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: child).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Pre-shape: unshaped borderClip = full borderBox = 42×22 = 924.
        guard let pre = session.windows.get(child) else { return XCTFail() }
        XCTAssertEqual(regionArea(pre.borderClip), 42 * 22)

        // Apply a bounding shape that's narrower than the window: 20×22 at
        // x=10 (window-local). After clamp to borderBox the visible bounding
        // is the 20-wide vertical strip.
        applyShape(session, to: child, kind: ShapeKind.bounding,
                   rects: [Rectangle(x: 10, y: -1, width: 20, height: 22)])

        guard let post = session.windows.get(child) else { return XCTFail() }
        let borderClipArea = regionArea(post.borderClip)
        XCTAssertLessThan(borderClipArea, 42 * 22,
                          "bounding shape should narrow borderClip below full borderBox")

        // Border-paint rects come from `borderClip - interiorBox` (matches
        // R6 mi/dix: PW_BORDER paints over `borderClip - winSize` only,
        // dix/window.c:1403). For this case interiorBox in top-level coords
        // is (10,10)-(50,30) = 40×20 = 800. borderClip is the shape-narrowed
        // 20×22 strip at (20,9)-(40,31). Their difference is two horizontal
        // 20×1 strips (above and below the interior), area 40 total.
        let paints = session.mappedBackgroundPaints(topLevelId: parent, byteOrder: .lsbFirst)
        // borderPixel resolves to blackPixel == RGB(0,0,0); easy to filter.
        let borderPaints = paints.filter {
            $0.color == RGB16(red: 0, green: 0, blue: 0)
        }
        XCTAssertFalse(borderPaints.isEmpty, "border ring should emit at least one paint rect")
        let borderArea: Int64 = borderPaints.reduce(0) {
            $0 + Int64($1.width) * Int64($1.height)
        }
        XCTAssertLessThan(borderArea, Int64(borderClipArea),
                          "border-ring paints should NOT cover the full borderClip — that would blast the interior with the border color where bg can't reach (children's areas)")
        XCTAssertEqual(borderArea, 40,
                       "ring is (borderClip - interiorBox) = two 20×1 strips above and below the interior")
    }

    // (Removed 2026-06-03 in phase 6 of DEVICE_COORDS_REFACTOR.md:
    // testDeviceShapeRoutingSuppressesRectPaintAndEmitsShapedRecord was
    // testing the now-deleted boundingShapeDeviceRects/clipShapeDeviceRects
    // sidecar fields and mappedShapedDescendantPaints walker. The new
    // model puts shape regions directly in device coords on `boundingShape`
    // and `clipShape` so paintRectsForWindow emits device-coord rects via
    // the normal path — no sidecar, no separate walker.)

    /// Sum the areas of a region's boxes.
    private func regionArea(_ region: Region) -> Int64 {
        var total: Int64 = 0
        for box in region.rects {
            total += Int64(box.x2 - box.x1) * Int64(box.y2 - box.y1)
        }
        return total
    }
}
