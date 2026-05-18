import Foundation
import Framer

// Walks a .xtap chronologically and prints one line per X11 message:
// timestamp, direction, message kind, key fields. Streams through both
// directions, matching replies to their requests by sequence number, and
// resolving atoms to readable names as InternAtom replies arrive.

public enum ChronoDumper {
    public static func dump(path: String) throws -> String {
        let frames = try CaptureReader.read(from: path)
        var out = "=== \(path) ===\n"

        // Determine byte order from the first c2s frame.
        var byteOrder: ByteOrder = .lsbFirst
        for f in frames where f.direction == .clientToServer && !f.bytes.isEmpty {
            byteOrder = (f.bytes[0] == 0x42) ? .msbFirst : .lsbFirst
            break
        }

        var c2s = StreamWalker()
        var s2c = StreamWalker()
        var ctx = ChronoContext()

        for frame in frames {
            switch frame.direction {
            case .clientToServer:
                c2s.append(frame.bytes, timestamp: frame.timestamp)
                while let (ts, raw) = try c2s.extractC2S(byteOrder: byteOrder, setupSeen: ctx.c2sSetupSeen) {
                    if !ctx.c2sSetupSeen {
                        ctx.c2sSetupSeen = true
                        if case .setupRequest(let r) = raw {
                            out += format(timestamp: ts, line: formatSetupRequest(r))
                        }
                    } else if case .request(let req) = raw {
                        let seq = ctx.nextSeq
                        ctx.nextSeq &+= 1
                        ctx.seqToOpcode[seq] = opcodeOf(req)
                        if case .internAtom(let ia) = req {
                            ctx.seqToInternAtomName[seq] = String(decoding: ia.name, as: UTF8.self)
                        }
                        if case .queryExtension(let qe) = req {
                            ctx.seqToQueryExtensionName[seq] = String(decoding: qe.name, as: UTF8.self)
                        }
                        out += format(timestamp: ts, direction: "→", line: formatRequest(req, seq: seq, ctx: ctx))
                    }
                }
            case .serverToClient:
                s2c.append(frame.bytes, timestamp: frame.timestamp)
                while let (ts, raw) = try s2c.extractS2C(byteOrder: byteOrder, setupSeen: ctx.s2cSetupSeen) {
                    if !ctx.s2cSetupSeen {
                        ctx.s2cSetupSeen = true
                        if case .setupReply(let r) = raw {
                            out += format(timestamp: ts, line: formatSetupReply(r))
                        }
                    } else if case .serverMessage(let m) = raw {
                        out += format(timestamp: ts, direction: "←", line: formatServerMessage(m, byteOrder: byteOrder, ctx: &ctx))
                    }
                }
            }
        }

        return out
    }
}

// MARK: - Walker state

struct StreamWalker {
    var buffer: [UInt8] = []
    var pendingChunks: [(byteCount: Int, timestamp: UInt64)] = []

    mutating func append(_ bytes: [UInt8], timestamp: UInt64) {
        buffer.append(contentsOf: bytes)
        pendingChunks.append((bytes.count, timestamp))
    }

    private var headTimestamp: UInt64 { pendingChunks.first?.timestamp ?? 0 }

    mutating func consume(_ n: Int) -> UInt64 {
        let ts = headTimestamp
        buffer.removeFirst(n)
        var remaining = n
        while remaining > 0, !pendingChunks.isEmpty {
            if pendingChunks[0].byteCount <= remaining {
                remaining -= pendingChunks[0].byteCount
                pendingChunks.removeFirst()
            } else {
                pendingChunks[0].byteCount -= remaining
                remaining = 0
            }
        }
        return ts
    }

    mutating func extractC2S(byteOrder: ByteOrder, setupSeen: Bool) throws -> (UInt64, ChronoRaw)? {
        if !setupSeen {
            guard buffer.count >= 12 else { return nil }
            let req = try SetupRequest.decode(from: buffer)
            let size = req.encode().count
            guard buffer.count >= size else { return nil }
            let ts = consume(size)
            return (ts, .setupRequest(req))
        }
        guard buffer.count >= 4 else { return nil }
        let lenIn4: UInt16
        switch byteOrder {
        case .lsbFirst: lenIn4 = UInt16(buffer[2]) | (UInt16(buffer[3]) << 8)
        case .msbFirst: lenIn4 = (UInt16(buffer[2]) << 8) | UInt16(buffer[3])
        }
        let totalSize = Int(lenIn4) * 4
        guard totalSize > 0, buffer.count >= totalSize else { return nil }
        let req = try Request.decode(from: buffer, byteOrder: byteOrder)
        let ts = consume(totalSize)
        return (ts, .request(req))
    }

    mutating func extractS2C(byteOrder: ByteOrder, setupSeen: Bool) throws -> (UInt64, ChronoRaw)? {
        if !setupSeen {
            guard buffer.count >= 8 else { return nil }
            let lenIn4: UInt16
            switch byteOrder {
            case .lsbFirst: lenIn4 = UInt16(buffer[6]) | (UInt16(buffer[7]) << 8)
            case .msbFirst: lenIn4 = (UInt16(buffer[6]) << 8) | UInt16(buffer[7])
            }
            let totalSize = 8 + Int(lenIn4) * 4
            guard buffer.count >= totalSize else { return nil }
            let reply = try SetupReply.decode(from: buffer, byteOrder: byteOrder)
            let ts = consume(totalSize)
            return (ts, .setupReply(reply))
        }
        guard buffer.count >= 32 else { return nil }
        let totalSize: Int
        switch buffer[0] {
        case 0:
            totalSize = 32
        case 1:
            let lenIn4: UInt32
            switch byteOrder {
            case .lsbFirst:
                lenIn4 = UInt32(buffer[4]) | (UInt32(buffer[5]) << 8) | (UInt32(buffer[6]) << 16) | (UInt32(buffer[7]) << 24)
            case .msbFirst:
                lenIn4 = (UInt32(buffer[4]) << 24) | (UInt32(buffer[5]) << 16) | (UInt32(buffer[6]) << 8) | UInt32(buffer[7])
            }
            totalSize = 32 + Int(lenIn4) * 4
        default:
            totalSize = 32
        }
        guard buffer.count >= totalSize else { return nil }
        let msg = try ServerMessage.decodeOne(from: buffer, byteOrder: byteOrder)
        let ts = consume(totalSize)
        return (ts, .serverMessage(msg))
    }
}

enum ChronoRaw {
    case setupRequest(SetupRequest)
    case setupReply(SetupReply)
    case request(Request)
    case serverMessage(ServerMessage)
}

struct ChronoContext {
    var c2sSetupSeen = false
    var s2cSetupSeen = false
    var nextSeq: UInt16 = 1
    var seqToOpcode: [UInt16: UInt8] = [:]
    var seqToInternAtomName: [UInt16: String] = [:]
    var seqToQueryExtensionName: [UInt16: String] = [:]
    var atomToName: [UInt32: String] = [:]
    var extensionMajorToName: [UInt8: String] = [:]
}

// MARK: - Formatting

private func format(timestamp: UInt64, line: String) -> String {
    let ms = Double(timestamp) / 1_000_000.0
    return String(format: "%9.3fms        %@\n", ms, line as NSString) as String
}

private func format(timestamp: UInt64, direction: String, line: String) -> String {
    let ms = Double(timestamp) / 1_000_000.0
    return String(format: "%9.3fms  %@   %@\n", ms, direction as NSString, line as NSString) as String
}

func formatSetupRequest(_ r: SetupRequest) -> String {
    let auth = r.authProtocolName.isEmpty ? "(none)"
        : String(decoding: r.authProtocolName, as: UTF8.self)
    return "SetupRequest             \(r.byteOrder) proto=\(r.protocolMajor).\(r.protocolMinor) auth=\(auth)"
}

func formatSetupReply(_ r: SetupReply) -> String {
    switch r {
    case .accepted(let a):
        let vendor = String(decoding: a.vendor, as: UTF8.self)
        let screen = a.screens.first
        let geom = screen.map { "\($0.widthInPixels)x\($0.heightInPixels) depth=\($0.rootDepth)" } ?? "(no screen)"
        return "SetupAccepted            \(vendor) release=\(a.releaseNumber) \(geom)"
    case .refused(let r):
        return "SetupRefused             \"\(String(decoding: r.reason, as: UTF8.self))\""
    case .authenticate(let a):
        let s = String(decoding: a.reason, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        return "SetupAuthenticate        \"\(s)\""
    }
}

func atomDisplay(_ atom: UInt32, ctx: ChronoContext) -> String {
    if atom == 0 { return "None" }
    if let p = predefinedAtomName(atom) { return p }
    if let n = ctx.atomToName[atom] { return n }
    return String(format: "0x%X", atom)
}

func windowDisplay(_ w: UInt32) -> String {
    return String(format: "0x%X", w)
}

func formatRequest(_ req: Request, seq: UInt16, ctx: ChronoContext) -> String {
    let seqStr = String(format: "[seq=%-4d]", seq)
    let body: String
    switch req {
    case .createWindow(let r):
        body = "CreateWindow             wid=\(windowDisplay(r.wid)) parent=\(windowDisplay(r.parent)) \(r.width)x\(r.height) at (\(r.x),\(r.y)) class=\(r.windowClass) mask=0x\(String(r.valueMask, radix: 16))"
    case .changeWindowAttributes(let r):
        body = "ChangeWindowAttributes   window=\(windowDisplay(r.window)) mask=0x\(String(r.valueMask, radix: 16))"
    case .getWindowAttributes(let r):
        body = "GetWindowAttributes      window=\(windowDisplay(r.window))"
    case .destroyWindow(let r):
        body = "DestroyWindow            window=\(windowDisplay(r.window))"
    case .destroySubwindows(let r):
        body = "DestroySubwindows        window=\(windowDisplay(r.window))"
    case .reparentWindow(let r):
        body = "ReparentWindow           window=\(windowDisplay(r.window)) parent=\(windowDisplay(r.parent)) at (\(r.x),\(r.y))"
    case .mapWindow(let r):
        body = "MapWindow                window=\(windowDisplay(r.window))"
    case .mapSubwindows(let r):
        body = "MapSubwindows            window=\(windowDisplay(r.window))"
    case .unmapWindow(let r):
        body = "UnmapWindow              window=\(windowDisplay(r.window))"
    case .unmapSubwindows(let r):
        body = "UnmapSubwindows          window=\(windowDisplay(r.window))"
    case .configureWindow(let r):
        body = "ConfigureWindow          window=\(windowDisplay(r.window)) mask=0x\(String(r.valueMask, radix: 16))"
    case .getGeometry(let r):
        body = "GetGeometry              drawable=\(windowDisplay(r.drawable))"
    case .queryTree(let r):
        body = "QueryTree                window=\(windowDisplay(r.window))"
    case .internAtom(let r):
        let name = String(decoding: r.name, as: UTF8.self)
        body = "InternAtom               \"\(name)\"\(r.onlyIfExists ? " (only-if-exists)" : "")"
    case .getAtomName(let r):
        body = "GetAtomName              atom=\(atomDisplay(r.atom, ctx: ctx))"
    case .changeProperty(let r):
        let dataPreview = previewBytes(r.data, format: r.format)
        body = "ChangeProperty           window=\(windowDisplay(r.window)) prop=\(atomDisplay(r.property, ctx: ctx)) type=\(atomDisplay(r.type, ctx: ctx)) format=\(r.format.rawValue) \(dataPreview)"
    case .deleteProperty(let r):
        body = "DeleteProperty           window=\(windowDisplay(r.window)) prop=\(atomDisplay(r.property, ctx: ctx))"
    case .getProperty(let r):
        body = "GetProperty              window=\(windowDisplay(r.window)) prop=\(atomDisplay(r.property, ctx: ctx))\(r.delete ? " (delete)" : "")"
    case .setSelectionOwner(let r):
        body = "SetSelectionOwner        selection=\(atomDisplay(r.selection, ctx: ctx)) owner=\(windowDisplay(r.owner))"
    case .getSelectionOwner(let r):
        body = "GetSelectionOwner        selection=\(atomDisplay(r.selection, ctx: ctx))"
    case .convertSelection(let r):
        body = "ConvertSelection         selection=\(atomDisplay(r.selection, ctx: ctx)) target=\(atomDisplay(r.target, ctx: ctx)) prop=\(atomDisplay(r.property, ctx: ctx)) requestor=\(windowDisplay(r.requestor))"
    case .sendEvent(let r):
        body = "SendEvent                dest=\(windowDisplay(r.destination)) propagate=\(r.propagate)"
    case .grabPointer:
        body = "GrabPointer"
    case .ungrabPointer:
        body = "UngrabPointer"
    case .grabButton(let r):
        body = "GrabButton               window=\(windowDisplay(r.grabWindow)) button=\(r.button) modifiers=0x\(String(r.modifiers, radix: 16))"
    case .changeActivePointerGrab(let r):
        body = "ChangeActivePointerGrab  cursor=0x\(String(r.cursor, radix: 16)) eventMask=0x\(String(r.eventMask, radix: 16))"
    case .grabKeyboard(let r):
        body = "GrabKeyboard             window=\(windowDisplay(r.grabWindow))"
    case .ungrabKeyboard:
        body = "UngrabKeyboard"
    case .grabKey(let r):
        body = "GrabKey                  window=\(windowDisplay(r.grabWindow)) key=\(r.key) modifiers=0x\(String(r.modifiers, radix: 16))"
    case .allowEvents(let r):
        body = "AllowEvents              mode=\(r.mode)"
    case .grabServer:    body = "GrabServer"
    case .ungrabServer:  body = "UngrabServer"
    case .queryPointer(let r):
        body = "QueryPointer             window=\(windowDisplay(r.window))"
    case .translateCoordinates(let r):
        body = "TranslateCoordinates     src=\(windowDisplay(r.srcWindow)) dst=\(windowDisplay(r.dstWindow)) (\(r.srcX),\(r.srcY))"
    case .warpPointer(let r):
        body = "WarpPointer              dst=\(windowDisplay(r.dstWindow)) (\(r.dstX),\(r.dstY))"
    case .setInputFocus(let r):
        body = "SetInputFocus            focus=\(windowDisplay(r.focus)) revertTo=\(r.revertTo)"
    case .getInputFocus:    body = "GetInputFocus"
    case .queryKeymap:      body = "QueryKeymap"
    case .openFont(let r):
        body = "OpenFont                 fid=\(windowDisplay(r.fid)) name=\"\(String(decoding: r.name, as: UTF8.self))\""
    case .closeFont(let r):
        body = "CloseFont                font=\(windowDisplay(r.font))"
    case .queryFont(let r):
        body = "QueryFont                font=\(windowDisplay(r.font))"
    case .listFonts(let r):
        body = "ListFonts                pattern=\"\(String(decoding: r.pattern, as: UTF8.self))\" max=\(r.maxNames)"
    case .createPixmap(let r):
        body = "CreatePixmap             pid=\(windowDisplay(r.pid)) drawable=\(windowDisplay(r.drawable)) \(r.width)x\(r.height) depth=\(r.depth)"
    case .freePixmap(let r):
        body = "FreePixmap               pixmap=\(windowDisplay(r.pixmap))"
    case .createGC(let r):
        body = "CreateGC                 cid=\(windowDisplay(r.cid)) drawable=\(windowDisplay(r.drawable)) mask=0x\(String(r.valueMask, radix: 16))"
    case .changeGC(let r):
        body = "ChangeGC                 gc=\(windowDisplay(r.gc)) mask=0x\(String(r.valueMask, radix: 16))"
    case .freeGC(let r):
        body = "FreeGC                   gc=\(windowDisplay(r.gc))"
    case .setDashes(let r):
        body = "SetDashes                gc=\(windowDisplay(r.gc)) offset=\(r.dashOffset) dashes=\(r.dashes.count)"
    case .setClipRectangles(let r):
        body = "SetClipRectangles        gc=\(windowDisplay(r.gc)) origin=(\(r.clipXOrigin),\(r.clipYOrigin)) rects=\(r.rectangles.count)"
    case .clearArea(let r):
        body = "ClearArea                window=\(windowDisplay(r.window)) (\(r.x),\(r.y)) \(r.width)x\(r.height) exposures=\(r.exposures)"
    case .copyArea(let r):
        body = "CopyArea                 src=\(windowDisplay(r.srcDrawable)) dst=\(windowDisplay(r.dstDrawable)) gc=\(windowDisplay(r.gc)) (\(r.srcX),\(r.srcY))→(\(r.dstX),\(r.dstY)) \(r.width)x\(r.height)"
    case .polyLine(let r):
        body = "PolyLine                 drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) points=\(r.points.count)"
    case .polySegment(let r):
        body = "PolySegment              drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) segments=\(r.segments.count)"
    case .polyArc(let r):
        body = "PolyArc                  drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) arcs=\(r.arcs.count)"
    case .fillPoly(let r):
        body = "FillPoly                 drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) points=\(r.points.count) shape=\(r.shape)"
    case .polyRectangle(let r):
        body = "PolyRectangle            drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) rects=\(r.rectangles.count)"
    case .polyFillRectangle(let r):
        body = "PolyFillRectangle        drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) rects=\(r.rectangles.count)"
    case .polyFillArc(let r):
        body = "PolyFillArc              drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) arcs=\(r.arcs.count)"
    case .putImage(let r):
        body = "PutImage                 drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) \(r.width)x\(r.height) at (\(r.dstX),\(r.dstY)) format=\(r.format) depth=\(r.depth) data=\(r.data.count)b"
    case .polyText8(let r):
        body = "PolyText8                drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at (\(r.x),\(r.y)) items=\(r.items.count)b"
    case .imageText8(let r):
        let s = String(decoding: r.string, as: UTF8.self)
        body = "ImageText8               drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at (\(r.x),\(r.y)) \"\(s)\""
    case .allocColor(let r):
        body = "AllocColor               cmap=\(windowDisplay(r.cmap)) rgb=(\(r.red),\(r.green),\(r.blue))"
    case .allocNamedColor(let r):
        body = "AllocNamedColor          cmap=\(windowDisplay(r.cmap)) name=\"\(String(decoding: r.name, as: UTF8.self))\""
    case .queryColors(let r):
        body = "QueryColors              cmap=\(windowDisplay(r.cmap)) pixels=\(r.pixels.count)"
    case .lookupColor(let r):
        body = "LookupColor              cmap=\(windowDisplay(r.cmap)) name=\"\(String(decoding: r.name, as: UTF8.self))\""
    case .createCursor(let r):
        body = "CreateCursor             cid=\(windowDisplay(r.cid)) source=\(windowDisplay(r.source)) mask=\(windowDisplay(r.mask)) hotspot=(\(r.x),\(r.y))"
    case .createGlyphCursor(let r):
        body = "CreateGlyphCursor        cid=\(windowDisplay(r.cid)) sourceFont=\(windowDisplay(r.sourceFont)) char=\(r.sourceChar)"
    case .freeCursor(let r):
        body = "FreeCursor               cursor=\(windowDisplay(r.cursor))"
    case .recolorCursor(let r):
        body = "RecolorCursor            cursor=\(windowDisplay(r.cursor))"
    case .queryBestSize(let r):
        body = "QueryBestSize            class=\(r.sizeClass) drawable=\(windowDisplay(r.drawable)) \(r.width)x\(r.height)"
    case .queryExtension(let r):
        body = "QueryExtension           name=\"\(String(decoding: r.name, as: UTF8.self))\""
    case .listExtensions:    body = "ListExtensions"
    case .getKeyboardMapping(let r):
        body = "GetKeyboardMapping       firstKeycode=\(r.firstKeycode) count=\(r.count)"
    case .getModifierMapping: body = "GetModifierMapping"
    case .getPointerMapping:  body = "GetPointerMapping"
    case .ungrabButton(let r):
        body = "UngrabButton             button=\(r.button) grabWindow=0x\(String(r.grabWindow, radix: 16)) modifiers=0x\(String(r.modifiers, radix: 16))"
    case .ungrabKey(let r):
        body = "UngrabKey                key=\(r.key) grabWindow=0x\(String(r.grabWindow, radix: 16)) modifiers=0x\(String(r.modifiers, radix: 16))"
    case .getMotionEvents(let r):
        body = "GetMotionEvents          window=0x\(String(r.window, radix: 16)) start=\(r.start) stop=\(r.stop)"
    case .allocColorCells(let r):
        body = "AllocColorCells          cmap=0x\(String(r.cmap, radix: 16)) colors=\(r.colors) planes=\(r.planes) contiguous=\(r.contiguous)"
    case .setCloseDownMode(let r):
        body = "SetCloseDownMode         mode=\(r.mode)"
    case .killClient(let r):
        body = "KillClient               resource=0x\(String(r.resource, radix: 16))"
    case .noOperation:
        body = "NoOperation"
    case .createColormap(let r):
        body = "CreateColormap           mid=0x\(String(r.mid, radix: 16)) window=0x\(String(r.window, radix: 16)) visual=0x\(String(r.visual, radix: 16)) alloc=\(r.alloc)"
    case .freeColormap(let r):
        body = "FreeColormap             cmap=0x\(String(r.cmap, radix: 16))"
    case .copyColormapAndFree(let r):
        body = "CopyColormapAndFree      mid=0x\(String(r.mid, radix: 16)) srcCmap=0x\(String(r.srcCmap, radix: 16))"
    case .installColormap(let r):
        body = "InstallColormap          cmap=0x\(String(r.cmap, radix: 16))"
    case .uninstallColormap(let r):
        body = "UninstallColormap        cmap=0x\(String(r.cmap, radix: 16))"
    case .listInstalledColormaps(let r):
        body = "ListInstalledColormaps   window=0x\(String(r.window, radix: 16))"
    case .allocColorPlanes(let r):
        body = "AllocColorPlanes         cmap=0x\(String(r.cmap, radix: 16)) colors=\(r.colors) rgb=\(r.red)/\(r.green)/\(r.blue) contiguous=\(r.contiguous)"
    case .freeColors(let r):
        body = "FreeColors               cmap=0x\(String(r.cmap, radix: 16)) planeMask=0x\(String(r.planeMask, radix: 16)) pixels=\(r.pixels.count)"
    case .storeColors(let r):
        body = "StoreColors              cmap=0x\(String(r.cmap, radix: 16)) items=\(r.rawItems.count / 12)"
    case .storeNamedColor(let r):
        body = "StoreNamedColor          cmap=0x\(String(r.cmap, radix: 16)) pixel=\(r.pixel) name=\"\(String(decoding: r.name, as: UTF8.self))\" flags=0x\(String(r.flags, radix: 16))"
    case .circulateWindow(let r):
        body = "CirculateWindow          window=0x\(String(r.window, radix: 16)) direction=\(r.direction == 0 ? "RaiseLowest" : "LowerHighest")"
    case .queryTextExtents(let r):
        body = "QueryTextExtents         fid=0x\(String(r.fid, radix: 16)) nChars=\(r.stringBytes.count / 2)"
    case .polyPoint(let r):
        body = "PolyPoint                drawable=0x\(String(r.drawable, radix: 16)) gc=0x\(String(r.gc, radix: 16)) mode=\(r.coordinateMode) n=\(r.points.count)"
    case .bell(let r):
        body = "Bell                     percent=\(r.percent)"
    case .unknown(let op, _):
        body = "Request opcode=\(op) (untyped)"
    }
    return "\(seqStr) \(body)"
}

func formatServerMessage(_ msg: ServerMessage, byteOrder: ByteOrder, ctx: inout ChronoContext) -> String {
    switch msg {
    case .reply(let r):
        let seq = r.sequenceNumber(byteOrder: byteOrder)
        let opcode = ctx.seqToOpcode[seq]
        let opName = opcode.flatMap { opcodeName($0) } ?? "?"
        var detail = ""
        if let op = opcode {
            if op == InternAtom.opcode, let name = ctx.seqToInternAtomName[seq] {
                if let parsed = try? InternAtomReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    if parsed.atom != 0 { ctx.atomToName[parsed.atom] = name }
                    detail = " atom=\(parsed.atom == 0 ? "None" : String(format: "0x%X", parsed.atom)) (\(name))"
                }
            }
            if op == QueryExtension.opcode, let name = ctx.seqToQueryExtensionName[seq] {
                if let parsed = try? QueryExtensionReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    if parsed.present { ctx.extensionMajorToName[parsed.majorOpcode] = name }
                    detail = " name=\(name) present=\(parsed.present) major=\(parsed.majorOpcode)"
                }
            }
            if op == QueryFont.opcode {
                if let parsed = try? QueryFontReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " ascent/descent=\(parsed.fontAscent)/\(parsed.fontDescent) chars=\(parsed.charInfos.count) properties=\(parsed.properties.count)"
                }
            }
        }
        return "[seq=\(seq)] Reply (\(opName))\(detail)"
    case .event(let e):
        let codeName = eventName(e.code) ?? "Event#\(e.code)"
        let prefix = e.sentEvent ? "[SendEvent] " : ""
        var detail = ""
        if let decoded = try? DecodedEvent.decode(from: e, byteOrder: byteOrder) {
            switch decoded {
            case .keyPress(let i), .keyRelease(let i), .buttonPress(let i), .buttonRelease(let i), .motionNotify(let i):
                detail = " keycode/btn=\(i.detail) state=0x\(String(i.state, radix: 16)) at (\(i.eventX),\(i.eventY)) window=\(windowDisplay(i.event))"
            case .enterNotify(let c), .leaveNotify(let c):
                detail = " window=\(windowDisplay(c.event)) at (\(c.eventX),\(c.eventY)) mode=\(c.mode)"
            case .focusIn(let f), .focusOut(let f):
                detail = " window=\(windowDisplay(f.event)) detail=\(f.detail) mode=\(f.mode)"
            case .expose(let ex):
                detail = " window=\(windowDisplay(ex.window)) (\(ex.x),\(ex.y)) \(ex.width)x\(ex.height) count=\(ex.count)"
            case .graphicsExposure(let ge):
                detail = " drawable=\(windowDisplay(ge.drawable)) (\(ge.x),\(ge.y)) \(ge.width)x\(ge.height)"
            case .noExposure(let ne):
                detail = " drawable=\(windowDisplay(ne.drawable))"
            case .createNotify(let cn):
                detail = " parent=\(windowDisplay(cn.parent)) window=\(windowDisplay(cn.window)) \(cn.width)x\(cn.height) at (\(cn.x),\(cn.y))"
            case .destroyNotify(let dn):
                detail = " window=\(windowDisplay(dn.window))"
            case .unmapNotify(let un):
                detail = " window=\(windowDisplay(un.window))"
            case .mapNotify(let mn):
                detail = " window=\(windowDisplay(mn.window))"
            case .mapRequest(let mr):
                detail = " window=\(windowDisplay(mr.window)) parent=\(windowDisplay(mr.parent))"
            case .reparentNotify(let rn):
                detail = " window=\(windowDisplay(rn.window)) parent=\(windowDisplay(rn.parent)) at (\(rn.x),\(rn.y))"
            case .configureNotify(let cn):
                detail = " window=\(windowDisplay(cn.window)) \(cn.width)x\(cn.height) at (\(cn.x),\(cn.y))"
            case .circulateNotify(let cn):
                detail = " window=\(windowDisplay(cn.window)) place=\(cn.place == 0 ? "Top" : "Bottom")"
            case .propertyNotify(let pn):
                detail = " window=\(windowDisplay(pn.window)) prop=\(atomDisplay(pn.atom, ctx: ctx)) state=\(pn.state)"
            case .selectionClear(let sc):
                detail = " selection=\(atomDisplay(sc.selection, ctx: ctx)) owner=\(windowDisplay(sc.owner))"
            case .selectionRequest(let sr):
                detail = " selection=\(atomDisplay(sr.selection, ctx: ctx)) target=\(atomDisplay(sr.target, ctx: ctx))"
            case .selectionNotify(let sn):
                detail = " selection=\(atomDisplay(sn.selection, ctx: ctx)) target=\(atomDisplay(sn.target, ctx: ctx))"
            case .clientMessage(let cm):
                detail = " window=\(windowDisplay(cm.window)) type=\(atomDisplay(cm.type, ctx: ctx)) format=\(cm.format.rawValue)"
            case .mappingNotify(let mn):
                detail = " request=\(mn.request)"
            case .visibilityNotify(let vn):
                detail = " window=\(windowDisplay(vn.window)) state=\(vn.state)"
            case .keymapNotify:
                detail = ""
            case .unknown:
                detail = ""
            }
        }
        return "\(prefix)\(codeName)\(detail)"
    case .xError(let err):
        let errName = errorName(err.errorCode) ?? "Error#\(err.errorCode)"
        let majorName = opcodeName(err.majorOpcode) ?? "?"
        let seq = err.sequenceNumber(byteOrder: byteOrder)
        return "[seq=\(seq)] \(errName) major=\(err.majorOpcode) (\(majorName)) bad=\(String(format: "0x%X", err.badResourceId(byteOrder: byteOrder)))"
    }
}

func opcodeOf(_ req: Request) -> UInt8 {
    switch req {
    case .createWindow:              return CreateWindow.opcode
    case .changeWindowAttributes:    return ChangeWindowAttributes.opcode
    case .getWindowAttributes:       return GetWindowAttributes.opcode
    case .destroyWindow:             return DestroyWindow.opcode
    case .destroySubwindows:         return DestroySubwindows.opcode
    case .reparentWindow:            return ReparentWindow.opcode
    case .mapWindow:                 return MapWindow.opcode
    case .mapSubwindows:             return MapSubwindows.opcode
    case .unmapWindow:               return UnmapWindow.opcode
    case .unmapSubwindows:           return UnmapSubwindows.opcode
    case .configureWindow:           return ConfigureWindow.opcode
    case .getGeometry:               return GetGeometry.opcode
    case .queryTree:                 return QueryTree.opcode
    case .internAtom:                return InternAtom.opcode
    case .getAtomName:               return GetAtomName.opcode
    case .changeProperty:            return ChangeProperty.opcode
    case .deleteProperty:            return DeleteProperty.opcode
    case .getProperty:               return GetProperty.opcode
    case .setSelectionOwner:         return SetSelectionOwner.opcode
    case .getSelectionOwner:         return GetSelectionOwner.opcode
    case .convertSelection:          return ConvertSelection.opcode
    case .sendEvent:                 return SendEvent.opcode
    case .grabPointer:               return GrabPointer.opcode
    case .ungrabPointer:             return UngrabPointer.opcode
    case .grabButton:                return GrabButton.opcode
    case .changeActivePointerGrab:   return ChangeActivePointerGrab.opcode
    case .grabKeyboard:              return GrabKeyboard.opcode
    case .ungrabKeyboard:            return UngrabKeyboard.opcode
    case .grabKey:                   return GrabKey.opcode
    case .allowEvents:               return AllowEvents.opcode
    case .grabServer:                return GrabServer.opcode
    case .ungrabServer:              return UngrabServer.opcode
    case .queryPointer:              return QueryPointer.opcode
    case .translateCoordinates:      return TranslateCoordinates.opcode
    case .warpPointer:               return WarpPointer.opcode
    case .setInputFocus:             return SetInputFocus.opcode
    case .getInputFocus:             return GetInputFocus.opcode
    case .queryKeymap:               return QueryKeymap.opcode
    case .openFont:                  return OpenFont.opcode
    case .closeFont:                 return CloseFont.opcode
    case .queryFont:                 return QueryFont.opcode
    case .listFonts:                 return ListFonts.opcode
    case .createPixmap:              return CreatePixmap.opcode
    case .freePixmap:                return FreePixmap.opcode
    case .createGC:                  return CreateGC.opcode
    case .changeGC:                  return ChangeGC.opcode
    case .freeGC:                    return FreeGC.opcode
    case .setDashes:                 return SetDashes.opcode
    case .setClipRectangles:         return SetClipRectangles.opcode
    case .clearArea:                 return ClearArea.opcode
    case .copyArea:                  return CopyArea.opcode
    case .polyLine:                  return PolyLine.opcode
    case .polySegment:               return PolySegment.opcode
    case .polyArc:                   return PolyArc.opcode
    case .fillPoly:                  return FillPoly.opcode
    case .polyRectangle:             return PolyRectangle.opcode
    case .polyFillRectangle:         return PolyFillRectangle.opcode
    case .polyFillArc:               return PolyFillArc.opcode
    case .putImage:                  return PutImage.opcode
    case .polyText8:                 return PolyText8.opcode
    case .imageText8:                return ImageText8.opcode
    case .allocColor:                return AllocColor.opcode
    case .allocNamedColor:           return AllocNamedColor.opcode
    case .queryColors:               return QueryColors.opcode
    case .lookupColor:               return LookupColor.opcode
    case .queryBestSize:             return QueryBestSize.opcode
    case .queryExtension:            return QueryExtension.opcode
    case .listExtensions:            return ListExtensions.opcode
    case .getKeyboardMapping:        return GetKeyboardMapping.opcode
    case .getModifierMapping:        return GetModifierMapping.opcode
    case .getPointerMapping:         return GetPointerMapping.opcode
    case .ungrabButton:              return UngrabButton.opcode
    case .ungrabKey:                 return UngrabKey.opcode
    case .getMotionEvents:           return GetMotionEvents.opcode
    case .allocColorCells:           return AllocColorCells.opcode
    case .setCloseDownMode:          return SetCloseDownMode.opcode
    case .killClient:                return KillClient.opcode
    case .noOperation:               return NoOperation.opcode
    case .createColormap:            return CreateColormap.opcode
    case .freeColormap:              return FreeColormap.opcode
    case .copyColormapAndFree:       return CopyColormapAndFree.opcode
    case .installColormap:           return InstallColormap.opcode
    case .uninstallColormap:         return UninstallColormap.opcode
    case .listInstalledColormaps:    return ListInstalledColormaps.opcode
    case .allocColorPlanes:          return AllocColorPlanes.opcode
    case .freeColors:                return FreeColors.opcode
    case .storeColors:               return StoreColors.opcode
    case .storeNamedColor:           return StoreNamedColor.opcode
    case .circulateWindow:           return CirculateWindow.opcode
    case .queryTextExtents:          return QueryTextExtents.opcode
    case .polyPoint:                 return PolyPoint.opcode
    case .createCursor:              return CreateCursor.opcode
    case .createGlyphCursor:         return CreateGlyphCursor.opcode
    case .freeCursor:                return FreeCursor.opcode
    case .recolorCursor:             return RecolorCursor.opcode
    case .bell:                      return Bell.opcode
    case .unknown(let op, _):        return op
    }
}

func previewBytes(_ data: [UInt8], format: PropertyFormat) -> String {
    if format == .format8 && data.count <= 64 {
        let s = String(decoding: data.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
        if !s.isEmpty {
            return "data=\"\(s)\""
        }
    }
    return "data=\(data.count)b"
}
