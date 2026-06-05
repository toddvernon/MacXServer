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
        // Build the source region from the rect list. Client supplies rects
        // at X-protocol LOGICAL coords; we scale to DEVICE coords as we
        // enter the internal region system (DEVICE_COORDS_REFACTOR.md).
        // We always normalize rather than trust the ordering hint —
        // strictly more lenient than shape.c's VerifyRectOrder.
        let s = config.deviceScale
        let boxes = r.rectangles.map { rectToBox($0).scaledToDevice(by: s) }
        let srcRgn = Region.rects(boxes, order: .unsorted)
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: Int32(r.xOff) * s, yOff: Int32(r.yOff) * s,
                     minor: ShapeMinor.rectangles)
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
            // bitmapToRegion reads the depth-1 pixmap at DEVICE resolution
            // — that's what the underlying PixelBuffer stores anyway, and
            // matches our new device-coord shape-region convention.
            srcRgn = bitmapToRegion(pixmapId: r.src,
                                    width: Int(pix.width)  * Int(config.deviceScale),
                                    height: Int(pix.height) * Int(config.deviceScale))
        }
        let s = config.deviceScale
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: Int32(r.xOff) * s, yOff: Int32(r.yOff) * s,
                     minor: ShapeMinor.mask)
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
        // ShapeCombine offsets are at logical X-protocol coords; scale to
        // device. The src region (from another window's shape) is already
        // device-coord.
        let s = config.deviceScale
        combineShape(dest: r.dest, destKind: r.destKind, src: srcRgn,
                     op: r.op, xOff: Int32(r.xOff) * s, yOff: Int32(r.yOff) * s,
                     minor: ShapeMinor.combine)
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
        // xOff/yOff are at logical X-protocol coords; scale to device since
        // the region is device-coord internally.
        if let region = existing {
            let s = config.deviceScale
            let moved = region.translated(dx: Int32(r.xOff) * s, dy: Int32(r.yOff) * s)
            if r.destKind == ShapeKind.bounding {
                windows.setBoundingShape(r.dest, moved)
            } else {
                windows.setClipShape(r.dest, moved)
            }
            setWindowShape(windowId: r.dest)
        }
        sendShapeNotify(windowId: r.dest, kind: r.destKind)
    }

    private func handleShapeQueryExtents(_ r: ShapeQueryExtents, byteOrder: ByteOrder) {
        guard let win = windows.get(r.window) else {
            emitError(.window, majorOpcode: Self.shapeMajorOpcode, badResourceId: r.window, minorOpcode: UInt16(ShapeMinor.queryExtents))
            return
        }
        // Shape regions are device-coord internally; the protocol expects
        // extents in X-protocol logical pixels. Scale each region's
        // bounding box back to logical with the conservative ceil/floor
        // round-trip (BoxRec.scaledToLogical) before computing the extent.
        let s = config.deviceScale
        func logicalExtent(_ region: Region) -> (x: Int16, y: Int16, w: UInt16, h: UInt16) {
            return boxExtent(Region(box: region.boundingBox.scaledToLogical(by: s)))
        }
        let bExtent: (x: Int16, y: Int16, w: UInt16, h: UInt16)
        let cExtent: (x: Int16, y: Int16, w: UInt16, h: UInt16)
        if let region = win.boundingShape {
            bExtent = logicalExtent(region)
        } else {
            // Default region is built in device coords; scale back for reply.
            bExtent = boxExtent(Region(box: boundingDefaultBox(for: win).scaledToLogical(by: s)))
        }
        if let region = win.clipShape {
            cExtent = logicalExtent(region)
        } else {
            cExtent = boxExtent(Region(box: clipDefaultBox(for: win).scaledToLogical(by: s)))
        }
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
        // interior clip), matching shape.c's `if (!region)` branch. Regions
        // are device-coord internally; scale back to logical with the
        // conservative ceil/floor convention for the reply (every logical
        // pixel with any device-pixel coverage is reported in).
        let s = config.deviceScale
        let logicalRegion: Region
        if let region {
            logicalRegion = region.scaledToLogical(by: s)
        } else if r.kind == ShapeKind.bounding {
            logicalRegion = Region(box: boundingDefaultBox(for: win).scaledToLogical(by: s))
        } else {
            logicalRegion = Region(box: clipDefaultBox(for: win).scaledToLogical(by: s))
        }
        let rects = logicalRegion.rects.map { boxToRect($0) }
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
                              op: UInt8, xOff: Int32, yOff: Int32, minor: UInt8) {
        guard op <= ShapeOp.invert else {
            emitError(.value, majorOpcode: Self.shapeMajorOpcode, badResourceId: UInt32(op), minorOpcode: UInt16(minor))
            return
        }
        guard let win = windows.get(dest) else { return }
        // Root window has no shape (shape.c: `if (!pWin->parent)`).
        if dest == config.rootWindowId { return }

        // xOff/yOff are in DEVICE coords (callers scale at the protocol
        // boundary). All shape regions in the engine are device-coord too.
        let translatedSrc: Region? = {
            guard let src else { return nil }
            return (xOff != 0 || yOff != 0) ? src.translated(dx: xOff, dy: yOff) : src
        }()

        let current = (destKind == ShapeKind.bounding) ? win.boundingShape : win.clipShape
        let defaultRegion: () -> Region = {
            destKind == ShapeKind.bounding ? self.defaultBoundingRegion(for: win)
                                           : self.defaultClipRegion(for: win)
        }
        let newShape = shapeRegionOperate(current: current, src: translatedSrc, op: op, defaultRegion: defaultRegion)

        if destKind == ShapeKind.bounding {
            windows.setBoundingShape(dest, newShape)
        } else {
            windows.setClipShape(dest, newShape)
        }

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
    //
    // Returns DEVICE-coord regions matching the rest of the engine
    // (DEVICE_COORDS_REFACTOR.md). WindowEntry stores logical sizes; we
    // scale here.

    private func boundingDefaultBox(for win: WindowEntry) -> BoxRec {
        let s = config.deviceScale
        let bw = Int32(win.borderWidth) * s
        return BoxRec(x1: -bw, y1: -bw,
                      x2: Int32(win.width)  * s + bw,
                      y2: Int32(win.height) * s + bw)
    }
    private func clipDefaultBox(for win: WindowEntry) -> BoxRec {
        let s = config.deviceScale
        return BoxRec(x1: 0, y1: 0,
                      x2: Int32(win.width)  * s,
                      y2: Int32(win.height) * s)
    }
    private func defaultBoundingRegion(for win: WindowEntry) -> Region { Region(box: boundingDefaultBox(for: win)) }
    private func defaultClipRegion(for win: WindowEntry) -> Region { Region(box: clipDefaultBox(for: win)) }

    // MARK: - Apply shape to rendering (Phase 3 hook)

    /// Push the window's current bounding/clip shape into the rendering layer.
    /// Two paths:
    ///
    /// - **Top-level**: mask the NSWindow to the bounding region (the visible
    ///   payoff: oclock's round face, xeyes' oval). The NSWindow masking
    ///   handles all drawing into the top-level's backing.
    /// - **Descendant**: fold the shape into the clipList machinery via
    ///   `recomputeClipsForSubtreeContaining` (which now respects
    ///   `boundingShape` + `clipShape` per `Region/ClipList.swift`), then
    ///   repaint the top-level subtree's backgrounds so newly-exposed parent
    ///   regions get filled and the shaped descendant draws within its new
    ///   region. Emit Expose on the changed descendant so the client redraws
    ///   content. xcalc's rounded buttons take this path.
    func setWindowShape(windowId: UInt32) {
        guard windows.get(windowId) != nil else { return }
        // Recompute the containing top-level's clip tree first. The engine
        // folds boundingShape/clipShape in for every window, so this is
        // load-bearing for both:
        //   - top-level shape: narrows descendants' parentVisible so
        //     children of a shaped top-level are correctly clipped (the
        //     NSWindow mask handles the top-level's own pixels, but the
        //     clipList machinery handles every other consumer like
        //     VisibilityNotify state and descendant rendering)
        //   - descendant shape: narrows the descendant's own borderClip and
        //     clipList so its rendering respects the shape (xcalc buttons).
        // Pure WindowTable bookkeeping; runs without a bridge so tests can
        // assert against the recomputed clipList.
        recomputeClipsForSubtreeContaining(windowId)
        // Re-fetch the window entry AFTER the recompute. WindowEntry is a
        // value type, so a snapshot taken before recompute would carry the
        // PRIOR (stale) borderClip / clipList — paintRectsForWindow would
        // then emit the old clip-shape's rects even though the new one was
        // just set, leaving xcalc buttons stuck in the post-Bounding /
        // pre-Clip intermediate visual (small grey region inside the new
        // larger bounding stadium). The wire diff at
        // /tmp/macxcapture/2026-06-03T10-51-17-xcalc.xtap caught this.
        guard let win = windows.get(windowId) else { return }
        // Bridge-side side effects (NSWindow mask for top-levels; repaint +
        // Expose for descendants) only run when a bridge is attached.
        guard let bridge = bridge, let bo = byteOrder else { return }
        if win.parent == config.rootWindowId {
            // Top-level: mask the NSWindow with device-coord shape rects.
            // The view's clip path divides by backingScale to convert device
            // px → points; same coordinate path the descendant rendering
            // takes via paintWindowRects + identity-CTM clip.
            let rects: [Rectangle]? = win.boundingShape.map { region in
                region.rects.map { boxToRect($0) }
            }
            bridge.setWindowBoundingShape(topLevel: windowId, rects: rects)
            return
        }
        // Descendant: paint the parent's bg under the window's borderBox
        // (covers shape-narrowed-now-parent-shows), then the window's own
        // bg/border via paintRectsForWindow. With device-coord regions
        // throughout the engine, paintRectsForWindow emits device-coord
        // rects that paintWindowRects fills at identity CTM — the curve
        // lands at exact device pixels by the same code path every
        // descendant paint uses. No special shape paint, no dual
        // representation, no transient invalidation dance.
        guard let (topId, dx, dy) = topLevelAndOffset(for: windowId) else { return }
        var rects: [WindowBackgroundRect] = []
        let s = config.deviceScale
        if let parent = windows.get(win.parent), parent.backPixel != nil {
            // Build child's borderBox in device coords (matches parent.clipList
            // and our region engine).
            let bw = Int32(win.borderWidth) * s
            let childBorderBox = BoxRec(
                x1: Int32(dx) * s - bw, y1: Int32(dy) * s - bw,
                x2: Int32(dx) * s + Int32(win.width)  * s + bw,
                y2: Int32(dy) * s + Int32(win.height) * s + bw
            )
            let parentBg = windowBackground(parent.id, byteOrder: bo)
            let exposedInParent = parent.clipList.intersected(with: Region(box: childBorderBox))
            for box in exposedInParent.rects {
                let w = box.x2 - box.x1, h = box.y2 - box.y1
                guard w > 0, h > 0 else { continue }
                rects.append(WindowBackgroundRect(
                    x: Int16(clamping: box.x1), y: Int16(clamping: box.y1),
                    width: UInt16(clamping: w), height: UInt16(clamping: h),
                    color: parentBg
                ))
            }
        }
        rects.append(contentsOf: paintRectsForWindow(entry: win, dx: dx, dy: dy, byteOrder: bo))
        if !rects.isEmpty {
            bridge.paintWindowRects(topLevel: topId, rects: rects)
        }
        if let entry = windows.get(windowId),
           entry.eventMask & MockWindowBridge.exposureMask != 0 {
            // Expose payload is window-local LOGICAL pixels; scale device
            // clipList back to logical, then subtract logical (dx, dy).
            let dxI = Int32(dx)
            let dyI = Int32(dy)
            let localRects = entry.clipList.rects.map { box -> BoxRec in
                let logical = box.scaledToLogical(by: s)
                return BoxRec(
                    x1: logical.x1 - dxI, y1: logical.y1 - dyI,
                    x2: logical.x2 - dxI, y2: logical.y2 - dyI
                )
            }
            MockWindowBridge.emitExposesForRects(
                window: windowId, rects: localRects,
                byteOrder: bo, sequence: sequenceNumber, outbound: outbound
            )
        }
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
        // Region is device-coord; ShapeNotify carries logical pixels per
        // the X protocol. Scale extent back at the wire boundary.
        let s = config.deviceScale
        let extent: (x: Int16, y: Int16, w: UInt16, h: UInt16)
        if let region {
            extent = boxExtent(Region(box: region.boundingBox.scaledToLogical(by: s)))
        } else {
            let defBox = (kind == ShapeKind.bounding ? boundingDefaultBox(for: win)
                                                     : clipDefaultBox(for: win)).scaledToLogical(by: s)
            extent = boxExtent(Region(box: defBox))
        }
        let event = ShapeNotifyEvent(
            type: Self.shapeEventBase + ShapeMinor.queryVersion,  // ShapeNotify == base + 0
            kind: kind, sequenceNumber: sequenceNumber, window: windowId,
            x: extent.x, y: extent.y, width: extent.w, height: extent.h,
            time: serverTime, shaped: shaped)
        outbound.append(event.encode(byteOrder: bo))
    }

    // MARK: - Bitmap -> Region (shape.c BITMAP_TO_REGION)

    /// Convert a depth-1 pixmap to a region of its set bits at DEVICE
    /// resolution. The pixmap's PixelBuffer is allocated at device scale
    /// (`reference_pixmap_device_scale` memory), so reading at device res
    /// gives sub-X-pixel precision for shape curves — the win for retina
    /// rendering. "Set" follows the server's paper/ink convention
    /// (whitePixel=0=clear, blackPixel=1=set); a set bit reads as fully
    /// black (`(p & 0x00FFFFFF) == 0`).
    ///
    /// `width`/`height` are in DEVICE pixels (logical pixmap dims times
    /// scale). Output region is in device-coord pixmap-local coordinates;
    /// caller translates by `xOff/yOff` (also device) when applying.
    private func bitmapToRegion(pixmapId: UInt32, width: Int, height: Int) -> Region {
        guard width > 0, height > 0, let bridge = bridge,
              let grid = bridge.readDepth1MaskDevicePixels(pixmapId: pixmapId) else { return .empty }
        let gw = grid.width, gh = grid.height
        guard gw > 0, gh > 0, grid.pixels.count >= gw * gh else { return .empty }
        // Walk at min(requested, available) so a stale-size request degrades
        // gracefully instead of overrunning the buffer.
        let walkW = min(width, gw)
        let walkH = min(height, gh)
        var boxes: [BoxRec] = []
        for y in 0..<walkH {
            var runStart = -1
            for x in 0..<walkW {
                let set = (grid.pixels[y * gw + x] & 0x00FFFFFF) == 0
                if set {
                    if runStart < 0 { runStart = x }
                } else if runStart >= 0 {
                    boxes.append(BoxRec(x1: Int32(runStart), y1: Int32(y), x2: Int32(x), y2: Int32(y + 1)))
                    runStart = -1
                }
            }
            if runStart >= 0 {
                boxes.append(BoxRec(x1: Int32(runStart), y1: Int32(y), x2: Int32(walkW), y2: Int32(y + 1)))
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
