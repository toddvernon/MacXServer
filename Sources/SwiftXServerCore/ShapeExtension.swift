import Foundation
import Framer

// SHAPE extension server logic. Faithful port of the request semantics in
// reference/X11R6/xc/programs/Xserver/Xext/shape.c, adapted to our value-typed
// WindowEntry + Region engine. The wire codec lives in Framer (ShapeRequests /
// ShapeReplies / ShapeEvents); this file owns dispatch, region combination,
// the bitmap->region conversion for ShapeMask, and ShapeNotify delivery.
//
// Coordinate note: shape regions live in window-LOCAL logical coordinates,
// same space as clipList / borderClip. Scaling to device pixels happens in the
// render layer (the bridge), never here.

extension ServerSession {

    // MARK: - Dispatch

    /// Sub-dispatch a SHAPE request. `bytes` is the full request including the
    /// 4-byte header (bytes[0] == our SHAPE major opcode, bytes[1] == minor).
    func handleShapeRequest(bytes: [UInt8], byteOrder: ByteOrder) {
        guard bytes.count >= 2 else {
            emitError(.length, majorOpcode: Self.shapeMajorOpcode)
            return
        }
        let minor = bytes[1]
        do {
            switch minor {
            case ShapeMinor.queryVersion:
                handleShapeQueryVersion(try ShapeQueryVersion.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.rectangles:
                handleShapeRectangles(try ShapeRectangles.decode(from: bytes, byteOrder: byteOrder), rawLength: bytes.count, byteOrder: byteOrder)
            case ShapeMinor.mask:
                handleShapeMask(try ShapeMask.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.combine:
                handleShapeCombine(try ShapeCombine.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.offset:
                handleShapeOffset(try ShapeOffset.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.queryExtents:
                handleShapeQueryExtents(try ShapeQueryExtents.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.selectInput:
                handleShapeSelectInput(try ShapeSelectInput.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.inputSelected:
                handleShapeInputSelected(try ShapeInputSelected.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            case ShapeMinor.getRectangles:
                handleShapeGetRectangles(try ShapeGetRectangles.decode(from: bytes, byteOrder: byteOrder), byteOrder: byteOrder)
            default:
                // Unknown minor opcode: BadRequest, per shape.c's dispatch default.
                emitError(.request, majorOpcode: Self.shapeMajorOpcode, minorOpcode: UInt16(minor))
            }
        } catch {
            // Malformed body (shouldn't happen: Request.decode already length-
            // checked) — BadLength is the spec-correct response.
            log?.log("[SHAPE] decode failed for minor \(minor): \(error)")
            emitError(.length, majorOpcode: Self.shapeMajorOpcode, minorOpcode: UInt16(minor))
        }
    }

    // MARK: - Requests

    private func handleShapeQueryVersion(_ r: ShapeQueryVersion, byteOrder: ByteOrder) {
        let reply = ShapeQueryVersionReply(sequenceNumber: sequenceNumber, majorVersion: 1, minorVersion: 0)
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    private func handleShapeRectangles(_ r: ShapeRectangles, rawLength: Int, byteOrder: ByteOrder) {
        guard windowForShape(r.dest, minor: ShapeMinor.rectangles) != nil else { return }
        guard r.destKind == ShapeKind.bounding || r.destKind == ShapeKind.clip else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.destKind), minorOpcode: UInt16(ShapeMinor.rectangles))
            return
        }
        // Ordering must be one of Unsorted(0)/YSorted(1)/YXSorted(2)/YXBanded(3).
        guard r.ordering <= 3 else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.ordering), minorOpcode: UInt16(ShapeMinor.rectangles))
            return
        }
        // shape.c: rect-bytes must be a whole number of 8-byte xRectangles.
        let rectBytes = rawLength - 16
        guard rectBytes >= 0, rectBytes % 8 == 0 else {
            emitError(.length, majorOpcode: Self.shapeMajorOpcode, minorOpcode: UInt16(ShapeMinor.rectangles))
            return
        }
        // Build the source region from the rect list. We always normalize
        // rather than trust the ordering hint — strictly more lenient than
        // shape.c's VerifyRectOrder (which would BadMatch a mis-claimed
        // order) and never yields a wrong region. See SHORTCUTS.md.
        let boxes = r.rectangles.map { rectToBox($0) }
        let srcRgn = Region.rects(boxes, order: .unsorted)
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: r.xOff, yOff: r.yOff, minor: ShapeMinor.rectangles)
    }

    private func handleShapeMask(_ r: ShapeMask, byteOrder: ByteOrder) {
        guard windowForShape(r.dest, minor: ShapeMinor.mask) != nil else { return }
        guard r.destKind == ShapeKind.bounding || r.destKind == ShapeKind.clip else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.destKind), minorOpcode: UInt16(ShapeMinor.mask))
            return
        }
        // src == None -> nil region (used to reset a window to unshaped via
        // op=Set). Otherwise the src must be a depth-1 pixmap on this screen.
        var srcRgn: Region? = nil
        if r.src != 0 {
            guard let pix = pixmaps.get(r.src) else {
                emitError(.pixmap, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.src, minorOpcode: UInt16(ShapeMinor.mask))
                return
            }
            guard pix.depth == 1 else {
                emitError(.match, majorOpcode: Self.shapeMajorOpcode, minorOpcode: UInt16(ShapeMinor.mask))
                return
            }
            srcRgn = bitmapToRegion(pixmapId: r.src, width: Int(pix.width), height: Int(pix.height))
        }
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: r.xOff, yOff: r.yOff, minor: ShapeMinor.mask)
    }

    private func handleShapeCombine(_ r: ShapeCombine, byteOrder: ByteOrder) {
        guard windowForShape(r.dest, minor: ShapeMinor.combine) != nil else { return }
        guard r.destKind == ShapeKind.bounding || r.destKind == ShapeKind.clip else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.destKind), minorOpcode: UInt16(ShapeMinor.combine))
            return
        }
        guard let srcWin = windows.get(r.src) else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.src, minorOpcode: UInt16(ShapeMinor.combine))
            return
        }
        let srcRgn: Region
        switch r.srcKind {
        case ShapeKind.bounding:
            srcRgn = srcWin.boundingShape ?? defaultBoundingRegion(for: srcWin)
        case ShapeKind.clip:
            srcRgn = srcWin.clipShape ?? defaultClipRegion(for: srcWin)
        default:
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.srcKind), minorOpcode: UInt16(ShapeMinor.combine))
            return
        }
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: r.xOff, yOff: r.yOff, minor: ShapeMinor.combine)
    }

    private func handleShapeOffset(_ r: ShapeOffset, byteOrder: ByteOrder) {
        guard windows.get(r.dest) != nil else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.dest, minorOpcode: UInt16(ShapeMinor.offset))
            return
        }
        let existing: Region?
        switch r.destKind {
        case ShapeKind.bounding: existing = windows.get(r.dest)?.boundingShape
        case ShapeKind.clip:     existing = windows.get(r.dest)?.clipShape
        default:
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.destKind), minorOpcode: UInt16(ShapeMinor.offset))
            return
        }
        // shape.c: only an existing (set) region is translated; an unshaped
        // window stays unshaped. Either way a ShapeNotify is sent.
        if let region = existing {
            let moved = region.translated(dx: Int32(r.xOff), dy: Int32(r.yOff))
            if r.destKind == ShapeKind.bounding { windows.setBoundingShape(r.dest, moved) }
            else { windows.setClipShape(r.dest, moved) }
            setWindowShape(windowId: r.dest)
        }
        sendShapeNotify(windowId: r.dest, kind: r.destKind)
    }

    private func handleShapeQueryExtents(_ r: ShapeQueryExtents, byteOrder: ByteOrder) {
        guard let win = windows.get(r.window) else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.window, minorOpcode: UInt16(ShapeMinor.queryExtents))
            return
        }
        let bExtent = win.boundingShape.map { regionExtent($0) } ?? boxExtent(defaultBoundingRegion(for: win))
        let cExtent = win.clipShape.map { regionExtent($0) } ?? boxExtent(defaultClipRegion(for: win))
        let reply = ShapeQueryExtentsReply(
            sequenceNumber: sequenceNumber,
            boundingShaped: win.boundingShape != nil,
            clipShaped: win.clipShape != nil,
            xBounding: bExtent.x, yBounding: bExtent.y, widthBounding: bExtent.w, heightBounding: bExtent.h,
            xClip: cExtent.x, yClip: cExtent.y, widthClip: cExtent.w, heightClip: cExtent.h)
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    private func handleShapeSelectInput(_ r: ShapeSelectInput, byteOrder: ByteOrder) {
        guard windows.get(r.window) != nil else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.window, minorOpcode: UInt16(ShapeMinor.selectInput))
            return
        }
        switch r.enable {
        case 1: shapeSelectedWindows.insert(r.window)   // xTrue
        case 0: shapeSelectedWindows.remove(r.window)   // xFalse
        default:
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.enable), minorOpcode: UInt16(ShapeMinor.selectInput))
        }
    }

    private func handleShapeInputSelected(_ r: ShapeInputSelected, byteOrder: ByteOrder) {
        guard windows.get(r.window) != nil else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.window, minorOpcode: UInt16(ShapeMinor.inputSelected))
            return
        }
        let reply = ShapeInputSelectedReply(sequenceNumber: sequenceNumber, enabled: shapeSelectedWindows.contains(r.window))
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    private func handleShapeGetRectangles(_ r: ShapeGetRectangles, byteOrder: ByteOrder) {
        guard let win = windows.get(r.window) else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.window, minorOpcode: UInt16(ShapeMinor.getRectangles))
            return
        }
        let region: Region?
        switch r.kind {
        case ShapeKind.bounding: region = win.boundingShape
        case ShapeKind.clip:     region = win.clipShape
        default:
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(r.kind), minorOpcode: UInt16(ShapeMinor.getRectangles))
            return
        }
        // Unshaped -> the single default rectangle (border-inclusive bounding /
        // interior clip), matching shape.c's `if (!region)` branch.
        let boxes: [BoxRec]
        if let region {
            boxes = region.rects
        } else if r.kind == ShapeKind.bounding {
            boxes = [boundingDefaultBox(for: win)]
        } else {
            boxes = [clipDefaultBox(for: win)]
        }
        let rects = boxes.map { boxToRect($0) }
        // YXBanded (3): our Region stores y-x banded, so that's the honest claim.
        let reply = ShapeGetRectanglesReply(sequenceNumber: sequenceNumber, ordering: 3, rectangles: rects)
        outbound.append(reply.encode(byteOrder: byteOrder))
    }

    // MARK: - Region combination (shape.c RegionOperate)

    /// The shared combine path: translate the source by (xOff,yOff), fold it
    /// into the destination's bounding or clip shape per `op`, store, then
    /// apply to rendering and send ShapeNotify. Faithful to shape.c's
    /// RegionOperate including the per-op nil-destination handling.
    private func combineShape(dest: UInt32, destKind: UInt8, src: Region?,
                              op: UInt8, xOff: Int16, yOff: Int16, minor: UInt8) {
        guard op <= ShapeOp.invert else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(op), minorOpcode: UInt16(minor))
            return
        }
        guard let win = windows.get(dest) else { return }
        // Root window has no shape (shape.c: `if (!pWin->parent)`).
        if dest == config.rootWindowId { return }

        let translatedSrc: Region? = {
            guard let src else { return nil }
            return (xOff != 0 || yOff != 0) ? src.translated(dx: Int32(xOff), dy: Int32(yOff)) : src
        }()

        let current = (destKind == ShapeKind.bounding) ? win.boundingShape : win.clipShape
        let defaultRegion: () -> Region = {
            destKind == ShapeKind.bounding ? self.defaultBoundingRegion(for: win)
                                           : self.defaultClipRegion(for: win)
        }
        let newShape = shapeRegionOperate(current: current, src: translatedSrc, op: op, defaultRegion: defaultRegion)

        if destKind == ShapeKind.bounding { windows.setBoundingShape(dest, newShape) }
        else { windows.setClipShape(dest, newShape) }

        setWindowShape(windowId: dest)
        sendShapeNotify(windowId: dest, kind: destKind)
    }

    /// Pure region algebra for the five SHAPE ops. `current`/result of nil
    /// means "unshaped" (the implicit full default region). Mirrors the op
    /// cases in shape.c:RegionOperate exactly.
    func shapeRegionOperate(current: Region?, src: Region?, op: UInt8, defaultRegion: () -> Region) -> Region? {
        switch op {
        case ShapeOp.set:
            // dest = src (nil src clears the shape back to unshaped).
            return src
        case ShapeOp.union:
            // Unshaped (full) ∪ anything = full -> stays unshaped (nil).
            guard let current else { return nil }
            guard let src else { return current }
            return current.unioned(with: src)
        case ShapeOp.intersect:
            // Unshaped (full) ∩ src = src.
            let src = src ?? .empty
            guard let current else { return src }
            return current.intersected(with: src)
        case ShapeOp.subtract:
            // Need a concrete base; unshaped materializes the default rect.
            let src = src ?? .empty
            let base = current ?? defaultRegion()
            return base.subtracting(src)
        case ShapeOp.invert:
            // dest = src − dest. Unshaped dest (full) -> src − full = empty.
            let src = src ?? .empty
            guard let current else { return .empty }
            return src.subtracting(current)
        default:
            return current   // unreachable: op validated by caller
        }
    }

    // MARK: - Default regions (shape.c CreateBoundingShape / CreateClipShape)

    private func boundingDefaultBox(for win: WindowEntry) -> BoxRec {
        let bw = Int32(win.borderWidth)
        return BoxRec(x1: -bw, y1: -bw, x2: Int32(win.width) + bw, y2: Int32(win.height) + bw)
    }
    private func clipDefaultBox(for win: WindowEntry) -> BoxRec {
        BoxRec(x1: 0, y1: 0, x2: Int32(win.width), y2: Int32(win.height))
    }
    private func defaultBoundingRegion(for win: WindowEntry) -> Region { Region(box: boundingDefaultBox(for: win)) }
    private func defaultClipRegion(for win: WindowEntry) -> Region { Region(box: clipDefaultBox(for: win)) }

    // MARK: - Apply shape to rendering (Phase 3 hook)

    /// Push the window's current bounding shape into the rendering layer. For a
    /// top-level this masks the NSWindow to the bounding region (the visible
    /// payoff: oclock's round face, xeyes' oval). Descendant and clip-shape
    /// application aren't wired in this cut — they're stored and queryable but
    /// not yet visually applied (see SHORTCUTS.md / scope decision).
    func setWindowShape(windowId: UInt32) {
        guard let win = windows.get(windowId), let bridge = bridge else { return }
        // Only top-levels map to an NSWindow we can mask in this first cut.
        guard win.parent == config.rootWindowId else { return }
        // nil bounding shape -> unshaped (rectangular); a region -> its rects.
        let rects: [Rectangle]? = win.boundingShape.map { region in
            region.rects.map { boxToRect($0) }
        }
        bridge.setWindowBoundingShape(topLevel: windowId, rects: rects)
    }

    // MARK: - ShapeNotify

    /// Emit a ShapeNotify for `kind` to this client if it has selected shape
    /// input on the window. Extents come from the (possibly nil) shape region,
    /// falling back to the default rect when unshaped — matching SendShapeNotify.
    func sendShapeNotify(windowId: UInt32, kind: UInt8) {
        guard shapeSelectedWindows.contains(windowId) else { return }
        guard let win = windows.get(windowId), let bo = byteOrder else { return }
        let region = (kind == ShapeKind.bounding) ? win.boundingShape : win.clipShape
        let shaped = region != nil
        let extent: (x: Int16, y: Int16, w: UInt16, h: UInt16)
        if let region {
            extent = regionExtent(region)
        } else {
            extent = boxExtent(kind == ShapeKind.bounding ? defaultBoundingRegion(for: win) : defaultClipRegion(for: win))
        }
        let event = ShapeNotifyEvent(
            type: Self.shapeEventBase + ShapeMinor.queryVersion,  // ShapeNotify == base + 0
            kind: kind, sequenceNumber: sequenceNumber, window: windowId,
            x: extent.x, y: extent.y, width: extent.w, height: extent.h,
            time: serverTime, shaped: shaped)
        outbound.append(event.encode(byteOrder: bo))
    }

    // MARK: - Bitmap -> Region (shape.c BITMAP_TO_REGION)

    /// Convert a depth-1 pixmap to a region of its set bits. "Set" follows the
    /// server's paper/ink convention (whitePixel=0=clear, blackPixel=1=set), so
    /// a set bit reads back as fully black via readDrawablePixels (0xAARRGGBB
    /// with RGB==0). Same convention as the FillStippled bit reader. Builds one
    /// 1-pixel-tall box per horizontal run of set bits, then normalizes (which
    /// coalesces vertically adjacent identical bands).
    private func bitmapToRegion(pixmapId: UInt32, width: Int, height: Int) -> Region {
        guard width > 0, height > 0, let bridge = bridge else { return .empty }
        let pixels = bridge.readDrawablePixels(from: .pixmap(id: pixmapId, depth: 1),
                                               srcX: 0, srcY: 0, width: width, height: height)
        guard pixels.count >= width * height else { return .empty }
        var boxes: [BoxRec] = []
        for y in 0..<height {
            var runStart = -1
            for x in 0..<width {
                let set = (pixels[y * width + x] & 0x00FFFFFF) == 0   // fully black
                if set {
                    if runStart < 0 { runStart = x }
                } else if runStart >= 0 {
                    boxes.append(BoxRec(x1: Int32(runStart), y1: Int32(y), x2: Int32(x), y2: Int32(y + 1)))
                    runStart = -1
                }
            }
            if runStart >= 0 {
                boxes.append(BoxRec(x1: Int32(runStart), y1: Int32(y), x2: Int32(width), y2: Int32(y + 1)))
            }
        }
        return Region.rects(boxes, order: .yxSorted)
    }

    // MARK: - Small helpers

    /// Look up a window for a shape op, emitting BadWindow if unknown. Returns
    /// nil for the root (which carries no shape) so callers no-op silently.
    private func windowForShape(_ id: UInt32, minor: UInt8) -> WindowEntry? {
        if let w = windows.get(id) { return w }
        if id == config.rootWindowId { return nil }
        emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: id, minorOpcode: UInt16(minor))
        return nil
    }

    private func rectToBox(_ r: Rectangle) -> BoxRec {
        BoxRec(x1: Int32(r.x), y1: Int32(r.y),
               x2: Int32(r.x) + Int32(r.width), y2: Int32(r.y) + Int32(r.height))
    }
    private func boxToRect(_ b: BoxRec) -> Rectangle {
        Rectangle(x: Int16(clamping: b.x1), y: Int16(clamping: b.y1),
                  width: UInt16(clamping: b.x2 - b.x1), height: UInt16(clamping: b.y2 - b.y1))
    }
    private func regionExtent(_ region: Region) -> (x: Int16, y: Int16, w: UInt16, h: UInt16) {
        boxExtent(region)
    }
    private func boxExtent(_ region: Region) -> (x: Int16, y: Int16, w: UInt16, h: UInt16) {
        let b = region.boundingBox
        return (Int16(clamping: b.x1), Int16(clamping: b.y1),
                UInt16(clamping: b.x2 - b.x1), UInt16(clamping: b.y2 - b.y1))
    }
}
