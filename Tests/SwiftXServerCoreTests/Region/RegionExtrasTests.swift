import XCTest
@testable import SwiftXServerCore

// Tests for the 5 region ops ported in RegionExtras.swift: inverse,
// reset, rects(_:order:), appended, normalized. Each test ends with the
// existing invariant checker (`validate()`) to enforce y-x banding.

final class RegionExtrasTests: XCTestCase {

    // MARK: - inverse

    func testInverseOfEmptyRegionIsInvRect() {
        let r = Region.empty
        let invRect = BoxRec(x1: 0, y1: 0, x2: 100, y2: 100)
        let result = r.inverse(within: invRect)
        XCTAssertEqual(result.rects, [invRect])
        XCTAssertNil(result.validate())
    }

    func testInverseOfNonOverlappingRegionIsInvRect() {
        // Region fully outside invRect → result is invRect unchanged.
        let r = Region(box: BoxRec(x1: 200, y1: 200, x2: 300, y2: 300))
        let invRect = BoxRec(x1: 0, y1: 0, x2: 100, y2: 100)
        let result = r.inverse(within: invRect)
        XCTAssertEqual(result.rects, [invRect])
        XCTAssertNil(result.validate())
    }

    func testInverseOfFullyContainedRectIsFrame() {
        // Hole in the middle → result is a 4-rect frame around it.
        let r = Region(box: BoxRec(x1: 30, y1: 30, x2: 70, y2: 70))
        let invRect = BoxRec(x1: 0, y1: 0, x2: 100, y2: 100)
        let result = r.inverse(within: invRect)
        XCTAssertNil(result.validate())
        XCTAssertEqual(result.boundingBox, invRect)
        // Verify a point in each region of the expected frame is "in"
        // and the hole's center is "out".
        XCTAssertTrue(result.contains(x: 5, y: 5))       // top-left
        XCTAssertTrue(result.contains(x: 95, y: 5))      // top-right
        XCTAssertTrue(result.contains(x: 5, y: 95))      // bottom-left
        XCTAssertTrue(result.contains(x: 95, y: 95))     // bottom-right
        XCTAssertFalse(result.contains(x: 50, y: 50))    // hole center
    }

    func testInverseRoundtripsToOriginal() {
        // (invRect - (invRect - region)) ∩ invRect should equal region ∩ invRect.
        let r = Region(box: BoxRec(x1: 20, y1: 20, x2: 80, y2: 80))
        let invRect = BoxRec(x1: 0, y1: 0, x2: 100, y2: 100)
        let inverted = r.inverse(within: invRect)
        let doubleInverted = inverted.inverse(within: invRect)
        XCTAssertEqual(doubleInverted, r.intersected(with: Region(box: invRect)))
        XCTAssertNil(doubleInverted.validate())
    }

    // MARK: - reset

    func testResetFromEmptyBox() {
        XCTAssertTrue(Region.reset(to: BoxRec()).isEmpty)
    }

    func testResetFromNonEmptyBox() {
        let box = BoxRec(x1: 5, y1: 10, x2: 25, y2: 30)
        let r = Region.reset(to: box)
        XCTAssertEqual(r.rects, [box])
        XCTAssertEqual(r.boundingBox, box)
        XCTAssertNil(r.validate())
    }

    // MARK: - rects(_:order:)

    func testRectsEmptyArray() {
        let r = Region.rects([], order: .yxBanded)
        XCTAssertTrue(r.isEmpty)
    }

    func testRectsFiltersEmptyBoxes() {
        // Empty boxes are filtered per miregion.c:1605.
        let r = Region.rects([
            BoxRec(),                                       // empty
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 5, y1: 5, x2: 5, y2: 15),            // zero-width
            BoxRec(x1: 20, y1: 20, x2: 30, y2: 20),         // zero-height
        ], order: .unsorted)
        XCTAssertEqual(r.rects, [BoxRec(x1: 0, y1: 0, x2: 10, y2: 10)])
        XCTAssertNil(r.validate())
    }

    func testRectsYXBandedTrusts() {
        // A pre-banded input passes through unchanged.
        let banded = [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 5),
            BoxRec(x1: 20, y1: 0, x2: 30, y2: 5),
            BoxRec(x1: 0, y1: 5, x2: 30, y2: 10),
        ]
        let r = Region.rects(banded, order: .yxBanded)
        XCTAssertEqual(r.rects, banded)
        XCTAssertNil(r.validate())
    }

    func testRectsUnsortedNormalizes() {
        // Unsorted input gets sorted + banded.
        let unsorted = [
            BoxRec(x1: 20, y1: 0, x2: 30, y2: 5),
            BoxRec(x1: 0, y1: 5, x2: 30, y2: 10),
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 5),
        ]
        let r = Region.rects(unsorted, order: .unsorted)
        XCTAssertNil(r.validate())
        XCTAssertEqual(r.rects, [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 5),
            BoxRec(x1: 20, y1: 0, x2: 30, y2: 5),
            BoxRec(x1: 0, y1: 5, x2: 30, y2: 10),
        ])
    }

    // MARK: - appended

    func testAppendedToEmpty() {
        let other = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let (result, needs) = Region.empty.appended(other)
        XCTAssertEqual(result.rects, other.rects)
        XCTAssertFalse(needs)
        XCTAssertNil(result.validate())
    }

    func testAppendedEmptyReturnsSelf() {
        let self_ = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let (result, needs) = self_.appended(.empty)
        XCTAssertEqual(result, self_)
        XCTAssertFalse(needs)
    }

    func testAppendedDisjointAfter() {
        // Other starts AFTER self in y → clean append, no normalize needed.
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 0, y1: 20, x2: 10, y2: 30))
        let (result, needs) = a.appended(b)
        XCTAssertFalse(needs)
        XCTAssertEqual(result.rects, [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 0, y1: 20, x2: 10, y2: 30),
        ])
        XCTAssertEqual(result.boundingBox, BoxRec(x1: 0, y1: 0, x2: 10, y2: 30))
        XCTAssertNil(result.validate())
    }

    func testAppendedDisjointBeforePrepends() {
        // Other ends BEFORE self in y → clean prepend.
        let a = Region(box: BoxRec(x1: 0, y1: 20, x2: 10, y2: 30))
        let b = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let (result, needs) = a.appended(b)
        XCTAssertFalse(needs)
        XCTAssertEqual(result.rects, [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 0, y1: 20, x2: 10, y2: 30),
        ])
        XCTAssertNil(result.validate())
    }

    func testAppendedOverlappingNeedsNormalize() {
        // Overlap in y → can't append/prepend cleanly; flag normalize needed.
        // Uses same-y-band rects so we can also exercise normalize's
        // overlap-detection flag (which only fires for horizontal
        // overlaps within a single y-band, per miregion.c:1471).
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 5, y1: 0, x2: 15, y2: 10))
        let (result, needs) = a.appended(b)
        XCTAssertTrue(needs)
        // Normalize should produce a valid banded result.
        let (normalized, overlap) = result.normalized()
        XCTAssertTrue(overlap)
        XCTAssertNil(normalized.validate())
        // Verify the result equals the union of the two.
        XCTAssertEqual(normalized, a.unioned(with: b))
    }

    func testAppendedDifferentBandsNeedsNormalizeNoOverlap() {
        // Rects in different y-bands that aren't strictly orderable by
        // the (y1 > last.y2) shortcut also need normalize, but the
        // overlap flag is FALSE since they don't share a band.
        let a = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let b = Region(box: BoxRec(x1: 5, y1: 5, x2: 15, y2: 15))
        let (result, needs) = a.appended(b)
        XCTAssertTrue(needs)
        let (normalized, overlap) = result.normalized()
        XCTAssertFalse(overlap)
        XCTAssertNil(normalized.validate())
        XCTAssertEqual(normalized, a.unioned(with: b))
    }

    // MARK: - normalized

    func testNormalizedEmpty() {
        let (r, overlap) = Region.empty.normalized()
        XCTAssertTrue(r.isEmpty)
        XCTAssertFalse(overlap)
    }

    func testNormalizedSingleRect() {
        let r = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let (normalized, overlap) = r.normalized()
        XCTAssertEqual(normalized, r)
        XCTAssertFalse(overlap)
    }

    func testNormalizedAlreadyBandedIsIdentity() {
        let banded = [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 5),
            BoxRec(x1: 20, y1: 0, x2: 30, y2: 5),
            BoxRec(x1: 0, y1: 5, x2: 30, y2: 10),
        ]
        let r = Region(rectsTrusted: banded)
        let (normalized, overlap) = r.normalized()
        XCTAssertEqual(normalized.rects, banded)
        XCTAssertFalse(overlap)
    }

    func testNormalizedOverlapDetected() {
        var raw = Region()
        raw.extents = BoxRec(x1: 0, y1: 0, x2: 20, y2: 10)
        raw.storage = Storage(rects: [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 5, y1: 0, x2: 15, y2: 10),    // overlaps the first
        ])
        let (normalized, overlap) = raw.normalized()
        XCTAssertTrue(overlap)
        XCTAssertEqual(normalized.rects, [BoxRec(x1: 0, y1: 0, x2: 15, y2: 10)])
        XCTAssertNil(normalized.validate())
    }

    func testNormalizedUnsortedScattersAndMerges() {
        // Three disjoint rects in random order — normalize sorts then bands.
        var raw = Region()
        raw.extents = BoxRec(x1: 0, y1: 0, x2: 30, y2: 30)
        raw.storage = Storage(rects: [
            BoxRec(x1: 20, y1: 20, x2: 30, y2: 30),
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 10, y1: 10, x2: 20, y2: 20),
        ])
        let (normalized, overlap) = raw.normalized()
        XCTAssertFalse(overlap)
        XCTAssertNil(normalized.validate())
        XCTAssertEqual(normalized.rects, [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 10, y1: 10, x2: 20, y2: 20),
            BoxRec(x1: 20, y1: 20, x2: 30, y2: 30),
        ])
    }

    func testNormalizedCoalescesAdjacentBands() {
        // Two y-adjacent bands with identical x coverage should fuse
        // into one rect — exercises the Coalesce path.
        var raw = Region()
        raw.extents = BoxRec(x1: 0, y1: 0, x2: 10, y2: 20)
        raw.storage = Storage(rects: [
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 10),
            BoxRec(x1: 0, y1: 10, x2: 10, y2: 20),    // touches + same x
        ])
        let (normalized, _) = raw.normalized()
        XCTAssertNil(normalized.validate())
        XCTAssertEqual(normalized.rects, [BoxRec(x1: 0, y1: 0, x2: 10, y2: 20)])
    }
}
