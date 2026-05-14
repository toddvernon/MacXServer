// Debug helpers for Region: human-readable description, an invariant
// validator (the equivalent of mi/miregion.c:miValidRegion at lines
// 241-284), and a band enumerator used by tests.

extension BoxRec: CustomStringConvertible {
    public var description: String {
        "Box(\(x1),\(y1)..\(x2),\(y2) \(width)x\(height))"
    }
}

extension Region: CustomStringConvertible {
    public var description: String {
        if isEmpty { return "Region.empty" }
        return "Region(\(rectCount) rects, extents=\(extents)):\n" +
            rects.map { "  \($0)" }.joined(separator: "\n")
    }
}

extension Region {

    /// Walk the rect list as a sequence of bands. Each band is a
    /// (y1, y2, [rects]) tuple. Useful for tests that want to assert on
    /// band structure rather than the flat rect list.
    public func enumerateBands(_ body: (Int32, Int32, [BoxRec]) -> Void) {
        let all = rects
        var i = 0
        while i < all.count {
            let y1 = all[i].y1
            let y2 = all[i].y2
            var j = i + 1
            while j < all.count && all[j].y1 == y1 {
                j += 1
            }
            body(y1, y2, Array(all[i..<j]))
            i = j
        }
    }

    /// Reasons a region might fail validation. Returned by `validate()`
    /// so tests can assert specific failure modes; production code can
    /// just check for nil.
    public enum InvariantViolation: Equatable {
        case rectHasInverseDimensions(BoxRec)
        case rectsNotSortedYThenX(BoxRec, BoxRec)
        case bandRectsTouchOrOverlap(BoxRec, BoxRec)
        case mixedY2WithinBand(BoxRec, BoxRec)
        case bandsCouldBeCoalesced(prevY: Int32, curY: Int32)
        case extentsDontMatchBoundingBox(stored: BoxRec, actual: BoxRec)
    }

    /// Check all the invariants Region promises. Returns nil if the
    /// region is well-formed, otherwise the first violation found.
    /// Used in tests; production code can call `assert(region.validate() == nil)`.
    public func validate() -> InvariantViolation? {
        if isEmpty { return nil }

        let all = rects
        // 1. No inverse-dimension rects.
        for r in all {
            if r.x2 <= r.x1 || r.y2 <= r.y1 {
                return .rectHasInverseDimensions(r)
            }
        }
        // 2. Sorted y1-then-x1, no overlap within band, same y2 within band.
        for i in 0..<(all.count - 1) {
            let a = all[i]
            let b = all[i + 1]
            if b.y1 < a.y1 {
                return .rectsNotSortedYThenX(a, b)
            }
            if b.y1 == a.y1 {
                // Same band.
                if a.y2 != b.y2 {
                    return .mixedY2WithinBand(a, b)
                }
                if b.x1 <= a.x2 {
                    // Per X.org: adjacent rects in a band must NOT touch
                    // (b.x1 < a.x2 is overlap; b.x1 == a.x2 should have
                    // been coalesced into a single rect).
                    return .bandRectsTouchOrOverlap(a, b)
                }
                if b.x1 < a.x1 {
                    return .rectsNotSortedYThenX(a, b)
                }
            }
        }
        // 3. No two adjacent bands could merge (would have been coalesced).
        //    Walk bands; if a band's y1 equals previous band's y2 AND their
        //    x-coverage matches, that's a missed coalesce.
        var bands: [(y1: Int32, y2: Int32, rects: [BoxRec])] = []
        enumerateBands { y1, y2, rs in bands.append((y1, y2, rs)) }
        for i in 0..<(bands.count - 1) {
            let p = bands[i]
            let c = bands[i + 1]
            guard p.y2 == c.y1 else { continue }
            guard p.rects.count == c.rects.count else { continue }
            var allMatch = true
            for k in 0..<p.rects.count {
                if p.rects[k].x1 != c.rects[k].x1 || p.rects[k].x2 != c.rects[k].x2 {
                    allMatch = false
                    break
                }
            }
            if allMatch {
                return .bandsCouldBeCoalesced(prevY: p.y1, curY: c.y1)
            }
        }
        // 4. Extents must match the bounding box of the rects.
        var actual = all[0]
        for r in all.dropFirst() {
            if r.x1 < actual.x1 { actual.x1 = r.x1 }
            if r.y1 < actual.y1 { actual.y1 = r.y1 }
            if r.x2 > actual.x2 { actual.x2 = r.x2 }
            if r.y2 > actual.y2 { actual.y2 = r.y2 }
        }
        if actual != extents {
            return .extentsDontMatchBoundingBox(stored: extents, actual: actual)
        }
        return nil
    }
}
