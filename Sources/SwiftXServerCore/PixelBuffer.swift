import CoreGraphics

// One CGBitmapContext per X pixmap. Created eagerly at CreatePixmap and
// freed at FreePixmap by PixmapTable. The X-side depth (1, 8, 24, 32) is
// stored separately on PixmapEntry; the Mac-side bitmap is always 32-bit
// ARGB premultiplied-first / byteOrder32Little — same format as
// FlippedXView's window backing. Depth conversion happens at the I/O
// boundary (PutImage decode, CopyPlane src extraction, GetImage encode).
//
// Coordinate convention: same y-flip as FlippedXView.backing. Drawing at
// user-space (x, y) lands at pixmap row y from the top. This way the
// dispatch handlers don't need to know whether the draw target is a
// window or a pixmap — coordinates are X-protocol coordinates throughout.
//
// Pixmaps live at LOGICAL pixels — no device-scale multiplication. Window
// backings scale up by scaleFactor (Phase 1 of the resolution work) to
// render at the display's device resolution. Pixmaps are pure off-screen
// surfaces; clients PutImage / draw in pixel-exact terms and CopyArea
// them to scaled windows where the blit happens to upscale. That keeps
// the format simple and avoids subpixel artifacts in CopyArea.

public struct PixelBuffer {

    public let context: CGContext
    public let width: Int
    public let height: Int

    /// Allocate a width×height ARGB bitmap, pre-fill transparent black,
    /// apply the y-flip CTM so the caller writes in X-protocol coords.
    /// Returns nil only if CGContext allocation fails (effectively never
    /// for sane width/height; defensive).
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return nil }

        // Y-flip: translate origin to top-left, flip y so X-style y-down
        // works. No scale (pixmaps at logical resolution). Same shape as
        // FlippedXView.resizeBacking minus the scale step. See
        // SERVER_RESOLUTION_SCALING_AND_FONTS.md for the rationale.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        self.context = ctx
        self.width = width
        self.height = height
    }
}
