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
    /// The drawable resolves to a window. `topLevel` is the X id of the
    /// top-level ancestor whose NSWindow owns the backing context;
    /// `offsetX` / `offsetY` translate drawable-local coords to top-level
    /// coords (positive = drawable is inside the top-level by that much).
    case window(topLevel: UInt32, offsetX: Int16, offsetY: Int16)

    /// The drawable resolves to a pixmap. `id` is the X pixmap id;
    /// `depth` is the X-side depth (1 / 8 / 24 / 32) so handlers can
    /// reject depth-mismatched ops with BadMatch.
    case pixmap(id: UInt32, depth: UInt8)
}
