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

    private func handleClearArea(_ r: ClearArea, byteOrder: ByteOrder) {
        guard let bridge = bridge,
              let (top, dx, dy) = topLevelAndOffset(for: r.window),
              let entry = windows.get(r.window) else { return }
        let bg = windowBackground(r.window, byteOrder: byteOrder)
        // X11 spec: if width is 0, fill to window's right edge; if height is 0,
        // fill to bottom.
        let fillW = r.width == 0 ? UInt16(max(0, Int(entry.width) - Int(r.x))) : r.width
        let fillH = r.height == 0 ? UInt16(max(0, Int(entry.height) - Int(r.y))) : r.height
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
            if r.parent == config.rootWindowId {
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
            if isTopLevel(r.window) {
                let descendants = mappedDescendantSnapshots(of: r.window)
                let topMask = windows.get(r.window)?.eventMask ?? 0
                bridge?.mapTopLevel(
                    id: r.window, eventMask: topMask, descendants: descendants,
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
            windows.resize(r.window, width: w, height: h, x: x, y: y)
            if let entry = windows.get(r.window), entry.parent != config.rootWindowId {
                bridge?.descendantResized(
                    id: r.window, parent: entry.parent,
                    geometry: TopLevelGeometry(
                        x: entry.x, y: entry.y,
                        width: entry.width, height: entry.height,
                        borderWidth: entry.borderWidth
                    )
                )
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
            fonts.insert(FontEntry(id: r.fid, name: r.name))

        case .closeFont(let r):
            fonts.remove(r.font)

        case .queryFont:
            // Stub reply — xclock asks for metrics it never uses. See SHORTCUTS.md.
            let reply = QueryFontReply(
                sequenceNumber: sequenceNumber,
                minBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 6, characterWidth: 6, ascent: 11, descent: 2, attributes: 0),
                maxBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 6, characterWidth: 6, ascent: 11, descent: 2, attributes: 0),
                minCharOrByte2: 32, maxCharOrByte2: 126, defaultChar: 32,
                drawDirection: .leftToRight,
                minByte1: 0, maxByte1: 0, allCharsExist: true,
                fontAscent: 11, fontDescent: 2,
                properties: [], charInfos: []
            )
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

        // Silent no-ops: requests xclock or other apps may issue that we
        // don't yet wire to rendering. Add real handlers as needed.
        case .polyArc, .polyRectangle,
             .polyFillRectangle, .polyFillArc, .copyArea,
             .setClipRectangles, .setDashes, .putImage, .imageText8, .polyText8,
             .sendEvent, .reparentWindow, .destroySubwindows,
             .grabPointer, .ungrabPointer, .grabButton, .grabKeyboard,
             .ungrabKeyboard, .grabKey, .allowEvents, .grabServer, .ungrabServer,
             .warpPointer, .setInputFocus, .createGlyphCursor, .freeCursor,
             .recolorCursor, .bell, .unmapSubwindows:
            break

        // Replies we don't yet implement — note them so the live test surfaces
        // what's missing without dropping the connection.
        case .getWindowAttributes, .getGeometry, .queryTree,
             .getAtomName, .getSelectionOwner, .setSelectionOwner,
             .queryPointer, .translateCoordinates,
             .listFonts, .queryColors, .lookupColor, .allocNamedColor,
             .queryBestSize, .listExtensions,
             .getKeyboardMapping, .getModifierMapping, .getPointerMapping, .queryKeymap:
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
