// Region: a set of disjoint axis-aligned rectangles, plus a bounding box.
//
// Ported from X11R6 mi/miregion.c. We follow X.org's "y-x banded" layout:
// rectangles are sorted top y first then left x, and grouped into bands
// (each rect in a band shares y1 and y2). Bands that share x-coverage
// across a touching y-boundary are coalesced. See miregion.c:80-124 for
// the original prose on the invariants. We need the invariants for the
// band-walk algorithms in RegionOp.swift to work — those algorithms are
// faithful ports and depend on it.
//
// Representation matches X.org's tagged-pointer trick (regionstr.h:66-89):
//   - Empty region: `storage == nil`, `extents` is the zero box.
//   - Single-rect region: `storage == nil`, `extents` is the rect.
//   - Multi-rect region: `storage` holds the rect list, `extents` is the
//     bounding box.
//
// The struct is value-typed; the multi-rect storage is a class behind a
// COW handle so copying a Region is cheap and mutation copies the rect
// list only when needed.

public struct BoxRec: Equatable, Hashable, Sendable {
    public var x1: Int32
    public var y1: Int32
    public var x2: Int32
    public var y2: Int32

    public init(x1: Int32, y1: Int32, x2: Int32, y2: Int32) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public init() {
        self.init(x1: 0, y1: 0, x2: 0, y2: 0)
    }

    /// Convenience builder using width/height. Returned box is empty if
    /// width or height is non-positive.
    public static func wh(x: Int32, y: Int32, width: Int32, height: Int32) -> BoxRec {
        BoxRec(x1: x, y1: y, x2: x &+ width, y2: y &+ height)
    }

    public var isEmpty: Bool { x2 <= x1 || y2 <= y1 }
    public var width: Int32 { x2 > x1 ? x2 - x1 : 0 }
    public var height: Int32 { y2 > y1 ? y2 - y1 : 0 }

    /// Half-open containment: point at (x2, *) or (*, y2) is NOT inside.
    /// Matches miregion.c:134-138 INBOX macro.
    public func contains(x: Int32, y: Int32) -> Bool {
        x2 > x && x1 <= x && y2 > y && y1 <= y
    }

    /// True iff this box and `other` share any interior. miregion.c:127-131.
    public func overlaps(_ other: BoxRec) -> Bool {
        !(x2 <= other.x1 || x1 >= other.x2 || y2 <= other.y1 || y1 >= other.y2)
    }

    /// True iff this box fully contains `other`. miregion.c:141-145.
    public func subsumes(_ other: BoxRec) -> Bool {
        x1 <= other.x1 && x2 >= other.x2 && y1 <= other.y1 && y2 >= other.y2
    }
}

/// rectIn(_:) return values. miregion.c:rgnOUT/IN/PART (regionstr.h:55-58).
public enum RectIn: Equatable, Sendable {
    case out         // rect is entirely outside the region
    case fully       // rect is entirely inside the region
    case partially   // rect crosses the region boundary
}

public struct Region: Equatable, Sendable {

    // Internal: bounding box of `rects`. For empty region this is the
    // zero box; for single-rect (storage == nil) this IS the rect.
    var extents: BoxRec

    // Internal: heap-backed rect list for multi-rect regions. nil for
    // empty and single-rect.
    var storage: Storage?

    /// The empty region: contains no points.
    public static let empty = Region()

    /// Build an empty region.
    public init() {
        self.extents = BoxRec()
        self.storage = nil
    }

    /// Build a region containing exactly the given box. If the box is
    /// empty (zero or negative width/height), the resulting region is
    /// also empty.
    public init(box: BoxRec) {
        if box.isEmpty {
            self.extents = BoxRec()
            self.storage = nil
        } else {
            self.extents = box
            self.storage = nil
        }
    }

    /// Build a region from a pre-validated banded rect list. Callers
    /// (mainly RegionOp helpers and validate()) are responsible for
    /// passing a list that satisfies the y-x band invariants. The
    /// bounding box is computed here.
    init(rectsTrusted rects: [BoxRec]) {
        switch rects.count {
        case 0:
            self.extents = BoxRec()
            self.storage = nil
        case 1:
            self.extents = rects[0]
            self.storage = nil
        default:
            var ext = rects[0]
            for r in rects.dropFirst() {
                if r.x1 < ext.x1 { ext.x1 = r.x1 }
                if r.y1 < ext.y1 { ext.y1 = r.y1 }
                if r.x2 > ext.x2 { ext.x2 = r.x2 }
                if r.y2 > ext.y2 { ext.y2 = r.y2 }
            }
            self.extents = ext
            self.storage = Storage(rects: rects)
        }
    }

    /// True iff the region contains no points (no rectangles).
    public var isEmpty: Bool {
        if let s = storage { return s.rects.isEmpty }
        return extents.isEmpty
    }

    /// Bounding box of the region. Zero box for empty regions.
    public var boundingBox: BoxRec { extents }

    /// Number of rectangles in the band representation. Empty = 0, single = 1.
    public var rectCount: Int {
        if let s = storage { return s.rects.count }
        return extents.isEmpty ? 0 : 1
    }

    /// The rectangle list. Allocates an array for the single-rect case;
    /// callers in hot paths can use `withRects` instead. Listed in band
    /// order (y1, then x1).
    public var rects: [BoxRec] {
        if let s = storage { return s.rects }
        return extents.isEmpty ? [] : [extents]
    }

    /// Read the rectangle list without copying for the multi-rect case.
    /// Caller must not retain the buffer past the closure.
    public func withRects<T>(_ body: ([BoxRec]) throws -> T) rethrows -> T {
        if let s = storage { return try body(s.rects) }
        if extents.isEmpty { return try body([]) }
        return try body([extents])
    }

    public func contains(x: Int32, y: Int32) -> Bool {
        if isEmpty { return false }
        if !extents.contains(x: x, y: y) { return false }
        if storage == nil { return true } // single rect == extents
        for r in storage!.rects where r.contains(x: x, y: y) {
            return true
        }
        return false
    }

    /// Classify a box against the region. miregion.c miRectIn.
    public func rectIn(_ box: BoxRec) -> RectIn {
        if isEmpty || box.isEmpty { return .out }
        if !extents.overlaps(box) { return .out }
        if let s = storage {
            // Multi-rect: walk bands. If the box is fully covered by
            // some subset of rects, return .fully; if any rect partially
            // overlaps, return .partially; otherwise .out.
            // The simple O(n) version is fine — our worst-case rect count
            // is small. X.org's miRectIn (miregion.c:1638) does a more
            // careful band-walk for very large regions; revisit if perf
            // ever shows up here.
            var anyOverlap = false
            // Track the y-coverage of the box. If every horizontal scan
            // line of the box is covered by some region rect, .fully;
            // else .partially (given anyOverlap) or .out.
            var coveredY = box.y1
            for r in s.rects where r.overlaps(box) {
                anyOverlap = true
                // For .fully we need r.x1 <= box.x1, r.x2 >= box.x2 at
                // the y-range r covers within [box.y1, box.y2].
                if r.x1 > box.x1 || r.x2 < box.x2 {
                    return .partially
                }
                // r covers the box horizontally on its y-band.
                if r.y1 > coveredY {
                    // Gap between previous coverage and this rect.
                    return .partially
                }
                if r.y2 > coveredY {
                    coveredY = r.y2
                }
                if coveredY >= box.y2 { return .fully }
            }
            return anyOverlap ? .partially : .out
        } else {
            // Single-rect region: just check subsumption.
            return extents.subsumes(box) ? .fully : .partially
        }
    }

    /// Translate by (dx, dy). Allocates a new Region; original unchanged.
    public func translated(dx: Int32, dy: Int32) -> Region {
        if isEmpty { return self }
        if dx == 0 && dy == 0 { return self }
        let newExt = BoxRec(
            x1: extents.x1 &+ dx, y1: extents.y1 &+ dy,
            x2: extents.x2 &+ dx, y2: extents.y2 &+ dy
        )
        if storage == nil {
            return Region(box: newExt)
        }
        let newRects = storage!.rects.map {
            BoxRec(x1: $0.x1 &+ dx, y1: $0.y1 &+ dy,
                   x2: $0.x2 &+ dx, y2: $0.y2 &+ dy)
        }
        var r = Region()
        r.extents = newExt
        r.storage = Storage(rects: newRects)
        return r
    }

    // MARK: - Equatable

    public static func == (lhs: Region, rhs: Region) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return true }
        if lhs.isEmpty != rhs.isEmpty { return false }
        if lhs.extents != rhs.extents { return false }
        return lhs.rects == rhs.rects
    }
}

/// Multi-rect rect-list storage behind Region's COW handle. Internal —
/// callers go through Region's API. Final class so reference counting is
/// straightforward; marked @unchecked Sendable because the struct only
/// reads through it (mutation is gated by isKnownUniquelyReferenced when
/// we add mutating operations).
final class Storage: @unchecked Sendable {
    var rects: [BoxRec]
    init(rects: [BoxRec]) { self.rects = rects }
}
