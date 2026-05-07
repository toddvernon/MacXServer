import Framer

// Per-connection state machine. Bytes flow in via `feed(_:)`; reply/event bytes
// the server should send back come out the return value. There is no socket
// in here, deliberately — `Server.swift` glues the session to a real socket;
// tests drive the session directly with bytes from the capture corpus.
//
// Sequence numbers: we increment per parsed request (starting at 1 for the
// first non-Setup request, per the X11 spec) and stamp it on every reply we
// emit. SetupAccepted itself doesn't carry a sequence number.

public final class ServerSession: @unchecked Sendable {
    private enum Phase {
        case awaitingSetup
        case running(byteOrder: ByteOrder)
    }

    public let config: ServerConfig

    public let atoms = AtomTable()
    public let colors = ColorTable()
    public let windows = WindowTable()
    public let gcs = GCTable()
    public let pixmaps = PixmapTable()
    public let fonts = FontTable()
    public let properties = PropertyTable()

    public let outbound: OutboundQueue
    public let bridge: WindowBridge?

    private var phase: Phase = .awaitingSetup
    private var inbound: [UInt8] = []
    private var sequenceNumber: UInt16 = 0

    public private(set) var setupAcceptedSent: Bool = false
    public private(set) var requestsProcessed: Int = 0
    public private(set) var unknownOpcodes: [UInt8] = []
    public private(set) var errorsEmitted: Int = 0

    public weak var log: ServerLogSink?

    public init(
        config: ServerConfig = .default,
        bridge: WindowBridge? = nil,
        outbound: OutboundQueue = OutboundQueue(),
        log: ServerLogSink? = nil
    ) {
        self.config = config
        self.bridge = bridge
        self.outbound = outbound
        self.log = log
        bridge?.setOnTopLevelResize { [weak self] id, width, height in
            self?.handleTopLevelResize(id: id, width: width, height: height)
        }
        bridge?.setOnKey { [weak self] topLevel, macKeyCode, modifierFlags, isDown in
            self?.handleKeyEvent(
                topLevel: topLevel, macKeyCode: macKeyCode,
                modifierFlags: modifierFlags, isDown: isDown
            )
        }
    }

    /// Called by the bridge from main thread when a keyDown/keyUp NSEvent
    /// arrives. Resolves which X window in the top-level's subtree should
    /// receive the event (the deepest viewable window with KeyPressMask /
    /// KeyReleaseMask in its event mask), translates to X keycode + state,
    /// and queues a KeyPress / KeyRelease event.
    public func handleKeyEvent(
        topLevel: UInt32, macKeyCode: UInt8, modifierFlags: UInt, isDown: Bool
    ) {
        guard let order = byteOrder else { return }
        let mask: UInt32 = isDown ? (1 << 0) : (1 << 1)        // KeyPress / KeyRelease
        guard let target = keyTarget(topLevel: topLevel, eventMaskBit: mask) else {
            log?.log("  keyEvent: no target window with mask 0x\(String(mask, radix: 16)) under 0x\(String(topLevel, radix: 16))")
            return
        }
        let xKeycode = USKeymap.xKeycode(forMacKeyCode: macKeyCode)
        let state = USKeymap.translateModifiers(modifierFlags)
        // X11 InputEvent shape covers KeyPress / KeyRelease / button / motion.
        // code: 2 = KeyPress, 3 = KeyRelease.
        let code: UInt8 = isDown ? 2 : 3
        let event = InputEvent(
            detail: xKeycode,
            sequenceNumber: sequenceNumber,
            time: 0,                                          // server time; xterm doesn't care
            root: config.rootWindowId,
            event: target,
            child: 0,
            rootX: 0, rootY: 0, eventX: 0, eventY: 0,         // pointer position; not relevant for keys
            state: state,
            sameScreen: true
        )
        log?.log("  → \(isDown ? "KeyPress" : "KeyRelease") xKey=0x\(String(xKeycode, radix: 16)) target=0x\(String(target, radix: 16)) state=0x\(String(state, radix: 16))")
        outbound.append(event.encode(code: code, byteOrder: order))
    }

    /// Walk the subtree rooted at `topLevel` looking for a viewable window
    /// whose event mask has the given bit set. Per X11 spec, key events
    /// propagate to the smallest enclosing window with the relevant mask.
    /// Phase 1: just find any descendant with the mask; fall back to top-level.
    private func keyTarget(topLevel: UInt32, eventMaskBit: UInt32) -> UInt32? {
        // BFS through the subtree.
        var queue: [UInt32] = [topLevel]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let entry = windows.get(id), entry.eventMask & eventMaskBit != 0 {
                return id
            }
            for (cid, w) in windows.windows where w.parent == id {
                queue.append(cid)
            }
        }
        return windows.get(topLevel) != nil ? topLevel : nil
    }

    /// Called by the bridge from main thread when the user resizes an
    /// NSWindow. Updates the X tracking and emits ConfigureNotify on the
    /// top-level. The X client (xclock) will respond by re-issuing
    /// ConfigureWindow on its drawing-target descendant; that in turn
    /// triggers the descendant Expose path in `dispatch`.
    public func handleTopLevelResize(id: UInt32, width: UInt16, height: UInt16) {
        guard let result = windows.resize(id, width: width, height: height, x: nil, y: nil) else { return }
        let (old, new) = result
        guard old.width != new.width || old.height != new.height else { return }
        guard let order = byteOrder else { return }
        log?.log("  → emit ConfigureNotify on 0x\(String(id, radix: 16)) \(new.width)x\(new.height) (was \(old.width)x\(old.height))")
        let event = ConfigureNotifyEvent(
            sequenceNumber: sequenceNumber,
            event: id, window: id, aboveSibling: 0,
            x: new.x, y: new.y,
            width: new.width, height: new.height,
            borderWidth: new.borderWidth,
            overrideRedirect: false
        )
        outbound.append(event.encode(byteOrder: order))

        // The outer's resize means descendants' visible region changed too —
        // for xterm specifically, the inner's drawing area is now bigger
        // (or smaller) and any newly-exposed pixels need redrawing. Real
        // Xsun emits Expose on each viewable descendant with ExposureMask.
        // We do the same (emit Expose covering full new descendant size,
        // even if shrinking — slight over-emit, but xterm copes).
        let exposureMask: UInt32 = 1 << 15
        for descendant in mappedDescendantSnapshots(of: id) {
            guard descendant.eventMask & exposureMask != 0 else { continue }
            log?.log("  → emit Expose on descendant 0x\(String(descendant.id, radix: 16)) \(descendant.width)x\(descendant.height)")
            let expose = ExposeEvent(
                sequenceNumber: sequenceNumber, window: descendant.id,
                x: 0, y: 0, width: descendant.width, height: descendant.height, count: 0
            )
            outbound.append(expose.encode(byteOrder: order))
        }
    }

    /// True if `window` is a known top-level (parent == root). Used to decide
    /// whether a CreateWindow/MapWindow should drive the platform bridge.
    public func isTopLevel(_ id: UInt32) -> Bool {
        windows.get(id)?.parent == config.rootWindowId
    }

    /// Walk parents until we hit a top-level. Returns the top-level id and
    /// the (x, y) offset of `drawable` inside it. nil if the drawable isn't
    /// in a window subtree we own (e.g., a pixmap, the root, or unknown).
    public func topLevelAndOffset(for drawable: UInt32) -> (UInt32, Int16, Int16)? {
        guard windows.get(drawable) != nil else { return nil }
        var id = drawable
        var dx: Int16 = 0
        var dy: Int16 = 0
        // Cap iterations defensively; a malformed parent chain otherwise loops.
        for _ in 0..<32 {
            guard let entry = windows.get(id) else { return nil }
            if entry.parent == config.rootWindowId { return (id, dx, dy) }
            dx = dx &+ entry.x
            dy = dy &+ entry.y
            id = entry.parent
        }
        return nil
    }

    /// Resolve a foreground/background pixel value to RGB16. Falls back to
    /// black for unknown pixels — better than crashing on a stray reference.
    private func resolveColor(_ pixel: UInt32) -> RGB16 {
        colors.rgb(for: pixel) ?? RGB16(red: 0, green: 0, blue: 0)
    }

    /// Snapshot every already-mapped descendant of `windowId`. Used when a
    /// top-level becomes viewable so the bridge can emit Expose to whichever
    /// descendants have ExposureMask in their event mask.
    private func mappedDescendantSnapshots(of windowId: UInt32) -> [DescendantSnapshot] {
        var out: [DescendantSnapshot] = []
        var stack: [UInt32] = [windowId]
        while let id = stack.popLast() {
            for (childId, w) in windows.windows where w.parent == id && w.mapped {
                out.append(DescendantSnapshot(
                    id: childId, eventMask: w.eventMask,
                    width: w.width, height: w.height
                ))
                stack.append(childId)
            }
        }
        return out
    }

    /// Build a QueryFontReply that reports the resolved font's cell-snapped
    /// metrics. Monospace path: min/max CharInfo bounds equal, charInfos
    /// empty (means "every char in range has metrics equal to minBounds"
    /// per X11 spec). Range covers printable ASCII 32..126 — Phase 4 polish
    /// extends to full Latin-1 / iso10646 BMP.
    private func makeQueryFontReply(resolved: ResolvedFont, sequence: UInt16) -> QueryFontReply {
        let bounds = CharInfo(
            leftSideBearing: 0,
            rightSideBearing: Int16(resolved.cellWidth),
            characterWidth: Int16(resolved.cellWidth),
            ascent: Int16(resolved.ascent),
            descent: Int16(resolved.descent),
            attributes: 0
        )
        return QueryFontReply(
            sequenceNumber: sequence,
            minBounds: bounds,
            maxBounds: bounds,
            minCharOrByte2: 32, maxCharOrByte2: 126,
            defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0,
            allCharsExist: true,
            fontAscent: Int16(resolved.ascent),
            fontDescent: Int16(resolved.descent),
            properties: [],
            charInfos: []
        )
    }

    /// Resolve the GC by id and translate to a typed `GCState`.
    private func gcState(_ gcId: UInt32, byteOrder: ByteOrder) -> GCState {
        guard let entry = gcs.get(gcId) else { return GCState() }
        return GCState.materialise(from: entry, byteOrder: byteOrder)
    }

    /// Pull the BackPixel attribute out of a window's stored CreateWindow
    /// valueList. Default = white pixel if not set. Used by ClearArea.
    private func windowBackground(_ windowId: UInt32, byteOrder: ByteOrder) -> RGB16 {
        guard let w = windows.get(windowId) else {
            return RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
        }
        if let pixel = ValueListReader.read(valueList: w.valueList, mask: w.valueMask, bit: CW.backPixel, byteOrder: byteOrder) {
            return resolveColor(pixel)
        }
        return RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
    }

    // MARK: - Drawing

    private func handlePolySegment(_ r: PolySegment, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.drawable) else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.segments.map {
            LineSegment(
                x1: $0.x1 &+ dx, y1: $0.y1 &+ dy,
                x2: $0.x2 &+ dx, y2: $0.y2 &+ dy
            )
        }
        bridge.drawPolySegment(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            segments: translated
        )
    }

    private func handlePolyLine(_ r: PolyLine, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.drawable) else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        // CoordinateMode.previous means each subsequent point is a delta from
        // the prior absolute position; we accumulate to get all-absolute.
        var points: [DrawPoint] = []
        points.reserveCapacity(r.points.count)
        var lastX: Int16 = 0
        var lastY: Int16 = 0
        for (i, p) in r.points.enumerated() {
            let absX: Int16
            let absY: Int16
            if r.coordinateMode == .origin || i == 0 {
                absX = p.x; absY = p.y
            } else {
                absX = lastX &+ p.x; absY = lastY &+ p.y
            }
            lastX = absX; lastY = absY
            points.append(DrawPoint(x: absX &+ dx, y: absY &+ dy))
        }
        bridge.drawPolyLine(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            lineWidth: state.lineWidth,
            points: points
        )
    }

    private func handleFillPoly(_ r: FillPoly, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.drawable) else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        var points: [DrawPoint] = []
        points.reserveCapacity(r.points.count)
        var lastX: Int16 = 0
        var lastY: Int16 = 0
        for (i, p) in r.points.enumerated() {
            let absX: Int16
            let absY: Int16
            if r.coordinateMode == .origin || i == 0 {
                absX = p.x; absY = p.y
            } else {
                absX = lastX &+ p.x; absY = lastY &+ p.y
            }
            lastX = absX; lastY = absY
            points.append(DrawPoint(x: absX &+ dx, y: absY &+ dy))
        }
        // Per X11 spec: Convex/Nonconvex use the GC's fill-rule for shape; for
        // Complex it also uses fill-rule. We just pass the GC state's fill-rule.
        bridge.drawFillPoly(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            points: points,
            evenOdd: state.fillRuleEvenOdd
        )
    }

    private func handlePolyFillRectangle(_ r: PolyFillRectangle, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.drawable) else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        let translated = r.rectangles.map {
            Rectangle(
                x: $0.x &+ dx, y: $0.y &+ dy,
                width: $0.width, height: $0.height
            )
        }
        bridge.drawPolyFillRectangle(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            rectangles: translated
        )
    }

    private func handleImageText8(_ r: ImageText8, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.drawable) else { return }
        let state = gcState(r.gc, byteOrder: byteOrder)
        // Pull the GC's font; fall back to "fixed" if no font set.
        let resolvedFont: ResolvedFont
        if let entry = fonts.get(state.font) {
            resolvedFont = entry.resolved
        } else {
            resolvedFont = FontResolver.resolve(name: "fixed")
        }
        bridge.drawImageText8(
            topLevel: top,
            foreground: resolveColor(state.foreground),
            background: resolveColor(state.background),
            font: resolvedFont,
            x: r.x &+ dx, y: r.y &+ dy,
            string: r.string
        )
    }

    private func handleCopyArea(_ r: CopyArea, byteOrder: ByteOrder) {
        guard let bridge = bridge else { return }
        // Phase 1: same-window copies only (xterm's scrolling case). If src
        // and dst drawables resolve to different top-levels, drop on the
        // floor with a log line — implement cross-window CopyArea later.
        guard let (srcTop, srcDX, srcDY) = topLevelAndOffset(for: r.srcDrawable),
              let (dstTop, dstDX, dstDY) = topLevelAndOffset(for: r.dstDrawable),
              srcTop == dstTop else {
            log?.log("  CopyArea: cross-window copy not supported yet (src=0x\(String(r.srcDrawable, radix: 16)) dst=0x\(String(r.dstDrawable, radix: 16)))")
            return
        }
        log?.log("  CopyArea top=0x\(String(srcTop, radix: 16)) src=(\(r.srcX),\(r.srcY)) dst=(\(r.dstX),\(r.dstY)) \(r.width)x\(r.height)")
        bridge.copyArea(
            topLevel: srcTop,
            srcX: r.srcX &+ srcDX, srcY: r.srcY &+ srcDY,
            dstX: r.dstX &+ dstDX, dstY: r.dstY &+ dstDY,
            width: r.width, height: r.height
        )
        // X11 spec: every CopyArea on a GC with graphics-exposures=True must
        // be followed by GraphicsExpose events (one per obscured source
        // region) OR a single NoExpose if the source had no obscured
        // pixels. graphics-exposures defaults to True; xterm's CopyWait
        // (util.c:709) BLOCKS in XWindowEvent waiting for one of these.
        // Without it, the first scroll works but every subsequent scroll
        // hangs xterm. Our same-window backing-store copies never have
        // obscured source regions, so we always emit NoExpose.
        let noExpose = NoExposureEvent(
            sequenceNumber: sequenceNumber,
            drawable: r.dstDrawable,
            minorOpcode: 0,
            majorOpcode: 62  // X_CopyArea
        )
        outbound.append(noExpose.encode(byteOrder: byteOrder))
    }

    private func handleClearArea(_ r: ClearArea, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.window),
              let entry = windows.get(r.window) else { return }
        let bg = windowBackground(r.window, byteOrder: byteOrder)
        // X11 spec: if width is 0, fill to window's right edge; if height is 0,
        // fill to bottom.
        let fillW = r.width == 0 ? UInt16(max(0, Int(entry.width) - Int(r.x))) : r.width
        let fillH = r.height == 0 ? UInt16(max(0, Int(entry.height) - Int(r.y))) : r.height
        log?.log("  ClearArea window=0x\(String(r.window, radix: 16)) at (\(r.x),\(r.y)) \(fillW)x\(fillH) (req w=\(r.width) h=\(r.height) win=\(entry.width)x\(entry.height) exposures=\(r.exposures))")
        bridge.clearArea(
            topLevel: top,
            x: r.x &+ dx, y: r.y &+ dy,
            width: fillW, height: fillH,
            background: bg
        )
    }

    public var byteOrder: ByteOrder? {
        if case .running(let bo) = phase { return bo }
        return nil
    }

    /// Append client bytes; return any bytes the server should send back.
    /// May process multiple requests in one call if they all arrived in the
    /// same chunk. May process zero requests if the chunk is partial (e.g.
    /// half a request header) — those bytes stay buffered.
    ///
    /// Bytes are queued on `outbound` during dispatch (same place async events
    /// from other threads land). The return value is whatever was queued
    /// during this call plus anything else that happened to be sitting on the
    /// queue. Production callers should generally drain `outbound` directly
    /// rather than rely on this return value, but tests use it.
    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        inbound.append(contentsOf: bytes)

        loop: while true {
            switch phase {
            case .awaitingSetup:
                guard let consumed = trySetup() else { break loop }
                inbound.removeFirst(consumed)
            case .running(let bo):
                guard let consumed = tryRequest(byteOrder: bo) else { break loop }
                inbound.removeFirst(consumed)
            }
        }
        return outbound.drain()
    }

    // MARK: - Setup

    private func trySetup() -> Int? {
        guard inbound.count >= 12 else { return nil }
        let order: ByteOrder
        switch inbound[0] {
        case 0x42: order = .msbFirst
        case 0x6C: order = .lsbFirst
        default:
            log?.log("setup: invalid byte-order marker 0x\(String(inbound[0], radix: 16))")
            // Can't proceed; close by signaling no progress and let the
            // transport decide. We keep the bytes around so the test can see
            // we made no output.
            return nil
        }

        let nameLen: Int
        let dataLen: Int
        switch order {
        case .lsbFirst:
            nameLen = Int(inbound[6]) | (Int(inbound[7]) << 8)
            dataLen = Int(inbound[8]) | (Int(inbound[9]) << 8)
        case .msbFirst:
            nameLen = (Int(inbound[6]) << 8) | Int(inbound[7])
            dataLen = (Int(inbound[8]) << 8) | Int(inbound[9])
        }
        let totalSize = 12 + nameLen + xPad(nameLen) + dataLen + xPad(dataLen)
        guard inbound.count >= totalSize else { return nil }

        do {
            _ = try SetupRequest.decode(from: Array(inbound[0..<totalSize]))
        } catch {
            log?.log("setup: decode failed: \(error)")
            return nil
        }

        let accepted = config.makeSetupAccepted()
        let bytes = SetupReply.accepted(accepted).encode(byteOrder: order)
        outbound.append(bytes)
        phase = .running(byteOrder: order)
        setupAcceptedSent = true
        log?.log("setup: accepted byteOrder=\(order)")
        return totalSize
    }

    // MARK: - Request loop

    private func tryRequest(byteOrder: ByteOrder) -> Int? {
        guard inbound.count >= 4 else { return nil }
        let lenIn4: UInt16
        switch byteOrder {
        case .lsbFirst: lenIn4 = UInt16(inbound[2]) | (UInt16(inbound[3]) << 8)
        case .msbFirst: lenIn4 = (UInt16(inbound[2]) << 8) | UInt16(inbound[3])
        }
        let totalSize = Int(lenIn4) * 4
        guard totalSize >= 4 else {
            log?.log("request: bogus length \(lenIn4) — closing")
            return nil
        }
        guard inbound.count >= totalSize else { return nil }

        let bytes = Array(inbound[0..<totalSize])
        sequenceNumber &+= 1
        requestsProcessed += 1

        do {
            let request = try Request.decode(from: bytes, byteOrder: byteOrder)
            log?.log("req[\(sequenceNumber)] \(opcodeName(request))")
            dispatch(request, byteOrder: byteOrder)
        } catch {
            log?.log("request: decode error opcode=\(bytes[0]) seq=\(sequenceNumber): \(error)")
            // M1: don't synthesize XError for decode failures yet — for our
            // capture corpus, decode is trusted. If a real client sends bytes
            // we can't decode, that's a framer bug, not a protocol error.
        }
        return totalSize
    }

    // MARK: - Dispatch

    private func dispatch(_ request: Request, byteOrder: ByteOrder) {
        switch request {

        case .createWindow(let r):
            let mask = r.valueMask
            let eventMask = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CW.eventMask, byteOrder: byteOrder) ?? 0
            let entry = WindowEntry(
                id: r.wid, parent: r.parent, depth: r.depth,
                x: r.x, y: r.y, width: r.width, height: r.height,
                borderWidth: r.borderWidth, windowClass: r.windowClass, visual: r.visual,
                valueMask: mask, valueList: r.valueList,
                mapped: false, eventMask: eventMask
            )
            windows.insert(entry)
            let isTop = r.parent == config.rootWindowId
            log?.log("  CreateWindow wid=0x\(String(r.wid, radix: 16)) parent=0x\(String(r.parent, radix: 16)) \(r.width)x\(r.height) at (\(r.x),\(r.y)) eventMask=0x\(String(eventMask, radix: 16)) topLevel=\(isTop)")
            if isTop {
                bridge?.registerTopLevel(
                    id: r.wid,
                    geometry: TopLevelGeometry(
                        x: r.x, y: r.y, width: r.width, height: r.height,
                        borderWidth: r.borderWidth
                    ),
                    eventMask: eventMask
                )
            }

        case .changeWindowAttributes(let r):
            if let newMask = ValueListReader.read(valueList: r.valueList, mask: r.valueMask, bit: CW.eventMask, byteOrder: byteOrder) {
                windows.setEventMask(r.window, newMask)
            }

        case .destroyWindow(let r):
            let wasTopLevel = isTopLevel(r.window)
            windows.remove(r.window)
            properties.deleteAll(window: r.window)
            if wasTopLevel {
                bridge?.destroyTopLevel(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
            }

        case .mapWindow(let r):
            windows.setMapped(r.window, true)
            let isTop = isTopLevel(r.window)
            log?.log("  MapWindow window=0x\(String(r.window, radix: 16)) topLevel=\(isTop)")
            if isTop {
                let descendants = mappedDescendantSnapshots(of: r.window)
                let entry = windows.get(r.window)
                let topMask = entry?.eventMask ?? 0
                let currentGeom = entry.map { TopLevelGeometry(
                    x: $0.x, y: $0.y,
                    width: $0.width, height: $0.height,
                    borderWidth: $0.borderWidth
                ) } ?? TopLevelGeometry(x: 0, y: 0, width: 1, height: 1, borderWidth: 0)
                bridge?.mapTopLevel(
                    id: r.window, geometry: currentGeom,
                    eventMask: topMask, descendants: descendants,
                    byteOrder: byteOrder, sequence: sequenceNumber,
                    outbound: outbound
                )
            } else {
                bridge?.mapDescendant(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
            }

        case .mapSubwindows(let r):
            for (_, w) in windows.windows where w.parent == r.window {
                windows.setMapped(w.id, true)
                bridge?.mapDescendant(
                    id: w.id, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
            }

        case .unmapWindow(let r):
            windows.setMapped(r.window, false)
            if isTopLevel(r.window) {
                bridge?.unmapTopLevel(
                    id: r.window, byteOrder: byteOrder,
                    sequence: sequenceNumber, outbound: outbound
                )
            }

        case .configureWindow(let r):
            let mask = UInt32(r.valueMask)
            let x = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.x, byteOrder: byteOrder).map { Int16(truncatingIfNeeded: $0) }
            let y = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.y, byteOrder: byteOrder).map { Int16(truncatingIfNeeded: $0) }
            let w = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.width, byteOrder: byteOrder).map { UInt16(truncatingIfNeeded: $0) }
            let h = ValueListReader.read(valueList: r.valueList, mask: mask, bit: CWindow.height, byteOrder: byteOrder).map { UInt16(truncatingIfNeeded: $0) }
            log?.log("  ConfigureWindow window=0x\(String(r.window, radix: 16)) mask=0x\(String(r.valueMask, radix: 16)) x=\(x.map(String.init) ?? "-") y=\(y.map(String.init) ?? "-") w=\(w.map(String.init) ?? "-") h=\(h.map(String.init) ?? "-")")
            let result = windows.resize(r.window, width: w, height: h, x: x, y: y)
            if let (old, new) = result, let entry = windows.get(r.window) {
                if entry.parent != config.rootWindowId {
                    bridge?.descendantResized(
                        id: r.window, parent: entry.parent,
                        geometry: TopLevelGeometry(
                            x: entry.x, y: entry.y,
                            width: entry.width, height: entry.height,
                            borderWidth: entry.borderWidth
                        )
                    )
                }
                let sizeChanged = old.width != new.width || old.height != new.height
                let posChanged = old.x != new.x || old.y != new.y
                // Per X11 spec: emit ConfigureNotify if the configuration
                // actually changed, on every window with StructureNotifyMask
                // set in its event mask. xterm's Xt geometry manager waits
                // for this synchronous confirmation before completing widget
                // realization — without it, Xt does a probing ping-pong
                // resize that wipes xterm's screen buffer.
                let structureNotifyMask: UInt32 = 1 << 17
                if (sizeChanged || posChanged) && (entry.eventMask & structureNotifyMask != 0) {
                    log?.log("  → emit ConfigureNotify on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height) at (\(new.x),\(new.y))")
                    let cfgEv = ConfigureNotifyEvent(
                        sequenceNumber: sequenceNumber,
                        event: r.window, window: r.window, aboveSibling: 0,
                        x: new.x, y: new.y,
                        width: new.width, height: new.height,
                        borderWidth: new.borderWidth,
                        overrideRedirect: false
                    )
                    outbound.append(cfgEv.encode(byteOrder: byteOrder))
                }
                // Per X11 spec: Expose only on size GROW (newly visible
                // area). Shrinking just hides content.
                let sizeGrew = new.width > old.width || new.height > old.height
                if sizeGrew && (entry.eventMask & MockWindowBridge.exposureMask != 0) {
                    log?.log("  → emit Expose on 0x\(String(r.window, radix: 16)) \(new.width)x\(new.height)")
                    let expose = ExposeEvent(
                        sequenceNumber: sequenceNumber, window: r.window,
                        x: 0, y: 0, width: new.width, height: new.height, count: 0
                    )
                    outbound.append(expose.encode(byteOrder: byteOrder))
                }
            }

        case .internAtom(let r):
            let name = String(decoding: r.name, as: UTF8.self)
            let atom = r.onlyIfExists ? atoms.lookupOrZero(name) : atoms.intern(name)
            let reply = InternAtomReply(sequenceNumber: sequenceNumber, atom: atom)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .changeProperty(let r):
            properties.change(
                window: r.window, property: r.property, type: r.type,
                format: r.format.rawValue, mode: r.mode.rawValue, value: r.data
            )
            // WM_NAME or WM_ICON_NAME (39 / 37) → push to NSWindow title.
            // Strip trailing nulls — real Xlib clients sometimes include the
            // C string terminator in the property data, sometimes not.
            if r.property == 39 || r.property == 37 {
                let trimmed = r.data.prefix(while: { $0 != 0 })
                let title = String(decoding: trimmed, as: UTF8.self)
                bridge?.setTopLevelTitle(id: r.window, title: title)
            }

        case .deleteProperty(let r):
            properties.delete(window: r.window, property: r.property)

        case .getProperty(let r):
            let reply: GetPropertyReply
            if let entry = properties.get(window: r.window, property: r.property) {
                reply = GetPropertyReply(
                    sequenceNumber: sequenceNumber,
                    format: entry.format,
                    type: entry.type,
                    bytesAfter: 0,
                    value: entry.value
                )
            } else {
                reply = GetPropertyReply.empty(sequenceNumber: sequenceNumber)
            }
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .openFont(let r):
            // Parse the font name (XLFD or alias), resolve to a Mac substitute
            // with cell-snapped metrics. Stored on the FontEntry so QueryFont
            // and any future text-rendering dispatch can answer without
            // re-parsing.
            let nameStr = String(decoding: r.name, as: UTF8.self)
            let resolved = FontResolver.resolve(name: nameStr)
            fonts.insert(FontEntry(id: r.fid, name: r.name, resolved: resolved))

        case .closeFont(let r):
            fonts.remove(r.font)

        case .queryFont(let r):
            // Look up the font and answer with cell-snapped metrics derived
            // from the resolved Mac substitute. Per
            // SERVER_RESOLUTION_SCALING_AND_FONTS.md "critical invariant":
            // the metrics we report must match what we actually render.
            let resolved = fonts.get(r.font)?.resolved
                ?? FontResolver.resolve(name: "fixed")
            let reply = makeQueryFontReply(resolved: resolved, sequence: sequenceNumber)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .createPixmap(let r):
            pixmaps.insert(PixmapEntry(id: r.pid, drawable: r.drawable, depth: r.depth, width: r.width, height: r.height))

        case .freePixmap(let r):
            pixmaps.remove(r.pixmap)

        case .createGC(let r):
            gcs.insert(GCEntry(id: r.cid, drawable: r.drawable, valueMask: r.valueMask, valueList: r.valueList))

        case .changeGC(let r):
            gcs.change(r.gc, valueMask: r.valueMask, valueList: r.valueList)

        case .freeGC(let r):
            gcs.remove(r.gc)

        case .allocColor(let r):
            let allocated = colors.allocate(red: r.red, green: r.green, blue: r.blue)
            let reply = AllocColorReply(
                sequenceNumber: sequenceNumber,
                red: allocated.allocated.red,
                green: allocated.allocated.green,
                blue: allocated.allocated.blue,
                pixel: allocated.pixel
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getInputFocus:
            let reply = GetInputFocusReply(
                sequenceNumber: sequenceNumber,
                revertTo: .none,
                focus: 0
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryExtension:
            let reply = QueryExtensionReply(
                sequenceNumber: sequenceNumber,
                present: false, majorOpcode: 0, firstEvent: 0, firstError: 0
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .polySegment(let r):
            handlePolySegment(r, byteOrder: byteOrder)

        case .polyLine(let r):
            handlePolyLine(r, byteOrder: byteOrder)

        case .fillPoly(let r):
            handleFillPoly(r, byteOrder: byteOrder)

        case .clearArea(let r):
            handleClearArea(r, byteOrder: byteOrder)

        case .polyFillRectangle(let r):
            handlePolyFillRectangle(r, byteOrder: byteOrder)

        case .imageText8(let r):
            handleImageText8(r, byteOrder: byteOrder)

        case .copyArea(let r):
            handleCopyArea(r, byteOrder: byteOrder)

        // Silent no-ops: requests xclock or other apps may issue that we
        // don't yet wire to rendering. Add real handlers as needed.
        case .polyArc, .polyRectangle,
             .polyFillArc,
             .setClipRectangles, .setDashes, .putImage, .polyText8,
             .sendEvent, .reparentWindow, .destroySubwindows,
             .grabPointer, .ungrabPointer, .grabButton, .grabKeyboard,
             .ungrabKeyboard, .grabKey, .allowEvents, .grabServer, .ungrabServer,
             .warpPointer, .setInputFocus, .createGlyphCursor, .freeCursor,
             .recolorCursor, .bell, .unmapSubwindows:
            break

        case .listFonts(let r):
            // Pattern-match against the synthesized Phase-1 font list.
            let pattern = String(decoding: r.pattern, as: UTF8.self)
            let names = SynthesizedFonts.match(pattern: pattern, max: Int(r.maxNames))
            let reply = ListFontsReply(sequenceNumber: sequenceNumber, names: names)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getKeyboardMapping(let r):
            let keysyms = DefaultKeyboardMap.keysyms(firstKeycode: r.firstKeycode, count: r.count)
            let reply = GetKeyboardMappingReply(
                sequenceNumber: sequenceNumber,
                keysymsPerKeycode: DefaultKeyboardMap.keysymsPerKeycode,
                keysyms: keysyms
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getModifierMapping:
            let reply = GetModifierMappingReply(
                sequenceNumber: sequenceNumber,
                keycodesPerModifier: DefaultModifierMap.keycodesPerModifier,
                keycodes: DefaultModifierMap.keycodes
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getPointerMapping:
            let reply = GetPointerMappingReply(
                sequenceNumber: sequenceNumber,
                map: DefaultPointerMap.map
            )
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .queryColors(let r):
            // Look up each requested pixel in our ColorTable; unknown pixels
            // resolve to black (consistent with the dispatch-time fallback).
            let entries: [QueryColorsRGB] = r.pixels.map { pixel in
                let rgb = colors.rgb(for: pixel) ?? RGB16(red: 0, green: 0, blue: 0)
                return QueryColorsRGB(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
            let reply = QueryColorsReply(sequenceNumber: sequenceNumber, colors: entries)
            outbound.append(reply.encode(byteOrder: byteOrder))

        case .getSelectionOwner:
            // We don't track selection ownership yet — return None so xterm
            // proceeds (it'll just show "selection unavailable" to itself).
            // Phase 4 polish wires up real PRIMARY/CLIPBOARD ↔ NSPasteboard.
            let reply = GetSelectionOwnerReply(sequenceNumber: sequenceNumber, owner: 0)
            outbound.append(reply.encode(byteOrder: byteOrder))

        // SetSelectionOwner has no reply per X11 spec — silent no-op for now
        // since we don't track selection state.
        case .setSelectionOwner:
            break

        // Replies we don't yet implement — note them so the live test surfaces
        // what's missing without dropping the connection.
        case .getWindowAttributes, .getGeometry, .queryTree,
             .getAtomName,
             .translateCoordinates, .queryPointer,
             .lookupColor, .allocNamedColor,
             .queryBestSize, .listExtensions,
             .queryKeymap:
            log?.log("dispatch: reply for \(opcodeName(request)) not implemented yet")

        case .unknown(let op, _):
            unknownOpcodes.append(op)
            let n = opcodeName(op) ?? "unknown"
            log?.log("dispatch: unknown opcode \(op) (\(n))")
        }
    }
}

// Pull the Request enum's opcode tag for logging. Cheap and exhaustive enough
// that the compiler tells us when we add a new case.
private func opcodeName(_ request: Request) -> String {
    switch request {
    case .createWindow: return "CreateWindow"
    case .changeWindowAttributes: return "ChangeWindowAttributes"
    case .getWindowAttributes: return "GetWindowAttributes"
    case .destroyWindow: return "DestroyWindow"
    case .destroySubwindows: return "DestroySubwindows"
    case .reparentWindow: return "ReparentWindow"
    case .mapWindow: return "MapWindow"
    case .mapSubwindows: return "MapSubwindows"
    case .unmapWindow: return "UnmapWindow"
    case .unmapSubwindows: return "UnmapSubwindows"
    case .configureWindow: return "ConfigureWindow"
    case .getGeometry: return "GetGeometry"
    case .queryTree: return "QueryTree"
    case .internAtom: return "InternAtom"
    case .getAtomName: return "GetAtomName"
    case .changeProperty: return "ChangeProperty"
    case .deleteProperty: return "DeleteProperty"
    case .getProperty: return "GetProperty"
    case .setSelectionOwner: return "SetSelectionOwner"
    case .getSelectionOwner: return "GetSelectionOwner"
    case .sendEvent: return "SendEvent"
    case .grabPointer: return "GrabPointer"
    case .ungrabPointer: return "UngrabPointer"
    case .grabButton: return "GrabButton"
    case .grabKeyboard: return "GrabKeyboard"
    case .ungrabKeyboard: return "UngrabKeyboard"
    case .grabKey: return "GrabKey"
    case .allowEvents: return "AllowEvents"
    case .grabServer: return "GrabServer"
    case .ungrabServer: return "UngrabServer"
    case .queryPointer: return "QueryPointer"
    case .translateCoordinates: return "TranslateCoordinates"
    case .warpPointer: return "WarpPointer"
    case .setInputFocus: return "SetInputFocus"
    case .getInputFocus: return "GetInputFocus"
    case .queryKeymap: return "QueryKeymap"
    case .openFont: return "OpenFont"
    case .closeFont: return "CloseFont"
    case .queryFont: return "QueryFont"
    case .listFonts: return "ListFonts"
    case .createPixmap: return "CreatePixmap"
    case .freePixmap: return "FreePixmap"
    case .createGC: return "CreateGC"
    case .freeGC: return "FreeGC"
    case .setDashes: return "SetDashes"
    case .setClipRectangles: return "SetClipRectangles"
    case .clearArea: return "ClearArea"
    case .copyArea: return "CopyArea"
    case .changeGC: return "ChangeGC"
    case .polyLine: return "PolyLine"
    case .polySegment: return "PolySegment"
    case .polyArc: return "PolyArc"
    case .fillPoly: return "FillPoly"
    case .polyRectangle: return "PolyRectangle"
    case .polyFillRectangle: return "PolyFillRectangle"
    case .polyFillArc: return "PolyFillArc"
    case .putImage: return "PutImage"
    case .polyText8: return "PolyText8"
    case .imageText8: return "ImageText8"
    case .allocColor: return "AllocColor"
    case .allocNamedColor: return "AllocNamedColor"
    case .queryColors: return "QueryColors"
    case .lookupColor: return "LookupColor"
    case .queryBestSize: return "QueryBestSize"
    case .queryExtension: return "QueryExtension"
    case .bell: return "Bell"
    case .createGlyphCursor: return "CreateGlyphCursor"
    case .freeCursor: return "FreeCursor"
    case .recolorCursor: return "RecolorCursor"
    case .listExtensions: return "ListExtensions"
    case .getKeyboardMapping: return "GetKeyboardMapping"
    case .getModifierMapping: return "GetModifierMapping"
    case .getPointerMapping: return "GetPointerMapping"
    case .unknown(let op, _): return "unknown(\(op))"
    }
}
