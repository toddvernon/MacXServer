// Doubly-linked sibling chain operations for the WindowTable. Mirrors
// R6's `dix/window.c` stacking model (`windowstr.h:101-104`,
// `MoveWindowInStack`, `WhereDoIGoInTheStack`).
//
// The chain is maintained only for windows whose parent is itself in the
// WindowTable — i.e. non-top-levels. Top-levels (parent == rootWindowId)
// have no parent entry to anchor firstChild/lastChild on; AppKit handles
// their stacking via NSWindow ordering. All `link*` / `unlink` / `move*`
// calls here no-op when the parent isn't in the table.
//
// Chain orientation (matches R6 windowstr.h):
//   parent.firstChild → topmost child   (prevSib chain ends here)
//   parent.lastChild  → bottommost child (nextSib chain ends here)
//   w.prevSib         → sibling above w (closer to firstChild)
//   w.nextSib         → sibling below w (closer to lastChild)

import Foundation

public enum SiblingChain {

    /// Insert `id` at the top (firstChild) of `parent`'s child list. Newly
    /// created non-override-redirect windows go here per X spec (and
    /// override-redirect too, since stacking-on-create is a separate notion
    /// from override-redirect, which only controls WM decoration).
    /// No-op if `parent` isn't in the WindowTable (top-levels' parent
    /// is root, which has no entry).
    public static func linkAtTop(_ id: UInt32, parent: UInt32, in windows: WindowTable) {
        guard let p = windows.get(parent) else { return }
        let oldFirst = p.firstChild

        windows.setPrevSib(id, nil)
        windows.setNextSib(id, oldFirst)
        windows.setFirstChild(parent, id)
        if let oldFirst = oldFirst {
            windows.setPrevSib(oldFirst, id)
        } else {
            // No existing children; this window is also the bottom.
            windows.setLastChild(parent, id)
        }
    }

    /// Remove `id` from its parent's child list. Fixes up both ends of
    /// every link. Safe to call on a window that isn't currently in the
    /// chain (no-op). Used by DestroyWindow, ReparentWindow,
    /// MoveWindowInStack.
    public static func unlink(_ id: UInt32, in windows: WindowTable) {
        guard let w = windows.get(id) else { return }
        guard let parent = windows.get(w.parent) else {
            // Top-level (no parent entry); nothing chained.
            windows.setPrevSib(id, nil)
            windows.setNextSib(id, nil)
            return
        }

        // Splice the neighbors past us.
        if let prev = w.prevSib {
            windows.setNextSib(prev, w.nextSib)
        } else if parent.firstChild == id {
            // We were the topmost child.
            windows.setFirstChild(w.parent, w.nextSib)
        }

        if let next = w.nextSib {
            windows.setPrevSib(next, w.prevSib)
        } else if parent.lastChild == id {
            // We were the bottommost child.
            windows.setLastChild(w.parent, w.prevSib)
        }

        windows.setPrevSib(id, nil)
        windows.setNextSib(id, nil)
    }

    /// Place `id` immediately above `sibling` in the chain (`id` becomes
    /// sibling.prevSib; sibling becomes id.nextSib). Both must currently
    /// be unlinked from any stale neighbor wiring on `id`'s side — call
    /// `unlink(id)` first. Used by MoveWindowInStack after WhereDoIGo
    /// resolves the target neighbor.
    public static func linkAbove(_ id: UInt32, sibling: UInt32, in windows: WindowTable) {
        guard let sib = windows.get(sibling) else { return }
        let parentId = sib.parent
        guard windows.get(parentId) != nil else { return }
        let above = sib.prevSib

        windows.setPrevSib(id, above)
        windows.setNextSib(id, sibling)
        windows.setPrevSib(sibling, id)
        if let above = above {
            windows.setNextSib(above, id)
        } else {
            // sibling was the topmost; id takes its place.
            windows.setFirstChild(parentId, id)
        }
    }

    /// Place `id` at the bottom (lastChild) of `parent`'s child list.
    /// `id` should already be unlinked from any old position.
    public static func linkAtBottom(_ id: UInt32, parent: UInt32, in windows: WindowTable) {
        guard let p = windows.get(parent) else { return }
        let oldLast = p.lastChild

        windows.setNextSib(id, nil)
        windows.setPrevSib(id, oldLast)
        windows.setLastChild(parent, id)
        if let oldLast = oldLast {
            windows.setNextSib(oldLast, id)
        } else {
            windows.setFirstChild(parent, id)
        }
    }

    /// All direct children of `parent`, in stack order (top to bottom —
    /// firstChild first). Replacement for the prior dict-scan-and-sort
    /// approximation. When `parent` isn't in the table (i.e. it's the root)
    /// falls back to a dict-scan sorted by id, which is approximately
    /// creation-order for top-levels. AppKit handles real top-level
    /// stacking; this is just a deterministic enumeration for the few
    /// places that walk root's children (QueryTree, cleanup, etc.).
    public static func directChildrenTopFirst(of parent: UInt32, in windows: WindowTable) -> [UInt32] {
        guard let p = windows.get(parent) else {
            // Root case: dict-scan fallback for deterministic enumeration.
            var out: [UInt32] = []
            for (cid, w) in windows.windows where w.parent == parent {
                out.append(cid)
            }
            out.sort()
            return out
        }
        var out: [UInt32] = []
        var cur = p.firstChild
        // Cap iterations defensively against any malformed chain (cycles
        // would hang the server otherwise).
        for _ in 0..<4096 {
            guard let id = cur else { break }
            out.append(id)
            cur = windows.get(id)?.nextSib
        }
        return out
    }

    /// All direct children in bottom-to-top order. QueryTree returns this
    /// order per X spec ("children are listed in bottom-to-top stacking
    /// order"). Reverse of `directChildrenTopFirst`.
    public static func directChildrenBottomFirst(of parent: UInt32, in windows: WindowTable) -> [UInt32] {
        guard let p = windows.get(parent) else {
            var out: [UInt32] = []
            for (cid, w) in windows.windows where w.parent == parent {
                out.append(cid)
            }
            out.sort()
            return out
        }
        var out: [UInt32] = []
        var cur = p.lastChild
        for _ in 0..<4096 {
            guard let id = cur else { break }
            out.append(id)
            cur = windows.get(id)?.prevSib
        }
        return out
    }
}
