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

        // Two-step transform so X-logical coords pass through:
        //   1. translate origin to (0, deviceHeight); flip y so y-down works
        //   2. scale by scale factor so logical-pixel arithmetic lands on
        //      device-pixel boundaries
        // Order matters; CG transforms compose right-to-left when applied to
        // drawing primitives, so the last transform set is applied first to
        // user-space coordinates.
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
        // Reset the CTM to identity for the duration of makeImage so the
        // CGImage has natural top-left-first pixel ordering. saveGState /
        // restoreGState bracket this so subsequent X drawing into the
        // backing context still uses the logical-to-device transform.
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        let img = ctx.makeImage()
        ctx.restoreGState()

        if let img = img {
            cg.draw(img, in: bounds)
        }
    }
}
