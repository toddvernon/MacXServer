import Foundation
import Framer

public enum DumpError: Error, Sendable {
    case requestParseFailed(offset: Int, underlying: String)
    case s2cParseFailed(offset: Int, underlying: String)
}

public enum Dumper {
    public static func summarize(path: String) throws -> String {
        let frames = try CaptureReader.read(from: path)
        var out = ""

        out += "=== \(path) ===\n"
        out += "frames: \(frames.count)\n"

        let c2sBytes = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }
        let s2cBytes = frames.filter { $0.direction == .serverToClient }.flatMap { $0.bytes }
        out += "c2s: \(c2sBytes.count) bytes\n"
        out += "s2c: \(s2cBytes.count) bytes\n\n"

        let setupReq = try SetupRequest.decode(from: c2sBytes)
        let setupReqSize = setupReq.encode().count
        let byteOrder = setupReq.byteOrder

        out += "→ SetupRequest:\n"
        out += "    byteOrder: \(byteOrder)\n"
        out += "    protocol: \(setupReq.protocolMajor).\(setupReq.protocolMinor)\n"
        let authName = String(decoding: setupReq.authProtocolName, as: UTF8.self)
        out += "    authName: \(authName.isEmpty ? "(none)" : authName)\n"
        out += "    authData: \(setupReq.authProtocolData.count) bytes\n\n"

        let setupReply = try SetupReply.decode(from: s2cBytes, byteOrder: byteOrder)
        let setupReplySize = setupReply.encode(byteOrder: byteOrder).count

        switch setupReply {
        case .refused(let r):
            out += "← SetupRefused: \(String(decoding: r.reason, as: UTF8.self))\n"
            return out
        case .authenticate(let a):
            out += "← SetupAuthenticate: \(String(decoding: a.reason, as: UTF8.self))\n"
            return out
        case .accepted(let a):
            let vendor = String(decoding: a.vendor, as: UTF8.self)
            out += "← SetupAccepted:\n"
            out += "    vendor: \(vendor)\n"
            out += "    release: \(a.releaseNumber)\n"
            out += "    protocol: \(a.protocolMajor).\(a.protocolMinor)\n"
            out += "    image byte order: \(a.imageByteOrder)\n"
            out += "    bitmap bit order: \(a.bitmapFormatBitOrder)\n"
            out += "    keycodes: \(a.minKeycode)..\(a.maxKeycode)\n"
            out += "    pixmap formats: \(a.pixmapFormats.count)\n"
            for fmt in a.pixmapFormats {
                out += "        depth=\(fmt.depth) bpp=\(fmt.bitsPerPixel) pad=\(fmt.scanlinePad)\n"
            }
            out += "    screens: \(a.screens.count)\n"
            for screen in a.screens {
                out += "        \(screen.widthInPixels)x\(screen.heightInPixels) px, "
                out += "\(screen.widthInMillimeters)x\(screen.heightInMillimeters) mm, "
                out += "rootDepth=\(screen.rootDepth), depths=\(screen.allowedDepths.count)\n"
                for depth in screen.allowedDepths {
                    let visualClasses = depth.visuals.map { "\($0.visualClass)" }.joined(separator: ",")
                    out += "            depth=\(depth.depth): \(depth.visuals.count) visuals (\(visualClasses))\n"
                }
            }
            out += "\n"
        }

        // c2s: walk requests after the setup request.
        var seqToOpcode: [UInt16: UInt8] = [:]
        var seqToInternAtomName: [UInt16: String] = [:]
        var seqToQueryExtensionName: [UInt16: String] = [:]
        var extensionMajorToName: [UInt8: String] = [:]
        var nextSeq: UInt16 = 1
        var offset = setupReqSize
        var requestCounts: [UInt8: Int] = [:]
        var totalRequests = 0
        var unknownRequests = 0
        while offset < c2sBytes.count {
            let remaining = Array(c2sBytes[offset...])
            do {
                let req = try Request.decode(from: remaining, byteOrder: byteOrder)
                let size = req.encode(byteOrder: byteOrder).count
                offset += size
                totalRequests += 1

                let opcode = opcodeOf(req)
                seqToOpcode[nextSeq] = opcode
                if case .internAtom(let ia) = req {
                    seqToInternAtomName[nextSeq] = String(decoding: ia.name, as: UTF8.self)
                }
                if case .queryExtension(let qe) = req {
                    seqToQueryExtensionName[nextSeq] = String(decoding: qe.name, as: UTF8.self)
                }
                nextSeq &+= 1
                requestCounts[opcode, default: 0] += 1
                if case .unknown = req { unknownRequests += 1 }
            } catch {
                throw DumpError.requestParseFailed(offset: offset, underlying: "\(error)")
            }
        }

        // Defer the request listing until after the s2c walk so extension opcodes
        // (128..255) can be labeled with their names from QueryExtension replies.
        let requestSummaryHeader = "Requests parsed: \(totalRequests) (\(unknownRequests) with no typed decoder)\n"
        let sortedRequests = requestCounts.sorted { (a, b) in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }

        // s2c: walk replies/events/errors after the setup reply.
        var sOffset = setupReplySize
        var replyCount = 0
        var eventCounts: [UInt8: Int] = [:]
        var errorCounts: [UInt8: Int] = [:]
        var sendEventCount = 0
        var replySizes: [Int] = []
        var replyByMatchedOpcode: [UInt8: Int] = [:]
        var replyUnmatched = 0
        var resolvedAtoms: [(name: String, atom: UInt32)] = []
        var typedEventCount = 0
        var untypedEventCount = 0
        var configureEvents: [ConfigureNotifyEvent] = []
        var propertyEventAtoms: [UInt32] = []
        var queryFontReplies: [QueryFontReply] = []
        var extensionResults: [(name: String, present: Bool, majorOpcode: UInt8, firstEvent: UInt8, firstError: UInt8)] = []
        while sOffset < s2cBytes.count {
            let remaining = Array(s2cBytes[sOffset...])
            do {
                let msg = try ServerMessage.decodeOne(from: remaining, byteOrder: byteOrder)
                sOffset += msg.bytes.count
                switch msg {
                case .reply(let r):
                    replyCount += 1
                    replySizes.append(r.bytes.count)
                    let seq = r.sequenceNumber(byteOrder: byteOrder)
                    if let op = seqToOpcode[seq] {
                        replyByMatchedOpcode[op, default: 0] += 1
                        if op == InternAtom.opcode, let name = seqToInternAtomName[seq] {
                            let parsed = try InternAtomReply.decode(from: r.bytes, byteOrder: byteOrder)
                            resolvedAtoms.append((name: name, atom: parsed.atom))
                        }
                        if op == QueryFont.opcode {
                            let parsed = try QueryFontReply.decode(from: r.bytes, byteOrder: byteOrder)
                            queryFontReplies.append(parsed)
                        }
                        if op == QueryExtension.opcode, let name = seqToQueryExtensionName[seq] {
                            let parsed = try QueryExtensionReply.decode(from: r.bytes, byteOrder: byteOrder)
                            extensionResults.append((
                                name: name,
                                present: parsed.present,
                                majorOpcode: parsed.majorOpcode,
                                firstEvent: parsed.firstEvent,
                                firstError: parsed.firstError
                            ))
                            if parsed.present && parsed.majorOpcode != 0 {
                                extensionMajorToName[parsed.majorOpcode] = name
                            }
                        }
                    } else {
                        replyUnmatched += 1
                    }
                case .event(let e):
                    eventCounts[e.code, default: 0] += 1
                    if e.sentEvent { sendEventCount += 1 }
                    let decoded = try DecodedEvent.decode(from: e, byteOrder: byteOrder)
                    if case .unknown = decoded {
                        untypedEventCount += 1
                    } else {
                        typedEventCount += 1
                    }
                    switch decoded {
                    case .configureNotify(let cn): configureEvents.append(cn)
                    case .propertyNotify(let pn): propertyEventAtoms.append(pn.atom)
                    default: break
                    }
                case .xError(let err):
                    errorCounts[err.errorCode, default: 0] += 1
                }
            } catch {
                throw DumpError.s2cParseFailed(offset: sOffset, underlying: "\(error)")
            }
        }

        out += requestSummaryHeader
        for (opcode, count) in sortedRequests {
            let name: String
            if let core = opcodeName(opcode) {
                name = core
            } else if let ext = extensionMajorToName[opcode] {
                name = "[ext: \(ext)]"
            } else if opcode >= 128 {
                name = "(extension, unidentified)"
            } else {
                name = "(unassigned)"
            }
            let typedMark = (Self.typedOpcodes.contains(opcode)) ? " [typed]" : ""
            out += "    \(String(format: "%3d", opcode)) \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(count)\(typedMark)\n"
        }
        out += "\n"

        let totalServerMsgs = replyCount + eventCounts.values.reduce(0, +) + errorCounts.values.reduce(0, +)
        out += "Server messages parsed: \(totalServerMsgs)\n"
        out += "    replies: \(replyCount) (matched to \(replyByMatchedOpcode.count) distinct request opcodes, \(replyUnmatched) unmatched)\n"
        if !replySizes.isEmpty {
            let total = replySizes.reduce(0, +)
            let largest = replySizes.max() ?? 0
            out += "        bytes total \(total), largest single reply \(largest)\n"
        }
        out += "    events: \(eventCounts.values.reduce(0, +))"
        if sendEventCount > 0 { out += " (\(sendEventCount) synthesized via SendEvent)" }
        out += "\n"
        out += "    errors: \(errorCounts.values.reduce(0, +))\n"

        if !eventCounts.isEmpty {
            out += "\nEvents: \(typedEventCount) typed, \(untypedEventCount) untyped\n"
            let sortedEvents = eventCounts.sorted { (a, b) in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }
            for (code, count) in sortedEvents {
                let name = eventName(code) ?? "(unassigned)"
                out += "    \(String(format: "%3d", code)) \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)\n"
            }
        }

        if !configureEvents.isEmpty {
            out += "\nConfigureNotify events (window resizes/moves):\n"
            for cn in configureEvents {
                out += "    window=0x\(String(cn.window, radix: 16)) "
                out += "x=\(cn.x) y=\(cn.y) w=\(cn.width) h=\(cn.height)\n"
            }
        }

        if !errorCounts.isEmpty {
            out += "\nErrors:\n"
            let sortedErrors = errorCounts.sorted { $0.value > $1.value }
            for (code, count) in sortedErrors {
                let name = errorName(code) ?? "(unassigned)"
                out += "    \(String(format: "%3d", code)) \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)\n"
            }
        }

        if !replyByMatchedOpcode.isEmpty {
            out += "\nReplies matched to request opcodes:\n"
            let sortedReplies = replyByMatchedOpcode.sorted { (a, b) in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }
            for (op, count) in sortedReplies {
                let name = opcodeName(op) ?? "(unassigned)"
                out += "    \(String(format: "%3d", op)) \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)\n"
            }
        }

        if !resolvedAtoms.isEmpty {
            out += "\nInterned atoms:\n"
            let nameWidth = resolvedAtoms.map { $0.name.count }.max() ?? 0
            for entry in resolvedAtoms {
                let padded = entry.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let atomDisplay = entry.atom == 0 ? "None" : String(format: "0x%X", entry.atom)
                out += "    \(padded)  → \(atomDisplay)\n"
            }
        }

        if !extensionResults.isEmpty {
            out += "\nQueried extensions:\n"
            for ext in extensionResults {
                if ext.present {
                    out += "    \(ext.name)  → major=\(ext.majorOpcode) firstEvent=\(ext.firstEvent) firstError=\(ext.firstError)\n"
                } else {
                    out += "    \(ext.name)  → not present\n"
                }
            }
        }

        for (i, font) in queryFontReplies.enumerated() {
            out += "\nQueryFont reply #\(i + 1):\n"
            out += "    drawDirection: \(font.drawDirection)\n"
            out += "    fontAscent/Descent: \(font.fontAscent) / \(font.fontDescent)\n"
            out += "    char range: \(font.minCharOrByte2)..\(font.maxCharOrByte2), default=\(font.defaultChar)\n"
            out += "    char info entries: \(font.charInfos.count)\n"
            out += "    min char width: \(font.minBounds.characterWidth), max: \(font.maxBounds.characterWidth)\n"
            if !font.properties.isEmpty {
                out += "    properties: \(font.properties.count)\n"
                for prop in font.properties.prefix(20) {
                    let name = predefinedAtomName(prop.name) ?? "atom=\(prop.name)"
                    out += "        \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) value=\(prop.value)\n"
                }
                if font.properties.count > 20 {
                    out += "        ... and \(font.properties.count - 20) more\n"
                }
            }
        }

        return out
    }

    private static func opcodeOf(_ req: Request) -> UInt8 {
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
        case .freeGC:                    return FreeGC.opcode
        case .setDashes:                 return SetDashes.opcode
        case .setClipRectangles:         return SetClipRectangles.opcode
        case .clearArea:                 return ClearArea.opcode
        case .copyArea:                  return CopyArea.opcode
        case .changeGC:                  return ChangeGC.opcode
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
        case .bell:                      return Bell.opcode
        case .createGlyphCursor:         return CreateGlyphCursor.opcode
        case .freeCursor:                return FreeCursor.opcode
        case .recolorCursor:             return RecolorCursor.opcode
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
        case .unknown(let op, _):        return op
        }
    }

    static let typedOpcodes: Set<UInt8> = [
        CreateWindow.opcode, ChangeWindowAttributes.opcode, GetWindowAttributes.opcode,
        DestroyWindow.opcode, DestroySubwindows.opcode, ReparentWindow.opcode,
        MapWindow.opcode, MapSubwindows.opcode, UnmapWindow.opcode, UnmapSubwindows.opcode,
        ConfigureWindow.opcode, GetGeometry.opcode, QueryTree.opcode,
        InternAtom.opcode, GetAtomName.opcode,
        ChangeProperty.opcode, DeleteProperty.opcode, GetProperty.opcode,
        SetSelectionOwner.opcode, GetSelectionOwner.opcode, SendEvent.opcode,
        GrabPointer.opcode, UngrabPointer.opcode, GrabButton.opcode,
        GrabKeyboard.opcode, UngrabKeyboard.opcode, GrabKey.opcode, AllowEvents.opcode,
        GrabServer.opcode, UngrabServer.opcode,
        QueryPointer.opcode, TranslateCoordinates.opcode, WarpPointer.opcode,
        SetInputFocus.opcode, GetInputFocus.opcode, QueryKeymap.opcode,
        OpenFont.opcode, CloseFont.opcode, QueryFont.opcode, ListFonts.opcode,
        CreatePixmap.opcode, FreePixmap.opcode,
        CreateGC.opcode, FreeGC.opcode, SetDashes.opcode, SetClipRectangles.opcode,
        ClearArea.opcode, CopyArea.opcode,
        ChangeGC.opcode,
        PolyLine.opcode, PolySegment.opcode, PolyArc.opcode,
        FillPoly.opcode, PolyRectangle.opcode, PolyFillRectangle.opcode, PolyFillArc.opcode,
        PutImage.opcode, PolyText8.opcode, ImageText8.opcode,
        AllocColor.opcode, AllocNamedColor.opcode, QueryColors.opcode, LookupColor.opcode,
        QueryBestSize.opcode, QueryExtension.opcode, Bell.opcode,
        CreateGlyphCursor.opcode, FreeCursor.opcode, RecolorCursor.opcode,
        ListExtensions.opcode,
        GetKeyboardMapping.opcode, GetModifierMapping.opcode, GetPointerMapping.opcode,
    ]
}
