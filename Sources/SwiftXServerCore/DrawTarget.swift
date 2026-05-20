// What a drawing opcode resolves its `drawable` argument to. Windows live
// in NSWindow-backed CGContexts and need a (dx, dy) translation from
// drawable-local to top-level coords. Pixmaps live in their own
// CGBitmapContext (one per pixmap, allocated by PixmapTable) and use
// drawable-local coords directly. The bridge's withDrawContext helper
// hides the difference from each drawXxx body.
//
// validateDrawTarget in ServerSession resolves the X drawable to one of
// these. nil return = already-emitted XError (bad drawable id, etc.) —
// handler bails. Pre-existing comment in validateDrawTarget about the
// "silent drop for pixmap targets" SHORTCUT goes away as Stage 1 lands.

public enum DrawTarget: Equatable, Sendable {
    /// The drawable resolves to a window. `id` is the X window id of the
    /// drawable itself (lets the bridge look up the window's clipList for
    /// composite-clip computation; X.org's miComputeCompositeClip in
    /// mi/migc.c intersects every per-op draw with pWin->clipList).
    /// `topLevel` is the X id of the top-level ancestor whose NSWindow
    /// owns the backing context; `offsetX` / `offsetY` translate
    /// drawable-local coords to top-level coords (positive = drawable
    /// is inside the top-level by that much).
    case window(id: UInt32, topLevel: UInt32, offsetX: Int16, offsetY: Int16)

    /// The drawable resolves to a pixmap. `id` is the X pixmap id;
    /// `depth` is the X-side depth (1 / 8 / 24 / 32) so handlers can
    /// reject depth-mismatched ops with BadMatch.
    case pixmap(id: UInt32, depth: UInt8)

    /// (dx, dy) to add to drawable-local coordinates to reach the
    /// coordinate space the bridge draws in. For window targets that's
    /// the top-level NSWindow's backing-context coords (positive when
    /// the drawable is a descendant inset from the top-level). For
    /// pixmap targets it's (0, 0) — pixmap-local IS the bridge's coord
    /// space. Lets handlers translate input geometry unconditionally
    /// instead of branching per case.
    public var windowOffset: (Int16, Int16) {
        if case .window(_, _, let dx, let dy) = self { return (dx, dy) }
        return (0, 0)
    }
}
