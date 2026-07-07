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
        var typedOpcodes: Set<UInt8> = []
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
                if case .unknown = req {
                    unknownRequests += 1
                } else {
                    typedOpcodes.insert(opcode)
                }
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
            let typedMark = typedOpcodes.contains(opcode) ? " [typed]" : ""
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

}
