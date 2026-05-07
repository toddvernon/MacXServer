import AppKit
import CoreGraphics

// NSView subclass that:
//   * uses X11's top-left origin convention (isFlipped = true) so X coords
//     pass through unchanged
//   * holds a CGBitmapContext sized at logical*scale device pixels (the
//     "device" coordinate space per RENDERING_DESIGN.md commitment 11)
//   * has a pre-applied CGAffineTransform on the backing context so
//     drawing requests issued in X-logical coordinates land at the right
//     device-pixel positions, and the y-axis is top-down
//   * blits the dirty rect to the screen in draw(_:)
//
// One NSView per top-level X window; drawing for any X subwindow in that
// subtree clips against the subwindow's geometry and writes into this
// single backing context.

public final class FlippedXView: NSView {

    /// CGBitmapContext sized at `logicalWidth * scale × logicalHeight * scale`.
    /// The CGContext has a pre-applied transform so callers can issue draw
    /// commands in logical coordinates — the transform handles the scale-up
    /// and the y-flip.
    public var backing: CGContext?

    /// Logical X-protocol dimensions (what the client sees).
    public private(set) var logicalWidth: Int = 0
    public private(set) var logicalHeight: Int = 0

    /// Device-pixel dimensions of the backing bitmap. = logical × scale.
    public private(set) var backingWidth: Int = 0
    public private(set) var backingHeight: Int = 0

    /// Integer scale factor: 1 logical pixel = `scale` device pixels.
    public private(set) var scaleFactor: Int = 1

    public override var isFlipped: Bool { true }

    /// Allocate (or re-allocate) the backing CGBitmapContext at
    /// `logicalWidth * scale × logicalHeight * scale` device pixels and
    /// install the logical-to-device transform. Old backing contents are
    /// discarded — caller is responsible for issuing Expose so the client
    /// repaints.
    public func resizeBacking(logicalWidth: Int, logicalHeight: Int, scale: Int) {
        guard logicalWidth > 0, logicalHeight > 0, scale > 0 else { return }
        let deviceWidth = logicalWidth * scale
        let deviceHeight = logicalHeight * scale

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = deviceWidth * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: deviceWidth, height: deviceHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return }

        // Default fill: white. A proper implementation reads BackPixel from
        // the X window's CWBackPixel attribute. M3 polish.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: deviceWidth, height: deviceHeight))

        // [Y-FLIP #1 of 3] Backing CTM y-flip + logical→device scale.
        //
        // Three operations applied to the backing CGContext:
        //   1. translate origin to (0, deviceHeight)
        //   2. scale(1, -1) — flip y so X-style y-down works
        //   3. scale(scaleFactor, scaleFactor) — logical→device pixels
        //
        // Order matters: CG transforms compose so the LAST call applies
        // FIRST to user-space coordinates. So drawing at user (x, y) gets
        // scaled first, then y-flipped, then translated up. Net effect:
        // user (x, y) → device (x*scale, h - y*scale).
        //
        // Why y-flipped: X11 uses top-left origin (y-down); CG default is
        // bottom-left (y-up). With this flip, dispatch handlers pass X
        // coords directly into draw calls without per-call arithmetic.
        //
        // This flip is one of three (see the other two in
        // FlippedXView.draw and CocoaWindowBridge.drawImageText8). All
        // three are necessary; none is redundant. See the comment in
        // FlippedXView.draw for how they compose.
        ctx.translateBy(x: 0, y: CGFloat(deviceHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        self.backing = ctx
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingWidth = deviceWidth
        self.backingHeight = deviceHeight
        self.scaleFactor = scale
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = backing, let cg = NSGraphicsContext.current?.cgContext else { return }
        guard let img = ctx.makeImage() else { return }

        // [Y-FLIP #2 of 3] Blit y-flip in the NSView's draw context.
        //
        // Why this y-flip is necessary, and not redundant with the backing
        // CTM's y-flip (#1) or the glyph local-flip (#3):
        //
        // Our backing CGBitmapContext has a y-flipped CTM (`translate(0, h)`
        // + `scaleBy(1, -1)`) so dispatch handlers can use X-style top-left
        // origin coords. That CTM affects DRAWING into the bitmap; it does
        // NOT change how pixels are stored in memory or how the bitmap is
        // interpreted as a CGImage.
        //
        // CGBitmapContext's user-space origin is at the lower-left (CG
        // natural y-up). So drawing at user-coord (0, 0) with our CTM
        // applied lands at CG-natural (0, h) — the upper edge of the bitmap
        // — which the rasterizer writes into "bottom of memory" because
        // that's what represents the image's TOP visually in CG's y-up
        // model. (Apple's CGBitmapContext stores bottom-of-image first in
        // memory by convention, even though `CGImage` interprets row 0 as
        // top of image.)
        //
        // Net effect: the CGImage from `makeImage()` represents the bitmap
        // with its rows in CG-natural order (row 0 = bottom of image). When
        // drawn into a flipped NSView's CGContext via `cg.draw(img, in:)`,
        // CG renders the image WITHOUT auto-flipping for the view's
        // flippedness — image row 0 ends up at the top of `bounds` in CG
        // user space, which is the BOTTOM of the view visually (since the
        // NSView is flipped). Result: image appears upside-down, drawn at
        // the bottom of the visible area.
        //
        // The explicit `translateBy + scaleBy(1, -1)` here counter-flips
        // before `cg.draw`, so the CGImage's natural-bottom maps to the
        // top of `bounds` in the flipped NSView's coords, which is the top
        // of the view visually. Now the image renders right-side-up at the
        // top.
        //
        // This is the ONLY transform applied at blit time. The other two
        // y-flips (backing CTM, text local-flip in drawImageText8) serve
        // separate purposes — none cancels another.
        cg.saveGState()
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: bounds)
        cg.restoreGState()
    }
}
