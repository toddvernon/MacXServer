import AppKit
import CoreGraphics

/// Server-side reskin of the xterm scrollbar into Motif chrome. xterm's
/// built-in (Athena) scrollbar draws a flat trough plus a thumb filled with a
/// 50%-gray OpaqueStippled pattern — the "jinky" dither. When the Motif-skin
/// hack is on, we suppress that rendering and draw a Motif XmScrollBar look in
/// the same window: square stepper arrows at each end, a recessed trough
/// between them, and a raised beveled slider over the thumb extent xterm asked
/// for. Because Motif reserves arrow buttons at the ends, the trough channel
/// is shorter than the whole window, so the thumb (which xterm computes against
/// the full window height) is rescaled proportionally into the channel.
///
/// Coordinates are TOP-LEVEL-LOCAL logical px — the same space FlippedXView's
/// backing draws in. The caller (CocoaWindowBridge) opens the scrollbar
/// window's `withDrawContext` first, which applies the window clip and the
/// logical->device CTM, so we just issue plain fills/paths here.
///
/// The bevel recipe mirrors MotifFrameView.bevel (concentric 1px rings, light
/// top/left + dark bottom/right for raised, swapped for recessed) so the
/// scrollbar matches the frame's buttons. Motif's XmScrollBar default
/// shadow_thickness is 2; we use that for the slider and arrow buttons.
enum MotifScrollbarRenderer {

    /// Recessed trough channel color: the frame face nudged toward its
    /// bottom-shadow so the trough reads as a darker, sunken track behind the
    /// raised slider — the XmScrollBar trough-vs-slider contrast.
    static func troughColor(_ c: MotifStateColors) -> NSColor {
        c.fill.blended(withFraction: 0.35, of: c.shadow) ?? c.fill
    }

    /// Size (square side, logical px) of the stepper-arrow buttons for a
    /// scrollbar of the given dimensions, or nil if it's too short to host
    /// arrows plus a usable trough. Shared by the renderer and the input side
    /// (ServerSession's arrow-region hit test) so the two never drift.
    static func arrowSize(width w: CGFloat, height h: CGFloat) -> CGFloat? {
        let minChannel: CGFloat = 10
        var arrow = w
        if h < 2 * arrow + minChannel { arrow = floor((h - minChannel) / 2) }
        return arrow >= 6 ? arrow : nil
    }

    /// Trough color as an X RGB16, for substituting the scrollbar window's
    /// background pixel so the existing bg-paint machinery paints the trough
    /// on map/expose/configure. Keeps ServerSession AppKit-free.
    static func troughRGB16(_ c: MotifStateColors) -> RGB16 {
        let t = troughColor(c)
        let s = t.usingColorSpace(.sRGB) ?? t
        return RGB16(red:   UInt16(max(0, min(1, s.redComponent))   * 65535),
                     green: UInt16(max(0, min(1, s.greenComponent)) * 65535),
                     blue:  UInt16(max(0, min(1, s.blueComponent))  * 65535))
    }

    /// Paint the whole scrollbar window in Motif style.
    ///
    /// - windowRect: the scrollbar window, top-level-local logical coords.
    /// - thumbTop / thumbHeight: the thumb extent in WINDOW-LOCAL coords against
    ///   the full window height (thumbHeight == 0 → no thumb). Rescaled here
    ///   into the trough channel between the arrow buttons.
    static func paint(_ ctx: CGContext,
                      windowRect: CGRect,
                      thumbTop: CGFloat,
                      thumbHeight: CGFloat,
                      colors: MotifStateColors,
                      bevelWidth: Int) {
        let w = windowRect.width
        let h = windowRect.height
        guard w > 0, h > 0 else { return }
        // Match the window frame's bevel thickness (the surfaced standard);
        // never less than 1 so the chrome doesn't disappear.
        let bw = max(1, bevelWidth)

        // Antialiasing OFF for the whole skin. The frame chrome is axis-aligned
        // fills (crisp either way), but the stepper-arrow glyph has diagonal edges
        // -- with AA on those smear across ~2px and the lit (highlight) slant
        // washes out, so the arrow reads as having no top-left highlight and lines
        // heavier than the frame's. Off, it renders hard-edged, like the frame and
        // real Motif (which never antialiased). The pixmap draw path disables AA;
        // the window path (which this rides) does not, so we do it here.
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        defer { ctx.restoreGState() }

        // Square stepper arrows at each end (nil if too short to host them).
        let arrowOpt = arrowSize(width: w, height: h)
        let hasArrows = arrowOpt != nil
        let arrow = arrowOpt ?? 0

        let channelY = windowRect.minY + (hasArrows ? arrow : 0)
        let channelH = h - (hasArrows ? 2 * arrow : 0)

        // Recessed trough channel.
        if channelH > 0 {
            let channel = CGRect(x: windowRect.minX, y: channelY, width: w, height: channelH)
            fill(ctx, channel, troughColor(colors))
            bevel(ctx, channel, topLeft: colors.shadow, bottomRight: colors.highlight, width: bw)
        }

        // Slider: rescale the full-height thumb extent into the channel.
        if thumbHeight > 0, channelH > 0 {
            let scale = channelH / h
            let sTop = channelY + thumbTop * scale
            let sH = max(CGFloat(2 * bw), thumbHeight * scale)
            let slider = CGRect(x: windowRect.minX, y: sTop, width: w, height: sH)
            fill(ctx, slider, colors.fill)
            bevel(ctx, slider, topLeft: colors.highlight, bottomRight: colors.shadow, width: bw)
        }

        // Stepper arrow buttons.
        if hasArrows {
            arrowButton(ctx,
                        CGRect(x: windowRect.minX, y: windowRect.minY, width: w, height: arrow),
                        pointingUp: true, colors: colors, bevelWidth: bw)
            arrowButton(ctx,
                        CGRect(x: windowRect.minX, y: windowRect.maxY - arrow, width: w, height: arrow),
                        pointingUp: false, colors: colors, bevelWidth: bw)
        }
    }

    /// A raised Motif stepper button with a 3D beveled arrowhead — the Motif
    /// XmArrowButton look. The arrow is the same face color as the button,
    /// defined by lit (top/left = highlight) and shadowed (bottom/right =
    /// shadow) edges, so it reads as a raised triangle rather than a flat
    /// black glyph.
    private static func arrowButton(_ ctx: CGContext, _ rect: CGRect,
                                    pointingUp: Bool, colors: MotifStateColors, bevelWidth: Int) {
        fill(ctx, rect, colors.fill)
        bevel(ctx, rect, topLeft: colors.highlight, bottomRight: colors.shadow, width: bevelWidth)

        let inset = rect.width * 0.28
        let cx = rect.midX
        let top = rect.minY + inset
        let bot = rect.maxY - inset
        let left = rect.minX + inset
        let right = rect.maxX - inset

        // Filled triangle in the face color, then per-edge highlight/shadow
        // for the raised 3D look (light source top-left).
        let lw = CGFloat(bevelWidth)
        if pointingUp {
            let apex = CGPoint(x: cx, y: top)
            let bl = CGPoint(x: left, y: bot)
            let br = CGPoint(x: right, y: bot)
            fillTriangle(ctx, apex, bl, br, colors.fill)
            line(ctx, apex, bl, colors.highlight, lw)   // left slant — lit
            line(ctx, bl, br, colors.shadow, lw)        // base — shadow
            line(ctx, br, apex, colors.shadow, lw)      // right slant — shadow
        } else {
            let apex = CGPoint(x: cx, y: bot)
            let tl = CGPoint(x: left, y: top)
            let tr = CGPoint(x: right, y: top)
            fillTriangle(ctx, apex, tl, tr, colors.fill)
            line(ctx, tl, tr, colors.highlight, lw)     // top — lit
            line(ctx, tl, apex, colors.highlight, lw)   // left slant — lit
            line(ctx, tr, apex, colors.shadow, lw)      // right slant — shadow
        }
    }

    private static func fillTriangle(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint,
                                     _ c: CGPoint, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint,
                             _ color: NSColor, _ width: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        // Butt caps so each edge stays its nominal width — round caps bulge
        // short edges out to ~2px and read heavier than the frame's crisp
        // 1px fill-rect bevels.
        ctx.setLineCap(.butt)
        ctx.beginPath()
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.strokePath()
    }

    /// Concentric-ring bevel: `width` rings of 1px lines, `topLeft` on the
    /// top and left edges, `bottomRight` on the bottom and right. Identical
    /// geometry to MotifFrameView.bevel.
    private static func bevel(_ ctx: CGContext, _ r: CGRect,
                              topLeft: NSColor, bottomRight: NSColor, width: Int) {
        for i in 0..<width {
            let o = CGFloat(i)
            fill(ctx, CGRect(x: r.minX + o, y: r.minY + o,
                             width: r.width - 2*o, height: 1), topLeft)
            fill(ctx, CGRect(x: r.minX + o, y: r.minY + o,
                             width: 1, height: r.height - 2*o), topLeft)
            fill(ctx, CGRect(x: r.minX + o, y: r.maxY - 1 - o,
                             width: r.width - 2*o, height: 1), bottomRight)
            fill(ctx, CGRect(x: r.maxX - 1 - o, y: r.minY + o,
                             width: 1, height: r.height - 2*o), bottomRight)
        }
    }

    private static func fill(_ ctx: CGContext, _ r: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(r)
    }
}
