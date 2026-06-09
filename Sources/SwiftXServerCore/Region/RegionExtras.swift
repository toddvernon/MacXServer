// This file is derived from the X11R6 reference implementation,
// xc/programs/Xserver/mi/miregion.c. The Swift port is Copyright 2026
// Todd Vernon, licensed under Apache-2.0 (see LICENSE). The original
// X Consortium and Digital Equipment Corporation notices below are
// retained as required by the X11 (MIT/X Consortium) license and govern
// the portions derived from miregion.c.
//
// Copyright (c) 1987, 1988, 1989  X Consortium
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
// X CONSORTIUM BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
// AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Except as contained in this notice, the name of the X Consortium shall not be
// used in advertising or otherwise to promote the sale, use or other dealings
// in this Software without prior written authorization from the X Consortium.
//
// Copyright 1987, 1988, 1989 by
// Digital Equipment Corporation, Maynard, Massachusetts.
//
//                         All Rights Reserved
//
// Permission to use, copy, modify, and distribute this software and its
// documentation for any purpose and without fee is hereby granted,
// provided that the above copyright notice appear in all copies and that
// both that copyright notice and this permission notice appear in
// supporting documentation, and that the name of Digital not be
// used in advertising or publicity pertaining to distribution of the
// software without specific, written prior permission.
//
// DIGITAL DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING
// ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL
// DIGITAL BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR
// ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
// WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
// ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS
// SOFTWARE.
//
// ---------------------------------------------------------------------------
//
// Remaining region ops ported from mi/miregion.c that the resize/move
// cascade in miSlideAndSizeWindow needs. Faithful function-for-function
// translations — keep MIT's invariants in the comments, mirror the
// control flow.
//
// Functions ported here:
//   - miInverse                    (miregion.c:1844)
//   - miRegionReset                (miregion.c:2083)
//   - miRectsToRegion              (miregion.c:1561)
//   - miRegionAppend               (miregion.c:1198)
//   - miRegionValidate             (miregion.c:1381) — exposed as `normalized()`
//   - miSetExtents helper          (miregion.c:847)
//
// MIT's `validate` is a structural normalize (sort + scatter + union). We
// already have a `validate()` on Region that returns the first invariant
// violation for tests/asserts — different semantics. Swift name for the
// normalize op is `normalized()` to avoid confusion.

extension Region {

    // MARK: - miInverse — invRect minus region

    /// invRect minus this region. miregion.c:1844 `miInverse`. If the
    /// region's extents don't overlap `invRect`, returns `Region(box:
    /// invRect)` unchanged. Otherwise subtracts the region from a one-
    /// rect region built from `invRect`.
    public func inverse(within invRect: BoxRec) -> Region {
        // Trivial reject (miregion.c:1856-1862).
        if isEmpty || !extents.overlaps(invRect) {
            return Region(box: invRect)
        }
        // The full op: build invReg from invRect, subtract self from it.
        // Equivalent to miregion.c:1864-1881's subtractO + miSetExtents
        // path (subtracting already handles the extents via finish()).
        return Region(box: invRect).subtracting(self)
    }

    // MARK: - miRegionReset — single-rect reset

    /// Reset to a single-rect region. miregion.c:2083 `miRegionReset`.
    /// Empty `box` (zero or negative width/height) yields the empty
    /// region.
    public static func reset(to box: BoxRec) -> Region {
        Region(box: box)
    }

    // MARK: - miRectsToRegion — build from rect array

    /// How `rects(_:rects:)` should treat the input array.
    /// miregion.c:1564 `ctype`. Matches X11 protocol's CT_* constants.
    public enum RectOrderHint: Sendable {
        /// Caller guarantees y-x banded form (sorted top-down,
        /// non-overlapping within band, no coalesce-able adjacent
        /// bands). Trusted path — no validation runs.
        case yxBanded
        /// Caller guarantees sorted by (y1, x1) but bands may need
        /// merging. Calls normalize.
        case yxSorted
        /// No order guarantee. Calls normalize.
        case unsorted
    }

    /// Build a region from an array of rects with an order hint.
    /// miregion.c:1561 `miRectsToRegion`. For `.yxBanded`, trusts the
    /// caller's layout; for `.yxSorted` and `.unsorted`, runs the same
    /// sort+scatter+union normalize that `normalized()` does.
    ///
    /// Empty rects (zero or negative width/height) in the input array
    /// are filtered out, matching miregion.c:1605's `x1 != x2 && y1 != y2`
    /// check.
    public static func rects(_ boxes: [BoxRec], order: RectOrderHint) -> Region {
        // Filter empty boxes upfront. Matches miregion.c:1605.
        let kept = boxes.filter { !$0.isEmpty }
        switch kept.count {
        case 0:
            return .empty
        case 1:
            return Region(box: kept[0])
        default:
            switch order {
            case .yxBanded:
                return Region(rectsTrusted: kept)
            case .yxSorted, .unsorted:
                // Build a raw region first, then normalize. The order
                // hint distinction only matters for performance — both
                // YXSORTED and UNSORTED go through normalize per
                // miregion.c:1619-1623 (the C source treats anything
                // != CT_YXBANDED uniformly through miRegionValidate).
                var raw = Region()
                raw.extents = BoxRec()
                raw.storage = Storage(rects: kept)
                return raw.normalized().region
            }
        }
    }

    // MARK: - miRegionAppend — fast concat

    /// Concatenate `other`'s rects onto this region's. miregion.c:1198
    /// `miRegionAppend`. Returns the new region and a `needsNormalize`
    /// flag — true if the append couldn't be done cleanly and the
    /// caller must run `normalized()` before relying on band structure
    /// or extents. Matches miregion.c:1257's `extents.x2 = extents.x1`
    /// trick for signaling invalid extents.
    ///
    /// Used by the resize-cascade port (`miSlideAndSizeWindow` and
    /// friends) where many small regions get accumulated into one
    /// before a single normalize pass at the end.
    public func appended(_ other: Region) -> (region: Region, needsNormalize: Bool) {
        // miregion.c:1206-1211: if other is single-rect and self is
        // empty, just take other's extents.
        if other.storage == nil && isEmpty {
            return (Region(box: other.extents), false)
        }
        let otherRects = other.rects
        // miregion.c:1213-1215: trivial reject for empty other.
        if otherRects.isEmpty {
            return (self, false)
        }
        let selfRects = rects
        let dnumRects = selfRects.count

        var newRects: [BoxRec] = []
        newRects.reserveCapacity(dnumRects + otherRects.count)
        var newExtents = extents
        var prepend = false
        var consistent = true

        if dnumRects == 0 {
            // miregion.c:1223-1224: self is empty; take other's extents.
            newExtents = other.extents
        } else if extents.x2 > extents.x1 {
            // miregion.c:1225-1258: self has valid extents. Check whether
            // other's first rect comes AFTER self's last (append-mode)
            // or other's last comes BEFORE self's first (prepend-mode);
            // otherwise mark extents invalid.
            let first = otherRects[0]
            let last = selfRects[dnumRects - 1]
            if (first.y1 > last.y2) ||
               (first.y1 == last.y1 && first.y2 == last.y2 && first.x1 > last.x2) {
                // Clean append. miregion.c:1231-1240.
                if other.extents.x1 < newExtents.x1 { newExtents.x1 = other.extents.x1 }
                if other.extents.x2 > newExtents.x2 { newExtents.x2 = other.extents.x2 }
                newExtents.y2 = other.extents.y2
            } else {
                let firstSelf = selfRects[0]
                let lastOther = otherRects[otherRects.count - 1]
                if (firstSelf.y1 > lastOther.y2) ||
                   (firstSelf.y1 == lastOther.y1 && firstSelf.y2 == lastOther.y2 && firstSelf.x1 > lastOther.x2) {
                    // Clean prepend. miregion.c:1245-1255.
                    prepend = true
                    if other.extents.x1 < newExtents.x1 { newExtents.x1 = other.extents.x1 }
                    if other.extents.x2 > newExtents.x2 { newExtents.x2 = other.extents.x2 }
                    newExtents.y1 = other.extents.y1
                } else {
                    // Inconsistent: mark extents invalid. miregion.c:1257.
                    newExtents.x2 = newExtents.x1
                    consistent = false
                }
            }
        }

        // Splice the rect lists in the chosen order. miregion.c:1260-1276.
        if prepend {
            newRects.append(contentsOf: otherRects)
            newRects.append(contentsOf: selfRects)
        } else {
            newRects.append(contentsOf: selfRects)
            newRects.append(contentsOf: otherRects)
        }

        var result = Region()
        result.extents = newExtents
        result.storage = Storage(rects: newRects)
        return (result, !consistent)
    }

    // MARK: - miRegionValidate — sort+scatter+union normalize

    /// Normalize an unsorted / unmerged rect list into a proper y-x
    /// banded region. Faithful port of miregion.c:1381 `miRegionValidate`.
    /// Returns the normalized region and a flag indicating whether ANY
    /// of the input rects overlapped (matches the `*pOverlap` parameter).
    ///
    /// Strategy (miregion.c:1364-1376):
    ///   Step 1. Sort by (y1, x1).
    ///   Step 2. Scatter into the minimum number of proper y-x banded
    ///           regions. If the next rect would force splitting an
    ///           existing band, try the next region; if none fit,
    ///           create a new region.
    ///   Step 3. Binary-merge all N regions into one via miUnion.
    public func normalized() -> (region: Region, overlap: Bool) {
        let allRects = rects
        if allRects.count <= 1 {
            return (self, false)
        }

        // Step 1: sort by (y1, x1). miregion.c:1432.
        let sorted = allRects.sorted {
            if $0.y1 != $1.y1 { return $0.y1 < $1.y1 }
            return $0.x1 < $1.x1
        }

        // Step 2: scatter into the minimum set of valid regions.
        // miregion.c:1437-1514.
        //
        // Each candidate region in `ri` is a (rects, prevBand, curBand)
        // tuple — same shape as miregion.c's `RegionInfo`. prevBand and
        // curBand are indices into the rects array so we can Coalesce on
        // band transitions.
        struct RegionInfo {
            var rects: [BoxRec]
            var extents: BoxRec
            var prevBand: Int
            var curBand: Int
        }
        var ri: [RegionInfo] = [
            RegionInfo(rects: [sorted[0]], extents: sorted[0],
                       prevBand: 0, curBand: 0)
        ]
        var overlap = false

        rectLoop: for i in 1..<sorted.count {
            let box = sorted[i]
            // Look for a region this box can extend cleanly.
            // miregion.c:1460-1494.
            for j in 0..<ri.count {
                let riBox = ri[j].rects[ri[j].rects.count - 1]
                if box.y1 == riBox.y1 && box.y2 == riBox.y2 {
                    // Same band — merge horizontally or append.
                    // miregion.c:1465-1481.
                    if box.x1 <= riBox.x2 {
                        if box.x1 < riBox.x2 { overlap = true }
                        if box.x2 > ri[j].rects[ri[j].rects.count - 1].x2 {
                            ri[j].rects[ri[j].rects.count - 1].x2 = box.x2
                        }
                    } else {
                        ri[j].rects.append(box)
                    }
                    continue rectLoop
                } else if box.y1 >= riBox.y2 {
                    // New band — append + Coalesce prev/cur.
                    // miregion.c:1482-1493.
                    if ri[j].extents.x2 < riBox.x2 { ri[j].extents.x2 = riBox.x2 }
                    if ri[j].extents.x1 > box.x1 { ri[j].extents.x1 = box.x1 }
                    coalesceInPlace(&ri[j].rects,
                                    prevBand: ri[j].prevBand,
                                    curBand: ri[j].curBand)
                    // Recompute curBand after potential coalesce.
                    ri[j].curBand = ri[j].rects.count
                    ri[j].rects.append(box)
                    continue rectLoop
                }
                // Else: this region can't accept the box (would split
                // an existing band). Try the next region.
            }
            // No region fit — make a new one. miregion.c:1497-1512.
            ri.append(RegionInfo(rects: [box], extents: box,
                                 prevBand: 0, curBand: 0))
        }

        // Final pass per region: set extents.y2 + last x2, Coalesce
        // trailing bands. miregion.c:1519-1531.
        for j in 0..<ri.count {
            let last = ri[j].rects[ri[j].rects.count - 1]
            ri[j].extents.y2 = last.y2
            if ri[j].extents.x2 < last.x2 { ri[j].extents.x2 = last.x2 }
            coalesceInPlace(&ri[j].rects,
                            prevBand: ri[j].prevBand,
                            curBand: ri[j].curBand)
        }

        // Step 3: binary-merge the N regions via union. miregion.c:1533-1553.
        var working: [Region] = ri.map { info in
            if info.rects.count == 1 {
                return Region(box: info.rects[0])
            }
            var r = Region()
            r.extents = info.extents
            r.storage = Storage(rects: info.rects)
            return r
        }
        while working.count > 1 {
            let half = working.count / 2
            var merged: [Region] = []
            merged.reserveCapacity(working.count - half)
            // First (working.count & 1) regions pass through unchanged
            // — matches miregion.c:1537's `j = numRI & 1`.
            let passThrough = working.count & 1
            for k in 0..<passThrough {
                merged.append(working[k])
            }
            for k in 0..<half {
                let a = working[passThrough + k]
                let b = working[passThrough + k + half]
                merged.append(a.unioned(with: b))
            }
            working = merged
        }
        return (working[0], overlap)
    }
}

// MARK: - Coalesce helper for normalize

/// In-place band-coalesce used by miRegionValidate's scatter phase.
/// Mirrors `Coalesce` macro (miregion.c:516, expanded inline at 1487 and
/// 1525). If `prevBand..curBand` and `curBand..end` have matching x
/// coverage and touching y bands, fuse them into one.
///
/// Same logic as `RegionOpBuilder.coalesce` in RegionOp.swift; duplicated
/// here so normalize can run on a value-typed [BoxRec] without going
/// through the OpBuilder accumulator.
private func coalesceInPlace(_ rects: inout [BoxRec], prevBand: Int, curBand: Int) {
    let total = rects.count
    let curCount = total - curBand
    let prevCount = curBand - prevBand
    if curCount == 0 || curCount != prevCount { return }
    if rects[prevBand].y2 != rects[curBand].y1 { return }
    for k in 0..<curCount {
        let p = rects[prevBand + k]
        let c = rects[curBand + k]
        if p.x1 != c.x1 || p.x2 != c.x2 { return }
    }
    let newY2 = rects[curBand].y2
    for k in 0..<curCount {
        rects[prevBand + k].y2 = newY2
    }
    rects.removeLast(curCount)
}

// MARK: - Logical <-> device scaling

extension BoxRec {
    /// Multiply every coordinate by `s`. Used when converting a box from
    /// X-protocol logical pixels (the wire format) into device pixels (the
    /// internal coordinate system for all clipping after the device-coord
    /// refactor; see DEVICE_COORDS_REFACTOR.md). `s == 1` is a no-op.
    public func scaledToDevice(by s: Int32) -> BoxRec {
        if s == 1 { return self }
        return BoxRec(x1: x1 * s, y1: y1 * s, x2: x2 * s, y2: y2 * s)
    }

    /// Inverse of `scaledToDevice`: shrink a device-coord box to logical
    /// with floor on the top-left corner (`x1`, `y1`) and ceil on the
    /// bottom-right (`x2`, `y2`). The "conservative" reading: every
    /// logical pixel that has any device-pixel coverage is included.
    /// Used by `ShapeGetRectangles` / `ShapeQueryExtents` when emitting a
    /// reply to a client that expects logical-pixel rectangles.
    public func scaledToLogical(by s: Int32) -> BoxRec {
        if s == 1 { return self }
        // Floor for non-negative is integer division; for negative we
        // round toward -inf so the result represents the logical pixel
        // that contains the device pixel.
        func floorDiv(_ a: Int32, _ b: Int32) -> Int32 {
            let q = a / b
            let r = a % b
            return (r != 0 && (r ^ b) < 0) ? q - 1 : q
        }
        func ceilDiv(_ a: Int32, _ b: Int32) -> Int32 {
            let q = a / b
            let r = a % b
            return (r != 0 && (r ^ b) > 0) ? q + 1 : q
        }
        return BoxRec(
            x1: floorDiv(x1, s), y1: floorDiv(y1, s),
            x2: ceilDiv(x2, s),  y2: ceilDiv(y2, s)
        )
    }
}

extension Region {
    /// Multiply every box by `s`. See `BoxRec.scaledToDevice`. `s == 1` is
    /// a no-op. The y-x banded invariant is preserved under uniform integer
    /// scaling.
    public func scaledToDevice(by s: Int32) -> Region {
        if s == 1 || isEmpty { return self }
        let scaled = rects.map { $0.scaledToDevice(by: s) }
        return Region.rects(scaled, order: .yxBanded)
    }

    /// Inverse of `scaledToDevice`. See `BoxRec.scaledToLogical` for the
    /// floor/ceil convention. The conservative ceil/floor can create
    /// touching/overlapping bands; the `.unsorted` order path through
    /// `Region.rects` runs the normalize step which coalesces them.
    public func scaledToLogical(by s: Int32) -> Region {
        if s == 1 || isEmpty { return self }
        let scaled = rects.map { $0.scaledToLogical(by: s) }
        return Region.rects(scaled, order: .unsorted)
    }
}
