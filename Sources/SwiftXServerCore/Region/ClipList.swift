// ClipList recomputation. The X11R6 reference is mi/mivaltree.c
// (miComputeClips, lines 158-477) which is structured around in-place
// region operations on a stacking-aware sibling list. Our model is
// simpler in three ways:
//
//   1. Rootless: we don't model overlap between top-levels (macOS handles
//      that). Each top-level subtree is computed independently.
//   2. No stacking among siblings yet (Step D's territory). All mapped
//      children are treated as obscuring their parent without ordering.
//   3. We recompute the full affected top-level subtree on every mutation
//      rather than the surgical-update approach miComputeClips uses. For
//      our scale (deepest dt-Motif subtree ≈ 200 windows) this stays
//      cheap; if it doesn't, the incremental path is the next move.
//
// Output: writes `clipList` and `borderClip` on every WindowEntry in the
// subtree. Both regions are in TOP-LEVEL-LOCAL coordinates, which is the
// same coordinate space the bridge's paintWindowRects expects.

public enum ClipListEngine {

    /// Recompute clipList + borderClip for the top-level `topId` and every
    /// window in its subtree. Call after any mutation that could affect
    /// the visible-region tree (map, unmap, configure, destroy, reparent).
    ///
    /// If `topId` doesn't refer to a known top-level, no-ops. (Handlers
    /// resolve the top-level from the mutated window before calling.)
    public static func recomputeClips(forTopLevel topId: UInt32, in windows: WindowTable) {
        guard let entry = windows.get(topId) else { return }
        let bw = Int32(entry.borderWidth)
        // For a top-level, the parent-visible region is the top-level's
        // own full border-included extent. The intersect-with-borderBox
        // in the recursion yields borderClip == borderBox, which is what
        // we want for the root of the subtree.
        let topBorderBox = BoxRec(
            x1: -bw, y1: -bw,
            x2: Int32(entry.width) + bw,
            y2: Int32(entry.height) + bw
        )
        recomputeSubtree(
            topId,
            parentVisible: Region(box: topBorderBox),
            in: windows,
            baseDx: 0, baseDy: 0
        )
    }

    /// Recurse for one window. `parentVisible` is the region (in top-level
    /// coords) within which this window is allowed to be visible — for
    /// the top-level this is its own border-box; for a descendant this is
    /// the parent's clipList after subtracting earlier-processed siblings.
    /// `baseDx`/`baseDy` is this window's origin in top-level coords.
    private static func recomputeSubtree(
        _ windowId: UInt32,
        parentVisible: Region,
        in windows: WindowTable,
        baseDx: Int32, baseDy: Int32
    ) {
        guard let entry = windows.get(windowId) else { return }

        // Unmapped windows have empty clip regions. Children of an
        // unmapped window are also empty (unviewable per X spec).
        if !entry.mapped {
            windows.setClipList(windowId, .empty)
            windows.setBorderClip(windowId, .empty)
            for childId in directChildren(of: windowId, in: windows) {
                recomputeSubtree(childId, parentVisible: .empty, in: windows,
                                 baseDx: 0, baseDy: 0)
            }
            return
        }

        let bw = Int32(entry.borderWidth)
        let interiorBox = BoxRec(
            x1: baseDx, y1: baseDy,
            x2: baseDx + Int32(entry.width),
            y2: baseDy + Int32(entry.height)
        )
        let borderBox = BoxRec(
            x1: interiorBox.x1 - bw, y1: interiorBox.y1 - bw,
            x2: interiorBox.x2 + bw, y2: interiorBox.y2 + bw
        )

        let borderClip = parentVisible.intersected(with: Region(box: borderBox))
        var clipList = parentVisible.intersected(with: Region(box: interiorBox))

        // Mapped children obscure this window's interior. Process each:
        // recurse to compute the child's regions, then subtract its
        // borderClip from our clipList so subsequent siblings (and our
        // own final clipList) reflect the obscured area.
        //
        // No stacking awareness yet — siblings processed in dictionary
        // iteration order. For non-overlapping toolkit widget layouts
        // this is correct regardless of order. Overlap + Z-order is
        // Step D's job.
        for childId in directChildren(of: windowId, in: windows) {
            guard let childEntry = windows.get(childId) else { continue }
            if !childEntry.mapped {
                // Unmapped child: clear its (and descendants') clips and
                // move on without affecting our clipList.
                recomputeSubtree(childId, parentVisible: .empty, in: windows,
                                 baseDx: 0, baseDy: 0)
                continue
            }
            let childBaseDx = baseDx + Int32(childEntry.x)
            let childBaseDy = baseDy + Int32(childEntry.y)
            recomputeSubtree(childId, parentVisible: clipList, in: windows,
                             baseDx: childBaseDx, baseDy: childBaseDy)
            if let updated = windows.get(childId) {
                clipList = clipList.subtracting(updated.borderClip)
            }
        }

        windows.setClipList(windowId, clipList)
        windows.setBorderClip(windowId, borderClip)
    }

    /// Direct children of `id` (parent == id), in ascending id order.
    /// Sorting matters because the recursion subtracts each child's
    /// borderClip from a running parent-visible region — different
    /// orderings produce identical results only when siblings are
    /// non-overlapping. Dictionary iteration is unordered, so without
    /// sorting we'd see non-deterministic clipList output (caught
    /// 2026-05-13 against xcalc replay: same input produced 42-49
    /// Expose events across runs). Sort-by-id is a stable approximation
    /// of "creation order" until Step D introduces real X stacking.
    private static func directChildren(of id: UInt32, in windows: WindowTable) -> [UInt32] {
        var out: [UInt32] = []
        for (cid, w) in windows.windows where w.parent == id {
            out.append(cid)
        }
        out.sort()
        return out
    }
}
