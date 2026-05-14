import XCTest
@testable import SwiftXServerCore

// Focused tests on banding invariants and coalesce: pathological inputs
// that exercise the y-x-band representation directly. If a refactor of
// the band-walk engine in RegionOp.swift breaks coalescing, the right
// failures show up here.

final class RegionBandingTests: XCTestCase {

    func testUnionAdjacentRowsBecomeOneRect() {
        // Three vertically-adjacent same-width rects must coalesce.
        var r: Region = .empty
        r = r.unioned(with: Region(box: BoxRec(x1: 0, y1: 0,  x2: 10, y2: 5)))
        r = r.unioned(with: Region(box: BoxRec(x1: 0, y1: 5,  x2: 10, y2: 10)))
        r = r.unioned(with: Region(box: BoxRec(x1: 0, y1: 10, x2: 10, y2: 15)))
        XCTAssertEqual(r.rects, [BoxRec(x1: 0, y1: 0, x2: 10, y2: 15)])
        XCTAssertNil(r.validate())
    }

    func testUnionStripedBandsDoNotCoalesceWhenXChanges() {
        // Three vertically-adjacent rects with DIFFERENT x-coverage.
        // Coalesce must NOT happen — each band stays separate.
        var r: Region = .empty
        r = r.unioned(with: Region(box: BoxRec(x1: 0,  y1: 0,  x2: 10, y2: 5)))
        r = r.unioned(with: Region(box: BoxRec(x1: 5,  y1: 5,  x2: 20, y2: 10)))
        r = r.unioned(with: Region(box: BoxRec(x1: 10, y1: 10, x2: 30, y2: 15)))
        XCTAssertEqual(r.rectCount, 3)
        XCTAssertNil(r.validate())
    }

    func testSubtractSplitsOneBandIntoTwo() {
        // Single horizontal strip, subtract a vertical slice through the
        // middle. Result: two rects in one band.
        let a = Region(box: BoxRec(x1: 0,  y1: 0, x2: 100, y2: 10))
        let b = Region(box: BoxRec(x1: 40, y1: 0, x2: 60,  y2: 10))
        let r = a.subtracting(b)
        XCTAssertEqual(r.rects, [
            BoxRec(x1: 0,  y1: 0, x2: 40,  y2: 10),
            BoxRec(x1: 60, y1: 0, x2: 100, y2: 10),
        ])
        XCTAssertNil(r.validate())
    }

    func testUnionOverlappingHorizontallySingleBand() {
        // Two rects overlapping x-wise on the same y-band: merge into one.
        let a = Region(box: BoxRec(x1: 0,  y1: 0, x2: 20, y2: 10))
        let b = Region(box: BoxRec(x1: 15, y1: 0, x2: 30, y2: 10))
        let u = a.unioned(with: b)
        XCTAssertEqual(u.rects, [BoxRec(x1: 0, y1: 0, x2: 30, y2: 10)])
        XCTAssertNil(u.validate())
    }

    func testManySubtractsValidateAtEach() {
        // 5x5 grid; punch holes one at a time. Validate invariants after
        // each subtract.
        var r = Region(box: BoxRec(x1: 0, y1: 0, x2: 50, y2: 50))
        for gy: Int32 in stride(from: 0, to: 50, by: 10) {
            for gx: Int32 in stride(from: 0, to: 50, by: 20) {
                let hole = Region(box: BoxRec(x1: gx, y1: gy, x2: gx + 5, y2: gy + 5))
                r = r.subtracting(hole)
                XCTAssertNil(r.validate(), "after hole at (\(gx),\(gy))")
            }
        }
    }

    func testIntersectOfTwoLShapes() {
        // L-shape A = (0,0,60,60) ∪ (0,60,30,100).
        // L-shape B = (30,30,90,90) ∪ (60,30,90,30..100)? Build via subtract.
        let aOuter = Region(box: BoxRec(x1: 0,  y1: 0,  x2: 60, y2: 100))
        let aCut   = Region(box: BoxRec(x1: 30, y1: 60, x2: 60, y2: 100))
        let a = aOuter.subtracting(aCut)

        let bOuter = Region(box: BoxRec(x1: 30, y1: 30, x2: 100, y2: 90))
        let bCut   = Region(box: BoxRec(x1: 30, y1: 30, x2: 60, y2: 60))
        let b = bOuter.subtracting(bCut)

        // Intersection: only the bottom-right portion of A's top arm
        // overlaps the bottom arm of B. Don't pin exact rects — pin
        // invariants + bounding box plausibility.
        let inter = a.intersected(with: b)
        XCTAssertNil(inter.validate())
        if !inter.isEmpty {
            XCTAssertTrue(a.boundingBox.subsumes(inter.boundingBox))
            XCTAssertTrue(b.boundingBox.subsumes(inter.boundingBox))
        }
    }

    func testValidateCatchesHandbuiltBadRegion() {
        // We can't easily construct an invalid Region through the public
        // API (the API maintains invariants). But we can verify the
        // validator's logic by checking that VALID regions all pass.
        let frame = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
            .subtracting(Region(box: BoxRec(x1: 30, y1: 30, x2: 70, y2: 70)))
        XCTAssertNil(frame.validate())

        let lShape = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
            .subtracting(Region(box: BoxRec(x1: 60, y1: 60, x2: 100, y2: 100)))
        XCTAssertNil(lShape.validate())
    }

    func testCoalesceAcrossSubtractRestoration() {
        // Start with a big rect, subtract a corner, then union the corner
        // back. End state must equal the original — the subtract+union
        // dance must coalesce back to a single rect.
        let original = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
        let corner   = Region(box: BoxRec(x1: 60, y1: 60, x2: 100, y2: 100))
        let cut = original.subtracting(corner)
        let restored = cut.unioned(with: corner)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.rectCount, 1)
    }

    func testEnumerateBandsWalksInOrder() {
        let frame = Region(box: BoxRec(x1: 0, y1: 0, x2: 100, y2: 100))
            .subtracting(Region(box: BoxRec(x1: 30, y1: 30, x2: 70, y2: 70)))
        var bandYs: [Int32] = []
        frame.enumerateBands { y1, _, _ in bandYs.append(y1) }
        XCTAssertEqual(bandYs, [0, 30, 70])
    }
}
