import Foundation
import AppKit
import CoreText
import Framer

// Cocoa-side WindowBridge. Owns an NSWindow per top-level X window. AppKit
// calls always dispatch to the main thread; protocol events queue back to
// the OutboundQueue from the same main-thread block once the NSWindow is on
// screen.
//
// Per DECISIONS.md 2026-05-05 and RENDERING_DESIGN.md: rootless mode is
// primary — each top-level X window becomes a real NSWindow with native
// macOS chrome. The X subtree below the top-level is internal; drawing
// targets the single FlippedXView per top-level.

public final class CocoaWindowBridge: WindowBridge, @unchecked Sendable {

    private struct Slot: @unchecked Sendable {
        var geometry: TopLevelGeometry
        var eventMask: UInt32
        var pendingTitle: String?
        var window: NSWindow?
        var view: FlippedXView?
        var delegate: ResizeWindowDelegate?
    }

    private var slots: [UInt32: Slot] = [:]
    private let lock = NSLock()
    private var resizeHandler: (@Sendable (UInt32, UInt16, UInt16) -> Void)?
    private weak var log: ServerLogSink?

    /// Integer scale factor: 1 X-logical pixel = `scale` device pixels.
    /// Pulled from `DisplayConfig.scale` at startup.
    public let scaleFactor: Int

    public init(scaleFactor: Int = 1, log: ServerLogSink? = nil) {
        self.scaleFactor = scaleFactor
        self.log = log
    }

    public func setOnTopLevelResize(_ handler: @escaping @Sendable (UInt32, UInt16, UInt16) -> Void) {
        resizeHandler = handler
    }

    // MARK: - WindowBridge

    public func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        lock.lock()
        slots[id] = Slot(geometry: geometry, eventMask: eventMask, pendingTitle: nil, window: nil, view: nil)
        lock.unlock()
    }

    public func mapTopLevel(
        id: UInt32,
        eventMask: UInt32,
        descendants: [DescendantSnapshot],
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        lock.lock()
        guard let slot = slots[id] else { lock.unlock(); return }
        let geometry = slot.geometry
        let pendingTitle = slot.pendingTitle ?? "swift-x"
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let scale = self.scaleFactor

            // NSWindow content rect is in points. Convert from logical:
            // points = logical * scale / backingScale (typically 2.0 on Retina).
            // The result: 1 X-logical pixel = `scale` device pixels regardless of
            // the macOS backing factor.
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let pointsW = CGFloat(geometry.width) * CGFloat(scale) / backingScale
            let pointsH = CGFloat(geometry.height) * CGFloat(scale) / backingScale

            let view = FlippedXView(frame: NSRect(x: 0, y: 0, width: pointsW, height: pointsH))
            view.resizeBacking(logicalWidth: Int(geometry.width),
                               logicalHeight: Int(geometry.height),
                               scale: scale)
            view.autoresizingMask = [.width, .height]

            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let contentRect = NSRect(x: 100, y: 100, width: pointsW, height: pointsH)
            let win = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
            win.contentView = view
            win.title = pendingTitle
            win.isReleasedWhenClosed = false

            let delegate = ResizeWindowDelegate(windowId: id, bridge: self)
            win.delegate = delegate

            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.lock.lock()
            self.slots[id]?.window = win
            self.slots[id]?.view = view
            self.slots[id]?.delegate = delegate
            self.lock.unlock()

            MockWindowBridge.emitMapSequence(
                window: id, geometry: geometry,
                topLevelEventMask: eventMask,
                descendants: descendants,
                byteOrder: byteOrder, sequence: sequence,
                outbound: outbound
            )
        }
    }

    public func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let event = MapNotifyEvent(
            sequenceNumber: sequence, event: id, window: id,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: byteOrder))
    }

    public func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let win = slot(id)?.window
        DispatchQueue.main.async {
            win?.orderOut(nil)
            let event = UnmapNotifyEvent(
                sequenceNumber: sequence, event: id, window: id, fromConfigure: false
            )
            outbound.append(event.encode(byteOrder: byteOrder))
        }
    }

    public func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let win = slot(id)?.window
        lock.lock()
        slots.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async {
            win?.close()
            let event = DestroyNotifyEvent(
                sequenceNumber: sequence, event: id, window: id
            )
            outbound.append(event.encode(byteOrder: byteOrder))
        }
    }

    public func setTopLevelTitle(id: UInt32, title: String) {
        lock.lock()
        let win = slots[id]?.window
        if win == nil {
            slots[id]?.pendingTitle = title
        }
        lock.unlock()
        if let win = win {
            DispatchQueue.main.async { win.title = title }
        }
    }

    public func descendantResized(id: UInt32, parent: UInt32, geometry: TopLevelGeometry) {
        // M3 hook — mark the NSView's region for that descendant as needing
        // redraw. M2 doesn't do anything visible.
    }

    public func drawingTarget(for drawable: UInt32) -> Any? {
        slot(drawable)?.view
    }

    // MARK: - Drawing

    public func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            ctx.setLineWidth(CGFloat(max(lineWidth, 1)))
            for s in segments {
                ctx.move(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                ctx.addLine(to: CGPoint(x: CGFloat(s.x2), y: CGFloat(s.y2)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyLine(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, points: [DrawPoint]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyForeground(ctx, foreground)
            ctx.setLineWidth(CGFloat(max(lineWidth, 1)))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.strokePath()
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing,
                  !points.isEmpty else { return }
            ctx.saveGState()
            applyFill(ctx, foreground)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y)))
            for p in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            }
            ctx.closePath()
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyFill(ctx, background)
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, rectangles: [Framer.Rectangle]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            applyFill(ctx, foreground)
            for r in rectangles {
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawImageText8(
        topLevel: UInt32,
        foreground: RGB16, background: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        string: [UInt8]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }

            // Per X11 ImageText8 spec: fill bg rect under the text first,
            // then draw glyphs. Rect spans (x, y-ascent) to
            // (x + n*cellWidth, y+descent) where (x, y) is the baseline of
            // the first glyph. We use the cell-snapped metrics so the bg
            // exactly covers what xterm expects.
            let cellW = font.cellWidth
            let n = string.count
            let bgRect = CGRect(
                x: CGFloat(x),
                y: CGFloat(Int(y) - font.ascent),
                width: CGFloat(cellW * n),
                height: CGFloat(font.cellHeight)
            )

            ctx.saveGState()
            applyFill(ctx, background)
            ctx.fill(bgRect)

            // Glyph rendering. Cell-snapped: each glyph's origin is at
            // (x + i*cellW, y) with subpixel positioning OFF. CTFont's
            // natural advance may differ from cellW; we override by
            // explicit position so monospace cells stay aligned.
            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            // Our backing context's CTM has y-flipped so X-style top-left
            // coordinates pass through. Glyphs in CG's default orientation
            // extend in +y user-space (visually down in our flipped frame),
            // which would render text upside-down. The text matrix
            // counter-flips glyph local coords; combined with the flipped
            // CTM the net y-axis is identity, so glyphs render right-side-up.
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

            let ctFont = ctFont(for: font)

            // Decode bytes as Latin-1 → UniChar (each byte is its codepoint).
            // Phase 4 adds proper iso8859-1 / iso10646-1 handling.
            var unichars = [UniChar](repeating: 0, count: n)
            for i in 0..<n { unichars[i] = UniChar(string[i]) }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

            var positions = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                positions[i] = CGPoint(
                    x: CGFloat(Int(x) + i * cellW),
                    y: CGFloat(y)
                )
            }

            // CTFontDrawGlyphs respects the current fill color (foreground),
            // the CTM (logical→device scale + y-flip), and the textMatrix
            // (counter-flip set above for upright glyphs).
            CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)

            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// Cache of CTFont instances keyed by (macFontName, pointSize). Avoids
    /// re-instantiating the same font on every ImageText8 dispatch.
    nonisolated(unsafe) private static let ctFontCache = NSCache<NSString, CTFont>()

    /// Resolve to a CTFont, caching by name+size key. Falls back to system
    /// monospace if the named font fails to load (very rare on macOS for
    /// the substitutes in our table).
    fileprivate func ctFont(for font: ResolvedFont) -> CTFont {
        let key = "\(font.macFontName)@\(font.pointSize)" as NSString
        if let cached = Self.ctFontCache.object(forKey: key) {
            return cached
        }
        let ct = CTFontCreateWithName(font.macFontName as CFString, CGFloat(font.pointSize), nil)
        Self.ctFontCache.setObject(ct, forKey: key)
        return ct
    }

    // MARK: - Helpers

    private func slot(_ id: UInt32) -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        return slots[id]
    }

    /// Called from the NSWindowDelegate after a user-driven resize. Compute
    /// the new logical (X) dimensions from the NSView's points-bounds via
    /// `points × backingScale / scaleFactor`, reallocate the FlippedXView's
    /// backing CGBitmapContext at the new logical size, then call back into
    /// the session via `resizeHandler` so it can update WindowTable + emit
    /// ConfigureNotify.
    @MainActor
    fileprivate func handleNSWindowResize(id: UInt32) {
        let view = slot(id)?.view
        guard let view = view else { return }
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = view.bounds
        let newLogicalW = Int((bounds.width * backingScale / CGFloat(scaleFactor)).rounded())
        let newLogicalH = Int((bounds.height * backingScale / CGFloat(scaleFactor)).rounded())
        guard newLogicalW > 0, newLogicalH > 0 else { return }
        if newLogicalW != view.logicalWidth || newLogicalH != view.logicalHeight {
            view.resizeBacking(logicalWidth: newLogicalW,
                               logicalHeight: newLogicalH,
                               scale: scaleFactor)
            view.setNeedsDisplay(view.bounds)
        }
        resizeHandler?(id, UInt16(min(newLogicalW, 65535)), UInt16(min(newLogicalH, 65535)))
    }
}

/// NSWindowDelegate that catches user-driven resizes and forwards them to
/// the bridge. Stays @MainActor since NSWindowDelegate is.
@MainActor
private final class ResizeWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UInt32
    weak var bridge: CocoaWindowBridge?

    init(windowId: UInt32, bridge: CocoaWindowBridge) {
        self.windowId = windowId
        self.bridge = bridge
    }

    func windowDidResize(_ notification: Notification) {
        bridge?.handleNSWindowResize(id: windowId)
    }
}

private func applyForeground(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
}

private func applyFill(_ ctx: CGContext, _ rgb: RGB16) {
    let r = CGFloat(rgb.red) / 65535.0
    let g = CGFloat(rgb.green) / 65535.0
    let b = CGFloat(rgb.blue) / 65535.0
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
}
