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
    /// Logical X-protocol width (matches PixmapEntry.width).
    public let width: Int
    /// Logical X-protocol height.
    public let height: Int
    /// Logical-to-device scale of the backing bitmap. > 1 means the
    /// underlying CGContext stores `width*scaleFactor × height*scaleFactor`
    /// device pixels with a matching scale baked into its CTM, so a
    /// drawing call at logical user-coords renders at device fidelity.
    /// This matches FlippedXView's backing layout — without it, window→pixmap
    /// CopyArea (Motif's caret save-under) downsamples 3× device pixels
    /// to a logical-scale pixmap and then upsamples on restore, eroding
    /// glyph AA edges every blink (visible as text damage in the cursor's
    /// save-under area).
    public let scaleFactor: Double

    /// Allocate a width×height (logical) ARGB bitmap stored at
    /// `width*scaleFactor × height*scaleFactor` device pixels, apply the
    /// y-flip-and-scale CTM so the caller writes in X-protocol coords
    /// (and reads at logical scale via the bitmap's stored content).
    /// Returns nil only if CGContext allocation fails (defensive — never
    /// for sane width/height/scale).
    public init?(width: Int, height: Int, scaleFactor: Double = 1) {
        guard width > 0, height > 0, scaleFactor > 0 else { return nil }
        let deviceWidth = Int((Double(width) * scaleFactor).rounded())
        let deviceHeight = Int((Double(height) * scaleFactor).rounded())
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = deviceWidth * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: deviceWidth, height: deviceHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return nil }

        // Three-op CTM matching FlippedXView.resizeBacking. Order of
        // calls vs. order of application is reversed (last call applies
        // first to user coords). Net: user (x, y) → device (x*scale,
        // deviceHeight - y*scale).
        ctx.translateBy(x: 0, y: CGFloat(deviceHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(scaleFactor), y: CGFloat(scaleFactor))

        self.context = ctx
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }
}
