import XCTest
@testable import SwiftXServerCore
import Framer
import CoreGraphics

// X11 spec: PolyArc/PolyFillArc.
//   - angle1 is in 64ths of a degree, 0 = east (+x).
//   - angle2 is the signed extent; positive = counterclockwise.
//
// swift-x draws into a FlippedXView (screen-y increases downward), so the
// parametrization in ellipseArcPath subtracts the sin term from cy rather
// than adding it. Pre-2026-05-14 the term was added, which made positive
// angle2 trace clockwise visually and put angle1=90° at south instead of
// north. xclock's face circle wasn't visibly affected (full sweep is
// orientation-invariant), but any partial arc with a non-zero start angle
// would render rotated/mirrored.

final class EllipseArcPathTests: XCTestCase {

    /// Walk a CGPath and return every move/line point in order.
    private func points(of path: CGPath) -> [CGPoint] {
        var out: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint:
                out.append(e.points[0])
            default:
                break
            }
        }
        return out
    }

    func testZeroAngleStartsEast() {
        // angle1=0 is "east" per spec — first point at (cx+rx, cy).
        // 100x100 bounding box at (0,0): center (50,50), radius 50.
        let arc = Arc(x: 0, y: 0, width: 100, height: 100, angle1: 0, angle2: 64 * 90)
        let pts = points(of: ellipseArcPath(arc: arc, includePieCenter: false))
        guard let first = pts.first else { XCTFail("empty path"); return }
        XCTAssertEqual(first.x, 100.0, accuracy: 0.5, "angle1=0 should land at east edge")
        XCTAssertEqual(first.y, 50.0,  accuracy: 0.5, "angle1=0 is on the equator")
    }

    func testNinetyDegreesIsVisuallyNorth() {
        // angle1=90° is "north" per spec. In FlippedXView coords, "north"
        // visually = smaller y. A degenerate arc starting at 90° with
        // angle2=0 (no extent) places its single sample at the start.
        let ninety: Int16 = 64 * 90
        let arc = Arc(x: 0, y: 0, width: 100, height: 100, angle1: ninety, angle2: 1)
        let pts = points(of: ellipseArcPath(arc: arc, includePieCenter: false))
        guard let first = pts.first else { XCTFail("empty path"); return }
        XCTAssertEqual(first.x, 50.0, accuracy: 0.5, "angle1=90° has cos=0; on vertical axis")
        XCTAssertEqual(first.y, 0.0,  accuracy: 0.5,
                       "angle1=90° must render at top edge (y=0), not bottom (y=100). Pre-fix bug placed it at y=100.")
    }

    func testPositiveExtentSweepsCounterclockwise() {
        // Sweep from east (angle1=0) by +90° → end at north (top edge).
        // Sample positive-angle2 midway: at 45° the point is in the
        // upper-right quadrant (x > cx, y < cy in screen coords).
        let arc = Arc(x: 0, y: 0, width: 100, height: 100,
                      angle1: 0, angle2: 64 * 90)
        let pts = points(of: ellipseArcPath(arc: arc, includePieCenter: false))
        guard let mid = pts.dropFirst(pts.count / 2).first,
              let last = pts.last else { XCTFail("short path"); return }
        XCTAssertGreaterThan(mid.x, 50.0, "midpoint should be east of center")
        XCTAssertLessThan(mid.y,    50.0, "midpoint should be visually-north of center (lower y)")
        XCTAssertEqual(last.x, 50.0, accuracy: 1.0, "endpoint at north (x=cx)")
        XCTAssertEqual(last.y, 0.0,  accuracy: 1.0, "endpoint at north (y=top)")
    }

    func testNegativeExtentSweepsClockwise() {
        // From east (angle1=0) with angle2=-90° → end at south (y=100).
        let arc = Arc(x: 0, y: 0, width: 100, height: 100,
                      angle1: 0, angle2: -64 * 90)
        let pts = points(of: ellipseArcPath(arc: arc, includePieCenter: false))
        guard let last = pts.last else { XCTFail("short path"); return }
        XCTAssertEqual(last.x, 50.0,  accuracy: 1.0, "endpoint at south (x=cx)")
        XCTAssertEqual(last.y, 100.0, accuracy: 1.0,
                       "negative angle2 from east must end at south (bottom edge)")
    }

    func testPieCenterStartsAtCenter() {
        // PolyFillArc includes the center as the first point.
        let arc = Arc(x: 20, y: 30, width: 80, height: 60,
                      angle1: 0, angle2: 64 * 90)
        let pts = points(of: ellipseArcPath(arc: arc, includePieCenter: true))
        guard let first = pts.first else { XCTFail("empty path"); return }
        XCTAssertEqual(first.x, 60.0, accuracy: 0.01, "pie center x = x + width/2")
        XCTAssertEqual(first.y, 60.0, accuracy: 0.01, "pie center y = y + height/2")
    }
}
