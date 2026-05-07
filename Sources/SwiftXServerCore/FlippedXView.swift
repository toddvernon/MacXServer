import AppKit
import CoreGraphics

// NSView subclass that:
//   * uses X11's top-left origin convention (isFlipped = true) so X coords
//     pass through unchanged
//   * holds a CGBitmapContext as the backing store; drawing requests write
//     into it directly
//   * blits the dirty rect to the screen in draw(_:)
//
// Per RENDERING_DESIGN.md: one NSView per top-level X window; drawing for any
// X subwindow in that subtree clips against the subwindow's geometry and
// writes into this single backing context.

public final class FlippedXView: NSView {

    public var backing: CGContext?
    public var backingWidth: Int = 0
    public var backingHeight: Int = 0

    public override var isFlipped: Bool { true }

    /// Per RENDERING_DESIGN.md item 8: the bitmap pixel order is top-down so
    /// X coordinates and CG coordinates agree. We achieve this by setting up
    /// the CGContext with a vertical flip applied, so writes to the bitmap
    /// land in screen-natural pixel order.
    public func resizeBacking(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        backingWidth = width
        backingHeight = height
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return }
        // Default fill: white. A proper implementation reads BackPixel from
        // the X window's CWBackPixel attribute. M3 polish.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip so subsequent CG calls use top-left origin / y-down semantics,
        // matching X11's coordinate system.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        backing = ctx
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = backing, let cg = NSGraphicsContext.current?.cgContext else { return }
        // The bitmap was rendered with y-flipped; to turn it into a CGImage
        // for blitting, undo the flip first.
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -CGFloat(backingHeight))
        let img = ctx.makeImage()
        ctx.restoreGState()
        // re-apply the flip after extracting the image so subsequent draws
        // continue to use top-left origin
        ctx.translateBy(x: 0, y: CGFloat(backingHeight))
        ctx.scaleBy(x: 1, y: -1)

        if let img = img {
            cg.draw(img, in: bounds)
        }
    }
}
