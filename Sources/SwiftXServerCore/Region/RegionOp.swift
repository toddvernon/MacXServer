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
// Band-walk engine for Region union / intersect / subtract.
//
// Direct port of mi/miregion.c:miRegionOp (lines 618-829) and the three
// overlap helpers miIntersectO / miUnionO / miSubtractO. Strategy: walk
// the two source regions' rects in y-order; for each maximal y-band,
// dispatch to the right per-band routine. At band boundaries, attempt to
// coalesce the just-written band with the previous one. The non-trivial
// part is the y-axis bookkeeping when the two regions have bands at
// different y-coordinates — that's miRegionOp's job; the per-op
// difference lives in the overlap function and two flags
// (`appendNon1`/`appendNon2`) controlling whether to keep the
// non-overlapping part of each region.

extension Region {

    // MARK: - Public entry points

    /// Set intersection of this region and `other`. Drives miRegionOp with
    /// the intersect overlap (miregion.c `miIntersect`).
    public func intersected(with other: Region) -> Region {
        // Trivial rejects (miregion.c:962-993).
        if isEmpty || other.isEmpty { return .empty }
        if !extents.overlaps(other.extents) { return .empty }

        // Both single-rect: clip extents directly. miregion.c:972-981.
        if storage == nil && other.storage == nil {
            let clipped = BoxRec(
                x1: max(extents.x1, other.extents.x1),
                y1: max(extents.y1, other.extents.y1),
                x2: min(extents.x2, other.extents.x2),
                y2: min(extents.y2, other.extents.y2)
            )
            return Region(box: clipped)
        }
        // One side single-rect that subsumes the other → return the multi.
        // miregion.c:982-989.
        if other.storage == nil && other.extents.subsumes(extents) { return self }
        if storage == nil && extents.subsumes(other.extents) { return other }

        let builder = RegionOpBuilder()
        miRegionOp(into: builder, r1: self, r2: other,
                   overlap: intersectBand,
                   appendNon1: false, appendNon2: false)
        return builder.finish()
    }

    /// Set union of this region and `other`. Drives miRegionOp with the
    /// union overlap, keeping the non-overlapping bits of both
    /// (miregion.c `miUnion`).
    public func unioned(with other: Region) -> Region {
        // Trivial cases (miregion.c:1118-1163).
        if isEmpty { return other }
        if other.isEmpty { return self }
        if storage == nil && extents.subsumes(other.extents) { return self }
        if other.storage == nil && other.extents.subsumes(extents) { return other }

        let builder = RegionOpBuilder()
        miRegionOp(into: builder, r1: self, r2: other,
                   overlap: unionBand,
                   appendNon1: true, appendNon2: true)
        return builder.finish()
    }

    /// This region minus `other`. Drives miRegionOp with the subtract
    /// overlap, keeping only the non-overlapping bits of self
    /// (miregion.c `miSubtract`).
    public func subtracting(_ other: Region) -> Region {
        // Trivial rejects (miregion.c:1792-1803).
        if isEmpty || other.isEmpty { return self }
        if !extents.overlaps(other.extents) { return self }

        let builder = RegionOpBuilder()
        miRegionOp(into: builder, r1: self, r2: other,
                   overlap: subtractBand,
                   appendNon1: true, appendNon2: false)
        return builder.finish()
    }
}

// MARK: - Generic band-walk driver

/// Faithful Swift port of miRegionOp (miregion.c:618-829). Walks the two
/// regions' rects band-by-band in y-order, dispatching to `overlap` when
/// both regions cover a band and emitting the non-overlapping bits of
/// each region if the corresponding `appendNon` flag is set.
private func miRegionOp(
    into builder: RegionOpBuilder,
    r1 reg1: Region,
    r2 reg2: Region,
    overlap: (RegionOpBuilder, ArraySlice<BoxRec>, ArraySlice<BoxRec>, Int32, Int32) -> Void,
    appendNon1: Bool,
    appendNon2: Bool
) {
    let r1Rects = reg1.rects
    let r2Rects = reg2.rects
    var i1 = 0
    var i2 = 0
    let n1 = r1Rects.count
    let n2 = r2Rects.count

    // Initial ybot = min of the two regions' first-y. See miregion.c:700.
    var ybot: Int32 = min(r1Rects[0].y1, r2Rects[0].y1)

    while i1 < n1 && i2 < n2 {
        // FindBand: scan ahead while y1 stays constant. miregion.c:570-577.
        let r1BandStart = i1
        let r1y1 = r1Rects[i1].y1
        var r1BandEnd = i1 + 1
        while r1BandEnd < n1 && r1Rects[r1BandEnd].y1 == r1y1 { r1BandEnd += 1 }

        let r2BandStart = i2
        let r2y1 = r2Rects[i2].y1
        var r2BandEnd = i2 + 1
        while r2BandEnd < n2 && r2Rects[r2BandEnd].y1 == r2y1 { r2BandEnd += 1 }

        // ytop = top of the upcoming overlap band; updated below.
        let ytop: Int32

        // Handle the non-overlapping band, if any. miregion.c:735-759.
        if r1y1 < r2y1 {
            if appendNon1 {
                let top = max(r1y1, ybot)
                let bot = min(r1Rects[i1].y2, r2y1)
                if top != bot {
                    builder.openBand()
                    appendNonO(into: builder,
                               from: r1Rects[r1BandStart..<r1BandEnd],
                               y1: top, y2: bot)
                    builder.closeBand()
                }
            }
            ytop = r2y1
        } else if r2y1 < r1y1 {
            if appendNon2 {
                let top = max(r2y1, ybot)
                let bot = min(r2Rects[i2].y2, r1y1)
                if top != bot {
                    builder.openBand()
                    appendNonO(into: builder,
                               from: r2Rects[r2BandStart..<r2BandEnd],
                               y1: top, y2: bot)
                    builder.closeBand()
                }
            }
            ytop = r1y1
        } else {
            ytop = r1y1
        }

        // Now the overlap band, if any. miregion.c:765-771.
        ybot = min(r1Rects[i1].y2, r2Rects[i2].y2)
        if ybot > ytop {
            builder.openBand()
            overlap(builder,
                    r1Rects[r1BandStart..<r1BandEnd],
                    r2Rects[r2BandStart..<r2BandEnd],
                    ytop, ybot)
            builder.closeBand()
        }

        // Advance whichever region(s) have finished this band. miregion.c:777-778.
        if r1Rects[i1].y2 == ybot { i1 = r1BandEnd }
        if r2Rects[i2].y2 == ybot { i2 = r2BandEnd }
    }

    // Trailing tail: at most one region has remaining rects.
    if i1 < n1 && appendNon1 {
        // First leftover band may be coalescable. miregion.c:790-797.
        let r1y1 = r1Rects[i1].y1
        var r1BandEnd = i1 + 1
        while r1BandEnd < n1 && r1Rects[r1BandEnd].y1 == r1y1 { r1BandEnd += 1 }
        builder.openBand()
        appendNonO(into: builder,
                   from: r1Rects[i1..<r1BandEnd],
                   y1: max(r1y1, ybot), y2: r1Rects[i1].y2)
        builder.closeBand()
        // Remaining bands appended wholesale, no coalesce attempts beyond
        // the first (matches miregion.c:797 AppendRegions). They're already
        // properly banded so we just copy.
        if r1BandEnd < n1 {
            builder.appendRaw(r1Rects[r1BandEnd..<n1])
        }
    } else if i2 < n2 && appendNon2 {
        let r2y1 = r2Rects[i2].y1
        var r2BandEnd = i2 + 1
        while r2BandEnd < n2 && r2Rects[r2BandEnd].y1 == r2y1 { r2BandEnd += 1 }
        builder.openBand()
        appendNonO(into: builder,
                   from: r2Rects[i2..<r2BandEnd],
                   y1: max(r2y1, ybot), y2: r2Rects[i2].y2)
        builder.closeBand()
        if r2BandEnd < n2 {
            builder.appendRaw(r2Rects[r2BandEnd..<n2])
        }
    }
}

// MARK: - Per-band overlap functions

/// Intersect overlap. Walks both bands in lockstep, emitting the x-overlap
/// of each pair. miregion.c:miIntersectO (lines 906-950).
private func intersectBand(
    _ builder: RegionOpBuilder,
    _ r1Band: ArraySlice<BoxRec>,
    _ r2Band: ArraySlice<BoxRec>,
    _ y1: Int32, _ y2: Int32
) {
    var i1 = r1Band.startIndex
    var i2 = r2Band.startIndex
    let e1 = r1Band.endIndex
    let e2 = r2Band.endIndex
    while i1 < e1 && i2 < e2 {
        let a = r1Band[i1]
        let b = r2Band[i2]
        let x1 = max(a.x1, b.x1)
        let x2 = min(a.x2, b.x2)
        if x1 < x2 {
            builder.append(BoxRec(x1: x1, y1: y1, x2: x2, y2: y2))
        }
        // Advance whichever has the leftmost right edge.
        if a.x2 == x2 { i1 += 1 }
        if b.x2 == x2 { i2 += 1 }
    }
}

/// Union overlap. miregion.c:miUnionO (lines 1043-1100). Maintains a
/// running (x1, x2) for the rect being built; absorbs the next-leftmost
/// rect from r1 or r2 into the running pair (extending x2 if they touch
/// or overlap) or flushes the running pair and starts a new one. Emits
/// at the end.
private func unionBand(
    _ builder: RegionOpBuilder,
    _ r1Band: ArraySlice<BoxRec>,
    _ r2Band: ArraySlice<BoxRec>,
    _ y1: Int32, _ y2: Int32
) {
    var i1 = r1Band.startIndex
    var i2 = r2Band.startIndex
    let e1 = r1Band.endIndex
    let e2 = r2Band.endIndex

    var curX1: Int32
    var curX2: Int32
    if r1Band[i1].x1 < r2Band[i2].x1 {
        curX1 = r1Band[i1].x1; curX2 = r1Band[i1].x2; i1 += 1
    } else {
        curX1 = r2Band[i2].x1; curX2 = r2Band[i2].x2; i2 += 1
    }

    func merge(_ r: BoxRec) {
        if r.x1 <= curX2 {
            if curX2 < r.x2 { curX2 = r.x2 }
        } else {
            builder.append(BoxRec(x1: curX1, y1: y1, x2: curX2, y2: y2))
            curX1 = r.x1; curX2 = r.x2
        }
    }

    while i1 < e1 && i2 < e2 {
        if r1Band[i1].x1 < r2Band[i2].x1 {
            merge(r1Band[i1]); i1 += 1
        } else {
            merge(r2Band[i2]); i2 += 1
        }
    }
    while i1 < e1 { merge(r1Band[i1]); i1 += 1 }
    while i2 < e2 { merge(r2Band[i2]); i2 += 1 }
    builder.append(BoxRec(x1: curX1, y1: y1, x2: curX2, y2: y2))
}

/// Subtract overlap. miregion.c:miSubtractO (lines 1657-1763). r1 is the
/// minuend, r2 is the subtrahend. For each minuend rect, walk the
/// subtrahend rects within the band and emit pieces of the minuend that
/// aren't covered.
private func subtractBand(
    _ builder: RegionOpBuilder,
    _ r1Band: ArraySlice<BoxRec>,
    _ r2Band: ArraySlice<BoxRec>,
    _ y1: Int32, _ y2: Int32
) {
    var i1 = r1Band.startIndex
    var i2 = r2Band.startIndex
    let e1 = r1Band.endIndex
    let e2 = r2Band.endIndex
    if i1 == e1 { return }
    var x1: Int32 = r1Band[i1].x1

    while i1 < e1 && i2 < e2 {
        let r1 = r1Band[i1]
        let r2 = r2Band[i2]
        if r2.x2 <= x1 {
            // Subtrahend entirely left of minuend; advance.
            i2 += 1
        } else if r2.x1 <= x1 {
            // Subtrahend covers minuend's left edge.
            x1 = r2.x2
            if x1 >= r1.x2 {
                i1 += 1
                if i1 < e1 { x1 = r1Band[i1].x1 }
            } else {
                i2 += 1
            }
        } else if r2.x1 < r1.x2 {
            // Subtrahend's left covers part of minuend's interior; emit
            // the uncovered left piece.
            builder.append(BoxRec(x1: x1, y1: y1, x2: r2.x1, y2: y2))
            x1 = r2.x2
            if x1 >= r1.x2 {
                i1 += 1
                if i1 < e1 { x1 = r1Band[i1].x1 }
            } else {
                i2 += 1
            }
        } else {
            // Minuend ends before subtrahend starts; emit any tail.
            if r1.x2 > x1 {
                builder.append(BoxRec(x1: x1, y1: y1, x2: r1.x2, y2: y2))
            }
            i1 += 1
            if i1 < e1 { x1 = r1Band[i1].x1 }
        }
    }
    // Remaining minuend rects → emit verbatim.
    while i1 < e1 {
        let r1 = r1Band[i1]
        builder.append(BoxRec(x1: x1, y1: y1, x2: r1.x2, y2: y2))
        i1 += 1
        if i1 < e1 { x1 = r1Band[i1].x1 }
    }
}

/// Non-overlapping band: clip each rect's y to [y1, y2) and append.
/// miregion.c:miAppendNonO (lines 541-568).
private func appendNonO(
    into builder: RegionOpBuilder,
    from band: ArraySlice<BoxRec>,
    y1: Int32, y2: Int32
) {
    for r in band {
        builder.append(BoxRec(x1: r.x1, y1: y1, x2: r.x2, y2: y2))
    }
}

// MARK: - RegionOpBuilder

/// Accumulator for miRegionOp output. Tracks prev-band start so we can
/// coalesce touching y-bands with identical x-coverage (miregion.c
/// miCoalesce, lines 456-512).
private final class RegionOpBuilder {
    private(set) var rects: [BoxRec] = []
    private var prevBandStart: Int = 0
    private var curBandStart: Int = 0

    init() {
        rects.reserveCapacity(8)
    }

    /// Mark the start of a new band before appending its rects.
    func openBand() {
        curBandStart = rects.count
    }

    /// Append one rect within the current band.
    func append(_ r: BoxRec) {
        // X.org's NEWRECT also coalesces horizontally within a band:
        // if the new rect touches/overlaps the previous one in the same
        // band, extend the previous rect instead of starting a new one.
        // This matters because miUnionO can produce adjacent runs.
        if rects.count > curBandStart {
            let last = rects.count - 1
            if rects[last].y1 == r.y1 && rects[last].y2 == r.y2 && rects[last].x2 >= r.x1 {
                if rects[last].x2 < r.x2 { rects[last].x2 = r.x2 }
                return
            }
        }
        rects.append(r)
    }

    /// End the current band; attempt vertical coalesce with the previous one.
    func closeBand() {
        if curBandStart == rects.count {
            return // no rects added this band
        }
        coalesce()
    }

    /// Append a slice of pre-banded rects in one shot. Used for the
    /// AppendRegions tail step. Does NOT attempt any coalesce — caller
    /// guarantees these are valid bands.
    func appendRaw(_ slice: ArraySlice<BoxRec>) {
        rects.append(contentsOf: slice)
        prevBandStart = rects.count // can't coalesce further
        curBandStart = rects.count
    }

    func finish() -> Region {
        return Region(rectsTrusted: rects)
    }

    /// Vertical band coalesce: if the previous band and the current
    /// band have the same number of rects with matching x1/x2 across
    /// pairs, and the previous band's y2 equals the current band's y1,
    /// extend each prev-band rect's y2 down to the current band's y2
    /// and discard the current band's rects.
    private func coalesce() {
        let curCount = rects.count - curBandStart
        let prevCount = curBandStart - prevBandStart
        if curCount == 0 || prevCount != curCount {
            prevBandStart = curBandStart
            return
        }
        // Check y-adjacency.
        if rects[prevBandStart].y2 != rects[curBandStart].y1 {
            prevBandStart = curBandStart
            return
        }
        // Check that x-coverage matches across the pair.
        for k in 0..<curCount {
            let p = rects[prevBandStart + k]
            let c = rects[curBandStart + k]
            if p.x1 != c.x1 || p.x2 != c.x2 {
                prevBandStart = curBandStart
                return
            }
        }
        // Merge: extend each prev-band rect's y2 down, drop current band.
        let newY2 = rects[curBandStart].y2
        for k in 0..<curCount {
            rects[prevBandStart + k].y2 = newY2
        }
        rects.removeLast(curCount)
        // prevBandStart stays put (current band absorbed into previous).
    }
}
