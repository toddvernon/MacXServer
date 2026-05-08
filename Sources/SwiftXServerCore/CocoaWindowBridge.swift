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
        var delegate: XWindowDelegate?
    }

    private var slots: [UInt32: Slot] = [:]
    private let lock = NSLock()
    private var resizeHandler: (@Sendable (UInt32, UInt16, UInt16) -> Void)?
    private var keyHandler: (@Sendable (UInt32, UInt8, UInt, Bool) -> Void)?
    private var focusHandler: (@Sendable (UInt32, Bool) -> Void)?
    private var mouseHandler: (@Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void)?
    private var pasteHandler: (@Sendable (UInt32, String) -> Void)?
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

    public func setOnKey(_ handler: @escaping @Sendable (UInt32, UInt8, UInt, Bool) -> Void) {
        keyHandler = handler
    }

    public func setOnFocus(_ handler: @escaping @Sendable (UInt32, Bool) -> Void) {
        focusHandler = handler
    }

    public func setOnMouse(_ handler: @escaping @Sendable (UInt32, Int16, Int16, UInt8, Bool) -> Void) {
        mouseHandler = handler
    }

    public func setOnPaste(_ handler: @escaping @Sendable (UInt32, String) -> Void) {
        pasteHandler = handler
    }

    func handleNSWindowFocusChange(id: UInt32, gained: Bool) {
        focusHandler?(id, gained)
    }

    // MARK: - WindowBridge

    public func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        lock.lock()
        slots[id] = Slot(geometry: geometry, eventMask: eventMask, pendingTitle: nil, window: nil, view: nil)
        lock.unlock()
    }

    public func mapTopLevel(
        id: UInt32,
        geometry: TopLevelGeometry,
        eventMask: UInt32,
        descendants: [DescendantSnapshot],
        byteOrder: ByteOrder,
        sequence: UInt16,
        outbound: OutboundQueue
    ) {
        lock.lock()
        if slots[id] != nil {
            slots[id]?.geometry = geometry            // sync to current
        }
        let pendingTitle = slots[id]?.pendingTitle ?? "swift-x"
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.log?.log("  bridge: bringing up NSWindow for 0x\(String(id, radix: 16)) \(geometry.width)x\(geometry.height) (logical)")
            let scale = self.scaleFactor

            // NSWindow content rect is in points. Convert from logical:
            // points = logical * scale / backingScale (typically 2.0 on Retina).
            // The result: 1 X-logical pixel = `scale` device pixels regardless of
            // the macOS backing factor.
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let pointsW = CGFloat(geometry.width) * CGFloat(scale) / backingScale
            let pointsH = CGFloat(geometry.height) * CGFloat(scale) / backingScale

            let view = FlippedXView(frame: NSRect(x: 0, y: 0, width: pointsW, height: pointsH))
            view.topLevelXWindowId = id
            view.resizeBacking(logicalWidth: Int(geometry.width),
                               logicalHeight: Int(geometry.height),
                               scale: scale)
            view.autoresizingMask = [.width, .height]
            // Route NSEvent keyDown / keyUp into the session via the
            // bridge-level keyHandler closure (set by ServerSession at init).
            // The view captures a snapshot of the closure; on each keystroke
            // it invokes with (topLevelXWindowId, macOS keyCode, modifierFlags
            // raw value, isDown).
            if let keyHandler = self.keyHandler {
                view.keyHandler = { event, isDown in
                    keyHandler(id, UInt8(event.keyCode & 0xFF),
                               event.modifierFlags.rawValue, isDown)
                }
            }
            if let mouseHandler = self.mouseHandler {
                view.mouseHandler = { x, y, button, isDown in
                    mouseHandler(id, x, y, button, isDown)
                }
            }
            if let pasteHandler = self.pasteHandler {
                view.pasteHandler = { text in
                    pasteHandler(id, text)
                }
            }

            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let contentRect = NSRect(x: 100, y: 100, width: pointsW, height: pointsH)
            let win = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
            win.contentView = view
            win.title = pendingTitle
            win.isReleasedWhenClosed = false

            let delegate = XWindowDelegate(windowId: id, bridge: self)
            win.delegate = delegate

            self.lock.lock()
            self.slots[id]?.window = win
            self.slots[id]?.view = view
            self.slots[id]?.delegate = delegate
            self.lock.unlock()

            // Emit MapNotify and any descendant Expose events BEFORE bringing
            // the NSWindow to key. makeKeyAndOrderFront fires
            // windowDidBecomeKey synchronously, which in turn calls our focus
            // handler and queues a FocusIn. We want MapNotify to land in the
            // outbound queue before that FocusIn so the X client sees the
            // natural order: window mapped, then focused.
            MockWindowBridge.emitMapSequence(
                window: id, geometry: geometry,
                topLevelEventMask: eventMask,
                descendants: descendants,
                byteOrder: byteOrder, sequence: sequence,
                outbound: outbound
            )

            win.makeKeyAndOrderFront(nil)
            // Make the FlippedXView the first responder so keyDown / keyUp
            // route to it. Without this, NSWindow swallows key events.
            win.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {
        let event = MapNotifyEvent(
            sequenceNumber: sequence, event: id, window: id,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: byteOrder))
        // The session passes ExposureMask + size info via the descendant
        // entry it just stored; we ask the bridge owner to emit Expose
        // through the higher-level mapWindow path. mapDescendant by itself
        // doesn't know event masks. See ServerSession.mapWindow for the
        // Expose-emit (it now follows mapDescendant for non-top-level maps).
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

    public func copyArea(
        topLevel: UInt32,
        srcX: Int16, srcY: Int16,
        dstX: Int16, dstY: Int16,
        width: UInt16, height: UInt16
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view,
                  let ctx = view.backing,
                  let dataPtr = ctx.data else { return }

            // Logical X-coords (y-down) translate to memory pixel coords
            // (top-down) via `mem = logical * scale`. Memory is row-major
            // with byte 0 = top-left pixel.
            let scale = view.scaleFactor
            let bpr = ctx.bytesPerRow
            let bmpW = ctx.width
            let bmpH = ctx.height
            let bytesPerPixel = 4

            let srcMemX = Int(srcX) * scale
            let srcMemY = Int(srcY) * scale
            let dstMemX = Int(dstX) * scale
            let dstMemY = Int(dstY) * scale
            let copyW = Int(width) * scale
            let copyH = Int(height) * scale

            // Bounds-check both rects. CopyArea outside the bitmap is a
            // silent no-op rather than a crash.
            guard srcMemX >= 0, srcMemY >= 0, copyW > 0, copyH > 0,
                  srcMemX + copyW <= bmpW, srcMemY + copyH <= bmpH,
                  dstMemX >= 0, dstMemY >= 0,
                  dstMemX + copyW <= bmpW, dstMemY + copyH <= bmpH else { return }

            let bytes = dataPtr.assumingMemoryBound(to: UInt8.self)
            let copyByteWidth = copyW * bytesPerPixel

            // Direction matters with overlap: copy rows from the side
            // farthest from overlap inward. memmove handles within-row.
            if dstMemY < srcMemY {
                // Moving content UP in memory (typical xterm scroll-up).
                // Iterate top-down so we read src rows before they're
                // overwritten as dst rows.
                for i in 0..<copyH {
                    let srcOffset = (srcMemY + i) * bpr + srcMemX * bytesPerPixel
                    let dstOffset = (dstMemY + i) * bpr + dstMemX * bytesPerPixel
                    memmove(bytes.advanced(by: dstOffset),
                            bytes.advanced(by: srcOffset),
                            copyByteWidth)
                }
            } else {
                // Moving content DOWN (or same row). Iterate bottom-up.
                for i in (0..<copyH).reversed() {
                    let srcOffset = (srcMemY + i) * bpr + srcMemX * bytesPerPixel
                    let dstOffset = (dstMemY + i) * bpr + dstMemX * bytesPerPixel
                    memmove(bytes.advanced(by: dstOffset),
                            bytes.advanced(by: srcOffset),
                            copyByteWidth)
                }
            }

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
        let printable = String(decoding: string.prefix(40), as: UTF8.self)
        log?.log("  drawImageText8 top=0x\(String(topLevel, radix: 16)) font=\(font.macFontName) cell=\(font.cellWidth)x\(font.cellHeight) at (\(x),\(y)) fg=(\(foreground.red >> 8),\(foreground.green >> 8),\(foreground.blue >> 8)) str=\"\(printable)\" len=\(string.count)")
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

            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            // [Y-FLIP #3 of 3] Glyph local y-flip.
            //
            // CTFontDrawGlyphs renders glyph art in CG's default orientation
            // — ascent extends in +y user space, descent in -y — same as
            // any text drawing. Our backing CTM (Y-FLIP #1) has user-space
            // y-axis flipped (so X coords pass through). Drawing glyphs
            // straight into that context puts ascent visually DOWN — text
            // appears upside-down.
            //
            // We translate to the glyph BASELINE first, then apply a local
            // scale(1, -1) inside saveGState/restoreGState. Inside that
            // scope, the local user-space has y running in CG's natural
            // direction relative to the baseline. Glyph art (which CG
            // draws +y from origin) now extends "up" relative to the
            // local origin, which is "up" visually because we're inside
            // the backing's flipped space.
            //
            // Glyph positions are relative to the local (post-translate,
            // post-flip) origin — `(i*cellW, 0)` per glyph for monospace.
            //
            // This y-flip is one of three (see Y-FLIP #1 in
            // FlippedXView.resizeBacking and Y-FLIP #2 in FlippedXView.draw).
            // Each addresses a separate concern.
            ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            ctx.scaleBy(x: 1, y: -1)

            let ctFont = ctFont(for: font)

            // Decode bytes as Latin-1 → UniChar (each byte is its codepoint).
            // Phase 4 adds proper iso8859-1 / iso10646-1 handling.
            var unichars = [UniChar](repeating: 0, count: n)
            for i in 0..<n { unichars[i] = UniChar(string[i]) }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

            var positions = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                positions[i] = CGPoint(x: CGFloat(i * cellW), y: 0)
            }

            CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)

            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func drawPolyText8(
        topLevel: UInt32,
        foreground: RGB16,
        font: ResolvedFont,
        x: Int16, y: Int16,
        items: [UInt8]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }

            ctx.saveGState()
            applyFill(ctx, foreground)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)

            // Walk TEXTITEM8 items: 0xFF marks a 5-byte font shift we ignore
            // (we use the GC font for the whole request — Athena widget apps
            // like xcalc don't issue font shifts). Otherwise each item is
            // length(1) + delta(1 signed) + length glyph bytes. Pen advances
            // by delta + sum-of-glyph-advances after each run.
            //
            // Position glyphs by the CTFont's actual advances rather than
            // the resolved-font cellWidth: PolyText8 has no bg fill, so
            // there's no benefit to cell-snapping, and using true advances
            // closes the visible gaps that show up when our reported cell
            // width is wider than the substituted Mac font's glyph box.
            // (The Phase-1.5 metrics-tightening work in CHATGPT_REVIEW.md
            // covers the principled fix; this is the local minimum.)
            let baseX = Int(x)
            var penX: CGFloat = CGFloat(baseX)
            let baseY = Int(y)

            let ctFont = ctFont(for: font)

            var i = 0
            while i < items.count {
                let b = items[i]
                if b == 0xFF {
                    // Font shift sentinel: skip 5 bytes total (sentinel + 4
                    // bytes of font ID). xcalc never sends these.
                    i += 5
                    continue
                }
                let n = Int(b)
                if n == 0 { i += 1; continue }
                guard i + 2 + n <= items.count else { break }
                let delta = Int8(bitPattern: items[i + 1])
                penX += CGFloat(delta)

                var unichars = [UniChar](repeating: 0, count: n)
                for j in 0..<n { unichars[j] = UniChar(items[i + 2 + j]) }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, n)

                var advances = [CGSize](repeating: .zero, count: n)
                CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advances, n)

                var positions = [CGPoint](repeating: .zero, count: n)
                var localX: CGFloat = 0
                for j in 0..<n {
                    positions[j] = CGPoint(x: localX, y: 0)
                    localX += advances[j].width
                }

                ctx.saveGState()
                ctx.translateBy(x: penX, y: CGFloat(baseY))
                ctx.scaleBy(x: 1, y: -1)
                CTFontDrawGlyphs(ctFont, &glyphs, &positions, n, ctx)
                ctx.restoreGState()

                penX += localX
                i += 2 + n
            }

            ctx.restoreGState()
            view.setNeedsDisplay(view.bounds)
        }
    }

    public func setTopLevelWindowBackground(id: UInt32, color: RGB16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let slot = self.slot(id) else { return }
            // RGB16 stores values in the high byte (e.g., 0xFFFF for max).
            // NSColor takes 0..1 floats, so divide by 0xFFFF.
            let r = CGFloat(color.red)   / 65535.0
            let g = CGFloat(color.green) / 65535.0
            let b = CGFloat(color.blue)  / 65535.0
            slot.window?.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
            // The view's layer.backgroundColor is what actually shows during
            // a live-resize drag (since the FlippedXView fully covers the
            // window's content area, NSWindow.backgroundColor is hidden).
            slot.view?.liveResizeBackground = CGColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }

    public func paintWindowRects(topLevel: UInt32, rects: [WindowBackgroundRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let view = self.slot(topLevel)?.view, let ctx = view.backing else { return }
            ctx.saveGState()
            for r in rects {
                applyFill(ctx, r.color)
                ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                width: CGFloat(r.width), height: CGFloat(r.height)))
            }
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
        log?.log("  windowDidResize id=0x\(String(id, radix: 16)) bounds=\(bounds.width)x\(bounds.height)pt → logical \(newLogicalW)x\(newLogicalH) (was \(view.logicalWidth)x\(view.logicalHeight)) liveResize=\(view.inLiveResize)")
        guard newLogicalW > 0, newLogicalH > 0 else { return }
        guard newLogicalW != view.logicalWidth || newLogicalH != view.logicalHeight else {
            // No actual size change — don't notify the session (would cause
            // xterm to react to a zero-delta resize).
            return
        }
        // During a live drag we keep the OLD bitmap. Reallocating it here
        // would fire on every pixel of mouse movement and white-flash the
        // window (FlippedXView.resizeBacking allocates a fresh white-filled
        // CGBitmapContext). The layer's backgroundColor (set in
        // setTopLevelWindowBackground) fills the newly-uncovered region in
        // the right colour while the user is dragging. The actual bitmap
        // resize + ConfigureNotify happen once when the drag ends, in
        // handleNSWindowDidEndLiveResize.
        guard !view.inLiveResize else { return }
        view.resizeBacking(logicalWidth: newLogicalW,
                           logicalHeight: newLogicalH,
                           scale: scaleFactor)
        view.setNeedsDisplay(view.bounds)
        resizeHandler?(id, UInt16(min(newLogicalW, 65535)), UInt16(min(newLogicalH, 65535)))
    }

    /// Called by the NSWindowDelegate when a live-resize gesture ends. We
    /// deferred BOTH the bitmap resize and the ConfigureNotify until now;
    /// catch up here using the view's current bounds.
    @MainActor
    fileprivate func handleNSWindowDidEndLiveResize(id: UInt32) {
        guard let view = slot(id)?.view else { return }
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = view.bounds
        let newLogicalW = Int((bounds.width * backingScale / CGFloat(scaleFactor)).rounded())
        let newLogicalH = Int((bounds.height * backingScale / CGFloat(scaleFactor)).rounded())
        log?.log("  windowDidEndLiveResize id=0x\(String(id, radix: 16)) final bounds=\(bounds.width)x\(bounds.height)pt → logical \(newLogicalW)x\(newLogicalH)")
        guard newLogicalW > 0, newLogicalH > 0 else { return }
        if newLogicalW != view.logicalWidth || newLogicalH != view.logicalHeight {
            view.resizeBacking(logicalWidth: newLogicalW,
                               logicalHeight: newLogicalH,
                               scale: scaleFactor)
            view.setNeedsDisplay(view.bounds)
        }
        resizeHandler?(id,
                       UInt16(min(newLogicalW, 65535)),
                       UInt16(min(newLogicalH, 65535)))
    }
}

/// NSWindowDelegate that catches user-driven resizes and key/resign-key focus
/// transitions and forwards them to the bridge. Stays @MainActor since
/// NSWindowDelegate is.
@MainActor
private final class XWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UInt32
    weak var bridge: CocoaWindowBridge?

    init(windowId: UInt32, bridge: CocoaWindowBridge) {
        self.windowId = windowId
        self.bridge = bridge
    }

    func windowDidResize(_ notification: Notification) {
        bridge?.handleNSWindowResize(id: windowId)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        bridge?.handleNSWindowDidEndLiveResize(id: windowId)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        bridge?.handleNSWindowFocusChange(id: windowId, gained: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        bridge?.handleNSWindowFocusChange(id: windowId, gained: false)
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
