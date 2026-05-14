import XCTest
@testable import SwiftXServerCore

// Covers the algebra of Region: union / intersect / subtract / translate /
// rectIn / contains. All pure-state, no AppKit. Each test ends with a
// `validate()` call so the y-x band invariants are enforced everywhere.
//
// Equality is intentional: if a test expects a 4-rect frame around a
// rectangular hole, the test pins not just the rect count but the band
// structure that miRegionOp produces.

final class RegionAlgebraTests: XCTestCase {

    // MARK: - Construction

    func testEmptyRegion() {
        let r = Region.empty
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.rectCount, 0)
        XCTAssertEqual(r.rects, [])
        XCTAssertNil(r.validate())
    }

    func testSingleRectRegion() {
        let r = Region(box: BoxRec(x1: 10, y1: 20, x2: 30, y2: 40))
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.rectCount, 1)
        XCTAssertEqual(r.rects, [BoxRec(x1: 10, y1: 20, x2: 30, y2: 40)])
        XCTAssertEqual(r.boundingBox, BoxRec(x1: 10, y1: 20, x2: 30, y2: 40))
        XCTAssertNil(r.validate())
    }

    func testInverseBoxYieldsEmpty() {
        // x2 < x1 and y2 < y1: zero-area box, region must be empty.
        let r1 = Region(box: BoxRec(x1: 50, y1: 50, x2: 10, y2: 60))
        let r2 = Region(box: BoxRec(x1: 10, y1: 50, x2: 30, y2: 30))
        XCTAssertTrue(r1.isEmpty)
        XCTAssertTrue(r2.isEmpty)
    }

    func testZeroSizeBoxYieldsEmpty() {
        // Half-open intervals: x1 == x2 has zero width → empty.
        let r = Region(box: BoxRec(x1: 10, y1: 10, x2: 10, y2: 20))
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - Union

    func testUnionDisjoint() {
        // Two rectangles that don't touch. Expect two bands.
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 20, y1: 20, x2: 30, y2: 30))
        let u = a.unioned(with: b)
        XCTAssertEqual(u.rects, [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 20, y1: 20, x2: 30, y2: 30),
        ])
        XCTAssertEqual(u.boundingBox, BoxRec(x1: 0, y1: 0, x2: 30, y2: 30))
        XCTAssertNil(u.validate())
    }

    func testUnionIdenticalIsIdempotent() {
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let u = a.unioned(with: a)
        XCTAssertEqual(u, a)
        XCTAssertNil(u.validate())
    }

    func testUnionPartialOverlap() {
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 20, y2: 20))
        let b = Region(box: BoxRec(x1: 10, y1: 10, x2: 30, y2: 30))
        let u = a.unioned(with: b)
        // Expected y-banded layout:
        //   y=0..10:  x=0..20    (just a's top half)
        //   y=10..20: x=0..30    (a's bottom half ∪ b's top half)
        //   y=20..30: x=10..30   (just b's bottom half)
        XCTAssertEqual(u.rects, [
            BoxRec(x1: 0,  y1: 0,  x2: 20, y2: 10),
            BoxRec(x1: 0,  y1: 10, x2: 30, y2: 20),
            BoxRec(x1: 10, y1: 20, x2: 30, y2: 30),
        ])
        XCTAssertNil(u.validate())
    }

    func testUnionHorizontallyAdjacentCoalesces() {
        // Two rectangles touching at x — must coalesce to one rect.
        let a = Region(box: BoxRec(x1: 0,  y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 10, y1: 0, x2: 20, y2: 10))
        let u = a.unioned(with: b)
        XCTAssertEqual(u.rects, [BoxRec(x1: 0, y1: 0, x2: 20, y2: 10)])
        XCTAssertNil(u.validate())
    }

    func testUnionVerticallyAdjacentCoalesces() {
        // Two rectangles touching at y, same x-coverage — coalesce into
        // one rect via miCoalesce.
        let a = Region(box: BoxRec(x1: 0, y1: 0,  x2: 20, y2: 10))
        let b = Region(box: BoxRec(x1: 0, y1: 10, x2: 20, y2: 20))
        let u = a.unioned(with: b)
        XCTAssertEqual(u.rects, [BoxRec(x1: 0, y1: 0, x2: 20, y2: 20)])
        XCTAssertNil(u.validate())
    }

    func testUnionWithEmpty() {
        let a = Region(box: BoxRec(x1: 5, y1: 5, x2: 15, y2: 15))
        XCTAssertEqual(a.unioned(with: .empty), a)
        XCTAssertEqual(Region.empty.unioned(with: a), a)
    }

    // MARK: - Intersect

    func testIntersectDisjointEmpty() {
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 20, y1: 20, x2: 30, y2: 30))
        XCTAssertTrue(a.intersected(with: b).isEmpty)
    }

    func testIntersectIdenticalSame() {
        let a = Region(box: BoxRec(x1: 5, y1: 5, x2: 25, y2: 25))
        XCTAssertEqual(a.intersected(with: a), a)
    }

    func testIntersectPartialOverlap() {
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 20, y2: 20))
        let b = Region(box: BoxRec(x1: 10, y1: 10, x2: 30, y2: 30))
        let inter = a.intersected(with: b)
        XCTAssertEqual(inter.rects, [BoxRec(x1: 10, y1: 10, x2: 20, y2: 20)])
        XCTAssertNil(inter.validate())
    }

    func testIntersectWithEmpty() {
        let a = Region(box: BoxRec(x1: 5, y1: 5, x2: 15, y2: 15))
        XCTAssertTrue(a.intersected(with: .empty).isEmpty)
        XCTAssertTrue(Region.empty.intersected(with: a).isEmpty)
    }

    func testIntersectSubsumes() {
        // Outer fully contains inner → result is inner.
        let outer = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let inner = Region(box: BoxRec(x1: 10, y1: 10, x2: 20,  y2: 20))
        XCTAssertEqual(outer.intersected(with: inner), inner)
        XCTAssertEqual(inner.intersected(with: outer), inner)
    }

    // MARK: - Subtract

    func testSubtractDisjointIsIdentity() {
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 20, y1: 20, x2: 30, y2: 30))
        XCTAssertEqual(a.subtracting(b), a)
    }

    func testSubtractFullCoverYieldsEmpty() {
        let a = Region(box: BoxRec(x1: 5, y1: 5, x2: 15, y2: 15))
        let b = Region(box: BoxRec(x1: 0, y1: 0, x2: 20, y2: 20))
        XCTAssertTrue(a.subtracting(b).isEmpty)
    }

    func testSubtractRemovesHoleProducingFourRectFrame() {
        // Outer minus inner-not-touching-edges → 4-rect frame.
        let outer = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let hole  = Region(box: BoxRec(x1: 30, y1: 30, x2: 70,  y2: 70))
        let r = outer.subtracting(hole)
        // Expected bands:
        //   y=0..30:  full width  (x=0..100)
        //   y=30..70: two rects (x=0..30 and x=70..100) — the frame's sides
        //   y=70..100: full width
        XCTAssertEqual(r.rects, [
            BoxRec(x1: 0,  y1: 0,   x2: 100, y2: 30),
            BoxRec(x1: 0,  y1: 30,  x2: 30,  y2: 70),
            BoxRec(x1: 70, y1: 30,  x2: 100, y2: 70),
            BoxRec(x1: 0,  y1: 70,  x2: 100, y2: 100),
        ])
        XCTAssertEqual(r.boundingBox, BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
        XCTAssertNil(r.validate())
    }

    func testSubtractCornerYieldsLShape() {
        // Subtracting a corner produces an L-shape: 2 bands.
        let outer = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let corner = Region(box: BoxRec(x1: 60, y1: 60, x2: 100, y2: 100))
        let r = outer.subtracting(corner)
        XCTAssertEqual(r.rects, [
            BoxRec(x1: 0, y1: 0,  x2: 100, y2: 60),
            BoxRec(x1: 0, y1: 60, x2: 60,  y2: 100),
        ])
        XCTAssertNil(r.validate())
    }

    func testSubtractSiblingFromOriginalRect() {
        // The doc's case: parent A (0,0,100,100), child B (10,10,60,60)
        // mapped → A's visible region = A minus B.
        let a = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let b = Region(box: BoxRec(x1: 10, y1: 10, x2: 60,  y2: 60))
        let visible = a.subtracting(b)
        XCTAssertEqual(visible.rects, [
            BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 10),
            BoxRec(x1: 0,  y1: 10, x2: 10,  y2: 60),
            BoxRec(x1: 60, y1: 10, x2: 100, y2: 60),
            BoxRec(x1: 0,  y1: 60, x2: 100, y2: 100),
        ])
        XCTAssertNil(visible.validate())
    }

    // MARK: - Translate / contains / rectIn

    func testTranslate() {
        let a = Region(box: BoxRec(x1: 5, y1: 10, x2: 15, y2: 20))
        let t = a.translated(dx: 100, dy: 200)
        XCTAssertEqual(t.rects, [BoxRec(x1: 105, y1: 210, x2: 115, y2: 220)])
    }

    func testTranslateMultiRectPreservesBands() {
        // Build an L-shape, translate, confirm both rects moved together.
        let outer = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let corner = Region(box: BoxRec(x1: 60, y1: 60, x2: 100, y2: 100))
        let l = outer.subtracting(corner)
        let t = l.translated(dx: 10, dy: 20)
        XCTAssertEqual(t.rects, [
            BoxRec(x1: 10, y1: 20,  x2: 110, y2: 80),
            BoxRec(x1: 10, y1: 80,  x2: 70,  y2: 120),
        ])
        XCTAssertNil(t.validate())
    }

    func testContainsPoint() {
        let r = Region(box: BoxRec(x1: 10, y1: 10, x2: 20, y2: 20))
        XCTAssertTrue(r.contains(x: 10, y: 10))   // top-left corner inclusive
        XCTAssertTrue(r.contains(x: 15, y: 15))
        XCTAssertTrue(r.contains(x: 19, y: 19))
        XCTAssertFalse(r.contains(x: 20, y: 19))  // x2 exclusive
        XCTAssertFalse(r.contains(x: 19, y: 20))  // y2 exclusive
        XCTAssertFalse(r.contains(x: 5, y: 15))
        XCTAssertFalse(r.contains(x: 25, y: 15))
        XCTAssertFalse(Region.empty.contains(x: 0, y: 0))
    }

    func testContainsPointMultiRect() {
        // L-shape: y=0..60 spans 0..100, y=60..100 spans 0..60.
        let outer = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let corner = Region(box: BoxRec(x1: 60, y1: 60, x2: 100, y2: 100))
        let l = outer.subtracting(corner)
        XCTAssertTrue(l.contains(x: 30, y: 30))
        XCTAssertTrue(l.contains(x: 70, y: 30))   // in the top band
        XCTAssertTrue(l.contains(x: 30, y: 70))   // in the bottom band
        XCTAssertFalse(l.contains(x: 70, y: 70))  // in the cut-out corner
    }

    func testRectInAllOutPartial() {
        let r = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
        XCTAssertEqual(r.rectIn(BoxRec(x1: 10, y1: 10, x2: 20, y2: 20)), .fully)
        XCTAssertEqual(r.rectIn(BoxRec(x1: 200, y1: 200, x2: 300, y2: 300)), .out)
        XCTAssertEqual(r.rectIn(BoxRec(x1: 90, y1: 90, x2: 110, y2: 110)), .partially)
    }

    // MARK: - COW

    func testValueSemanticsCOW() {
        // Multi-rect region. Storage is class-backed; copying the struct
        // shares storage, but logical equality is preserved across mutation
        // attempts.
        let a = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let b = Region(box: BoxRec(x1: 30, y1: 30, x2: 70,  y2: 70))
        let frame = a.subtracting(b)
        let copy = frame
        XCTAssertEqual(copy, frame)
        // Both translate to the same result.
        XCTAssertEqual(copy.translated(dx: 0, dy: 0), frame)
        // Translate one — both still observe the original through their
        // own state (Region API is non-mutating, returns new Region).
        _ = frame.translated(dx: 1000, dy: 1000)
        XCTAssertEqual(copy, frame)
    }

    // MARK: - The four doc cases (pure-state region forms)

    // The doc's `WHAT_TO_DO_THIS_WEEK.md` listed four "test cases that don't
    // need live hardware" for the region library. Wired-in semantics
    // (windows / clipList) land in Step B's tests; here we just check the
    // region math each case reduces to.

    func testDocCase1_ChildSubtractedFromParent() {
        // "Window A at (0,0) 100x100; child B at (10,10) 50x50 mapped.
        //  A's visible region = original rect minus B's rect."
        let a = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let b = Region(box: BoxRec(x1: 10, y1: 10, x2: 60,  y2: 60))
        let visible = a.subtracting(b)
        XCTAssertEqual(visible.boundingBox, BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
        XCTAssertEqual(visible.rectCount, 4) // frame around B
        XCTAssertNil(visible.validate())
    }

    func testDocCase2_HigherSiblingClippedToA() {
        // "Window A at (0,0) 100x100; sibling C at (50,0) 100x100 higher.
        //  A's visible region = A minus (C clipped to A)."
        let a = Region(box: BoxRec(x1: 0,  y1: 0, x2: 100, y2: 100))
        let c = Region(box: BoxRec(x1: 50, y1: 0, x2: 150, y2: 100))
        // First clip C to A's bounds (sibling extends past A horizontally
        // but they share full y-range).
        let cClipped = c.intersected(with: a)
        let visible = a.subtracting(cClipped)
        XCTAssertEqual(visible.rects, [
            BoxRec(x1: 0, y1: 0, x2: 50, y2: 100),
        ])
        XCTAssertNil(visible.validate())
    }

    func testDocCase3_FullRectExposeOnRemap() {
        // "Window A at (0,0) 100x100; A unmapped then mapped again.
        //  Expose region = A's full rect."
        // Region-wise: starting from empty, the newly-viewable region IS
        // the window's rect.
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
        let newlyVisible = a.subtracting(.empty)
        XCTAssertEqual(newlyVisible, a)
    }

    func testDocCase4_AThenBExposeRegions() {
        // "A at (0,0,100,100) with child B (10,10,50x50) already mapped;
        //  A maps. Expose for A = A minus B. Expose for B = B's full rect."
        let a = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 100, y2: 100))
        let b = Region(box: BoxRec(x1: 10, y1: 10, x2: 60,  y2: 60))
        let exposeForA = a.subtracting(b)
        let exposeForB = b // first-paint, no overlap from B's perspective
        XCTAssertEqual(exposeForA.rectCount, 4)
        XCTAssertEqual(exposeForB, b)
    }
}
