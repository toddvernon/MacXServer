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
    /// `scale` is the logical->device multiplier (`ServerConfig.deviceScale`).
    /// Window dimensions (`x`, `y`, `width`, `height`, `borderWidth`) on
    /// `WindowEntry` are stored at X-protocol logical pixels; we multiply
    /// by `scale` at box construction so every region the engine touches
    /// is in DEVICE pixels. The output `clipList` and `borderClip` on every
    /// window are device-coord regions in top-level-device-local coords.
    ///
    /// `entry.boundingShape` and `entry.clipShape` are expected to be in
    /// window-local DEVICE coords (the convention set by phase 3 of
    /// `DEVICE_COORDS_REFACTOR.md`). The translation by `baseDx, baseDy`
    /// (which are already device-coord top-level-local) brings them into
    /// the same frame.
    ///
    /// If `topId` doesn't refer to a known top-level, no-ops. (Handlers
    /// resolve the top-level from the mutated window before calling.)
    public static func recomputeClips(
        forTopLevel topId: UInt32,
        in windows: WindowTable,
        scale: Int32 = 1
    ) {
        guard let entry = windows.get(topId) else { return }
        let bw = Int32(entry.borderWidth) * scale
        // For a top-level, the parent-visible region is the top-level's
        // own full border-included extent. The intersect-with-borderBox
        // in the recursion yields borderClip == borderBox, which is what
        // we want for the root of the subtree.
        let topBorderBox = BoxRec(
            x1: -bw, y1: -bw,
            x2: Int32(entry.width) * scale + bw,
            y2: Int32(entry.height) * scale + bw
        )
        recomputeSubtree(
            topId,
            parentVisible: Region(box: topBorderBox),
            in: windows,
            baseDx: 0, baseDy: 0,
            scale: scale
        )
    }

    /// Recurse for one window. `parentVisible` is the region (in top-level
    /// device coords) within which this window is allowed to be visible.
    /// `baseDx`/`baseDy` is this window's origin in top-level DEVICE coords.
    private static func recomputeSubtree(
        _ windowId: UInt32,
        parentVisible: Region,
        in windows: WindowTable,
        baseDx: Int32, baseDy: Int32,
        scale: Int32
    ) {
        guard let entry = windows.get(windowId) else { return }

        // Unmapped windows have empty clip regions. Children of an
        // unmapped window are also empty (unviewable per X spec).
        if !entry.mapped {
            windows.setClipList(windowId, .empty)
            windows.setBorderClip(windowId, .empty)
            for childId in directChildren(of: windowId, in: windows) {
                recomputeSubtree(childId, parentVisible: .empty, in: windows,
                                 baseDx: 0, baseDy: 0, scale: scale)
            }
            return
        }

        let bw = Int32(entry.borderWidth) * scale
        let interiorBox = BoxRec(
            x1: baseDx, y1: baseDy,
            x2: baseDx + Int32(entry.width) * scale,
            y2: baseDy + Int32(entry.height) * scale
        )
        let borderBox = BoxRec(
            x1: interiorBox.x1 - bw, y1: interiorBox.y1 - bw,
            x2: interiorBox.x2 + bw, y2: interiorBox.y2 + bw
        )

        // SHAPE bounding/clip regions are stored window-local in DEVICE
        // pixels (phase 3). Translate by (baseDx, baseDy) — also device
        // — to bring them into top-level frame. The borderBox/interiorBox
        // intersect that follows is a defensive clamp matching R6's
        // `REGION_UNION(borderSize, winSize)` belt-and-suspenders at
        // `dix/window.c:1604`.
        let boundingClamp: Region = {
            guard let shape = entry.boundingShape else { return Region(box: borderBox) }
            return shape.translated(dx: baseDx, dy: baseDy)
                .intersected(with: Region(box: borderBox))
        }()
        let interiorClamp: Region = {
            guard let shape = entry.clipShape else { return Region(box: interiorBox) }
            return shape.translated(dx: baseDx, dy: baseDy)
                .intersected(with: Region(box: interiorBox))
        }()
        let borderClip = parentVisible.intersected(with: boundingClamp)
        var clipList = parentVisible.intersected(with: interiorClamp)

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
                                 baseDx: 0, baseDy: 0, scale: scale)
                continue
            }
            let childBaseDx = baseDx + Int32(childEntry.x) * scale
            let childBaseDy = baseDy + Int32(childEntry.y) * scale
            recomputeSubtree(childId, parentVisible: clipList, in: windows,
                             baseDx: childBaseDx, baseDy: childBaseDy, scale: scale)
            if let updated = windows.get(childId) {
                clipList = clipList.subtracting(updated.borderClip)
            }
        }

        windows.setClipList(windowId, clipList)
        windows.setBorderClip(windowId, borderClip)
    }

    /// Direct children of `id` in top-to-bottom stack order — topmost
    /// first. Order matters because the recursion subtracts each child's
    /// borderClip from a running parent-visible region: the topmost
    /// sibling sees the full parent area, lower siblings see what's left
    /// after higher siblings' regions are excluded.
    ///
    /// Delegates to `SiblingChain.directChildrenTopFirst`, which walks the
    /// real R6-style sibling chain (firstChild → nextSib → ...) shipped
    /// 2026-05-14. Falls back to dict-scan-sorted-by-id when `id` isn't in
    /// the WindowTable (the root case) — AppKit handles top-level Z-order
    /// in rootless mode, so the fallback is fine for that path.
    private static func directChildren(of id: UInt32, in windows: WindowTable) -> [UInt32] {
        return SiblingChain.directChildrenTopFirst(of: id, in: windows)
    }
}
