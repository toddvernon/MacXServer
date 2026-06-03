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

    // MARK: - Logical ↔ device scaling (DEVICE_COORDS_REFACTOR.md)

    func testBoxScaledToDeviceMultipliesByScale() {
        let b = BoxRec(x1: 4, y1: 5, x2: 14, y2: 20)
        XCTAssertEqual(b.scaledToDevice(by: 3), BoxRec(x1: 12, y1: 15, x2: 42, y2: 60))
        XCTAssertEqual(b.scaledToDevice(by: 1), b, "scale 1 is a no-op")
    }

    func testBoxScaledToLogicalConservative() {
        // Device box covering exactly logical (1..5, 2..7) at scale 3
        // round-trips back to itself.
        let exact = BoxRec(x1: 3, y1: 6, x2: 15, y2: 21)
        XCTAssertEqual(exact.scaledToLogical(by: 3),
                       BoxRec(x1: 1, y1: 2, x2: 5, y2: 7))

        // Device box that fractionally covers logical pixels: floor on
        // x1/y1, ceil on x2/y2 → conservative (every logical pixel with
        // ANY device coverage is included).
        let partial = BoxRec(x1: 4, y1: 7, x2: 14, y2: 20)   // (4..14, 7..20) at scale 3
        // x1=4 → floor(4/3)=1; y1=7 → floor(7/3)=2; x2=14 → ceil(14/3)=5; y2=20 → ceil(20/3)=7
        XCTAssertEqual(partial.scaledToLogical(by: 3),
                       BoxRec(x1: 1, y1: 2, x2: 5, y2: 7))
    }

    func testBoxScaledToLogicalHandlesNegatives() {
        // -1 device px in interior-local coords is in the border ring.
        // floor(-1/3) = -1 because Swift's / rounds toward zero;
        // floor wants -1 (round toward -inf).
        XCTAssertEqual(BoxRec(x1: -3, y1: -3, x2: 0, y2: 0).scaledToLogical(by: 3),
                       BoxRec(x1: -1, y1: -1, x2: 0, y2: 0))
        // Partial: x1=-2 → floor(-2/3)=-1; x2=-1 → ceil(-1/3)=0
        XCTAssertEqual(BoxRec(x1: -2, y1: -2, x2: -1, y2: -1).scaledToLogical(by: 3),
                       BoxRec(x1: -1, y1: -1, x2: 0, y2: 0))
    }

    func testRegionScaledToDevicePreservesBanding() {
        // Two y-adjacent bands of the same x extent. Scaling by 3
        // produces two y-adjacent bands of the same (scaled) x extent —
        // the y-x banded invariant survives uniform integer scaling.
        let r = Region.rects([
            BoxRec(x1: 0, y1: 0, x2: 10, y2: 5),
            BoxRec(x1: 0, y1: 5, x2: 10, y2: 10),
        ], order: .unsorted)
        let scaled = r.scaledToDevice(by: 3)
        XCTAssertNil(scaled.validate(), "banded invariant preserved")
        XCTAssertEqual(scaled.boundingBox,
                       BoxRec(x1: 0, y1: 0, x2: 30, y2: 30))
    }

    func testRegionScaledToLogicalRoundTrip() {
        // A logical region → device → logical should return the
        // original. Pin this so the conversion functions form a
        // proper inverse on exact-scale-aligned boxes.
        let logical = Region.rects([
            BoxRec(x1: 1, y1: 2, x2: 5, y2: 7),
            BoxRec(x1: 10, y1: 2, x2: 14, y2: 7),
        ], order: .unsorted)
        let roundTripped = logical.scaledToDevice(by: 3).scaledToLogical(by: 3)
        XCTAssertEqual(roundTripped.rects, logical.rects)
    }

    func testEmptyRegionScaleIsEmpty() {
        XCTAssertEqual(Region.empty.scaledToDevice(by: 3), Region.empty)
        XCTAssertEqual(Region.empty.scaledToLogical(by: 3), Region.empty)
    }

    func testServerConfigDeviceScaleIsInt32RoundedScale() {
        let cfg = ServerConfig.default
        XCTAssertEqual(cfg.deviceScale, Int32(cfg.scaleFactor.rounded()))
        XCTAssertGreaterThanOrEqual(cfg.deviceScale, 1)
    }
}
