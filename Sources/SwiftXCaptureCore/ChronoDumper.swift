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
        var landmarks = LandmarkDetector()
        // Track first / last activity timestamp and a few summary counters
        // for the session-end landmark. Frames before SetupRequest don't
        // count toward "session start"; ts is captured at first decoded
        // request emission instead.
        var firstTimestamp: UInt64?
        var lastTimestamp: UInt64 = 0
        var requestCount = 0
        var eventCount = 0
        var errorCount = 0

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
                        if case .getKeyboardMapping(let gk) = req {
                            ctx.seqToGetKeyboardMapping[seq] = (gk.firstKeycode, gk.count)
                        }
                        if case .changeKeyboardMapping(let ck) = req {
                            // Installed at request time; there's no reply. A
                            // subsequent GetKeyboardMapping reply will overwrite.
                            ctx.installKeysyms(firstKeycode: ck.firstKeyCode,
                                               keysymsPerKeycode: ck.keysymsPerKeycode,
                                               flat: ck.keysyms)
                        }
                        if case .getProperty(let gp) = req {
                            ctx.seqToGetPropertyAtom[seq] = gp.property
                        }
                        if case .getAtomName(let ga) = req {
                            ctx.seqToGetAtomName[seq] = ga.atom
                        }
                        trackResourceLifecycle(req, seq: seq, registry: &ctx.resources)
                        out += format(timestamp: ts, direction: "→", line: formatRequest(req, seq: seq, ctx: ctx, byteOrder: byteOrder))
                        if firstTimestamp == nil { firstTimestamp = ts }
                        lastTimestamp = ts
                        requestCount += 1
                        for lm in landmarks.afterRequest(req, byteOrder: byteOrder,
                                                          screenRoots: ctx.screenRoots,
                                                          atomToName: ctx.atomToName) {
                            out += formatLandmark(lm.text)
                        }
                    }
                }
            case .serverToClient:
                s2c.append(frame.bytes, timestamp: frame.timestamp)
                while let (ts, raw) = try s2c.extractS2C(byteOrder: byteOrder, setupSeen: ctx.s2cSetupSeen) {
                    if !ctx.s2cSetupSeen {
                        ctx.s2cSetupSeen = true
                        if case .setupReply(let r) = raw {
                            if case .accepted(let acc) = r {
                                ctx.screenRoots = Set(acc.screens.map(\.root))
                                for (idx, screen) in acc.screens.enumerated() {
                                    for d in screen.allowedDepths {
                                        for v in d.visuals {
                                            ctx.visualCatalog[v.visualId] = VisualCatalogEntry(
                                                depth: d.depth,
                                                visualClass: v.visualClass,
                                                bitsPerRgbValue: v.bitsPerRgbValue,
                                                screenIndex: idx)
                                        }
                                    }
                                }
                            }
                            out += format(timestamp: ts, line: formatSetupReply(r))
                        }
                    } else if case .serverMessage(let m) = raw {
                        out += format(timestamp: ts, direction: directionGlyph(for: m), line: formatServerMessage(m, byteOrder: byteOrder, ctx: &ctx))
                        if firstTimestamp == nil { firstTimestamp = ts }
                        lastTimestamp = ts
                        switch m {
                        case .event:   eventCount += 1
                        case .xError:  errorCount += 1
                        case .reply:   break
                        }
                        for lm in landmarks.afterServerMessage(m, byteOrder: byteOrder,
                                                                screenRoots: ctx.screenRoots,
                                                                extensionMajorToName: ctx.extensionMajorToName,
                                                                resources: ctx.resources) {
                            out += formatLandmark(lm.text)
                        }
                    }
                }
            }
        }

        // Session-end summary landmark. Emitted unconditionally — the
        // bookend frames the whole capture so a reader scanning the file
        // top-to-bottom knows when it's over and what the totals were.
        if let start = firstTimestamp, requestCount > 0 || eventCount > 0 {
            let elapsedMs = Double(lastTimestamp &- start) / 1_000_000.0
            let elapsedPhrase = formatElapsed(ms: elapsedMs)
            var parts: [String] = ["\(requestCount) requests"]
            if eventCount > 0 { parts.append("\(eventCount) events") }
            if errorCount > 0 { parts.append("\(errorCount) errors") }
            let stats = parts.joined(separator: ", ")
            out += formatLandmark("# Session ends after \(elapsedPhrase) (\(stats))")
            if let resources = ctx.resources.summaryLine() {
                out += formatLandmark("# resources: \(resources)")
            }
        }

        return out
    }
}

/// Render an elapsed-ms value as a human-friendly phrase. Sub-second
/// captures show ms; longer captures show seconds with two decimals;
/// over a minute uses MM:SS. Keeps the session-end landmark readable
/// across the full range of capture durations.
private func formatElapsed(ms: Double) -> String {
    if ms < 1000 {
        return String(format: "%.0fms", ms)
    }
    let seconds = ms / 1000.0
    if seconds < 60 {
        return String(format: "%.2fs", seconds)
    }
    let minutes = Int(seconds) / 60
    let remainingSeconds = seconds - Double(minutes * 60)
    return String(format: "%d:%05.2f", minutes, remainingSeconds)
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
    /// In-flight GetKeyboardMapping requests: seq → (firstKeycode, count). The
    /// reply only carries the keysym list and the per-keycode group width,
    /// so we have to remember the request's `firstKeycode` to know where the
    /// list lands in the keymap.
    var seqToGetKeyboardMapping: [UInt16: (firstKeycode: UInt8, count: UInt8)] = [:]
    /// In-flight GetProperty requests: seq → property atom. Reply path uses
    /// this to dispatch type-aware decoders on the returned value.
    var seqToGetPropertyAtom: [UInt16: UInt32] = [:]
    /// In-flight GetAtomName requests: seq → atom id being looked up. Reply
    /// path uses this to populate ctx.atomToName in reverse (clients query
    /// the server for an existing atom's name rather than always interning).
    var seqToGetAtomName: [UInt16: UInt32] = [:]
    var atomToName: [UInt32: String] = [:]
    var extensionMajorToName: [UInt8: String] = [:]
    /// Extension event-base assignments from QueryExtension replies. Lets
    /// the dumper figure out which extension owns a given event code.
    var extensionFirstEventToName: [UInt8: String] = [:]
    /// Root window ids (one per screen) harvested from the accepted-setup
    /// reply. The landmark detector uses this to recognize a CreateWindow
    /// whose parent is a screen root, i.e. a top-level window.
    var screenRoots: Set<UInt32> = []
    /// Visual catalog harvested from the SetupAccepted reply. Indexed by
    /// visualId; each entry remembers the depth the visual was advertised
    /// at, its class, and which screen it belongs to. Used to render
    /// visualIds symbolically in CreateWindow / CreateColormap dumper
    /// output: `visual=0x21(PseudoColor d8 screen0)` instead of `0x21`.
    var visualCatalog: [UInt32: VisualCatalogEntry] = [:]
    /// Session-wide registry of every Create* / Free* request the dumper
    /// has seen. Powers the session-end resource summary landmark and the
    /// "freed at seq=N" annotation on resource-bearing XError landmarks.
    var resources = ResourceRegistry()
    /// Session keymap, populated from GetKeyboardMapping replies and
    /// ChangeKeyboardMapping requests. Indexed by keycode; each entry is the
    /// `keysymsPerKeycode`-wide row from the spec. Empty until the first
    /// keymap message lands. Used to translate KeyPress/KeyRelease keycodes
    /// into keysym names in the dumper.
    var keymap: [UInt8: [UInt32]] = [:]

    /// Best-effort keycode → keysym name. Picks the first (group-0,
    /// unshifted) keysym from the keymap row; that's the symbol you see
    /// reported for a bare KeyPress without modifiers. Returns nil if the
    /// session keymap hasn't been populated yet, or this keycode isn't in
    /// it, or its row is all-NoSymbol. Falls back to the raw keycode in the
    /// caller.
    func keysymName(forKeycode keycode: UInt8) -> String? {
        guard let row = keymap[keycode], !row.isEmpty else { return nil }
        let primary = row.first(where: { $0 != 0 }) ?? 0
        guard primary != 0 else { return nil }
        return xKeysymNames[primary]
    }

    /// Install a row of keysyms for `firstKeycode .. firstKeycode + count - 1`.
    /// Called from both the GetKeyboardMapping reply harvester and the
    /// ChangeKeyboardMapping request handler. Trailing NoSymbol entries in
    /// each row are preserved so `keysymsPerKeycode` stays consistent.
    mutating func installKeysyms(firstKeycode: UInt8, keysymsPerKeycode: UInt8, flat: [UInt32]) {
        let kpk = Int(keysymsPerKeycode)
        guard kpk > 0 else { return }
        let count = flat.count / kpk
        for i in 0..<count {
            let kc = Int(firstKeycode) + i
            guard kc <= 0xFF else { break }
            let lo = i * kpk
            keymap[UInt8(kc)] = Array(flat[lo..<lo+kpk])
        }
    }

    /// For an event code ≥ 64 (i.e., outside the core 2-34 range), find
    /// the registered extension whose `[firstEvent, firstEvent+eventCount)`
    /// range contains `code`. Returns (name, firstEvent) or nil.
    func extensionForEvent(code: UInt8) -> (name: String, firstEvent: UInt8)? {
        for (firstEvent, name) in extensionFirstEventToName {
            let count = ExtensionDumperRegistry.eventCount(forName: name)
            // Unknown extensions (no registered dumper) have count=0; still
            // useful to label by name, so we also accept code == firstEvent
            // as "first event of this extension."
            let span = max(count, 1)
            if code >= firstEvent && code < firstEvent + UInt8(span) {
                return (name, firstEvent)
            }
        }
        return nil
    }
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

/// Synthetic line for a LandmarkDetector emission. Left-justified comment,
/// surrounded by blank lines so it visually breaks the protocol stream and
/// reads as a chapter heading rather than another protocol line. The
/// detector emits the line with a leading `# ` so the text reads as a
/// source-code-style comment.
private func formatLandmark(_ text: String) -> String {
    return "\n\(text)\n\n"
}

/// Phase 5 visual join — picks the direction glyph for a server-to-client
/// message based on whether it's responding to a prior request. Replies
/// and XErrors carry the seq number of the request that triggered them;
/// events are spontaneous.
///
/// The `↙` glyph (south-west arrow) is used for replies and XErrors: the
/// leftward component matches the `←` server→client convention, and the
/// downward component signals "this line is attached to the request
/// above." The regular `←` stays for spontaneous events.
private func directionGlyph(for msg: ServerMessage) -> String {
    switch msg {
    case .reply, .xError: return "↙"
    case .event:          return "←"
    }
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

/// One row in the per-session visual catalog. `depth` is from the parent
/// `Depth` block in SetupAccepted (visuals are nested under their depth in
/// the wire format). `screenIndex` lets the dumper distinguish identical
/// visualIds across screens on multi-screen servers, though in practice
/// every Sun ss2 / SGI / Mac advertises a single screen.
struct VisualCatalogEntry {
    let depth: UInt8
    let visualClass: VisualClass
    let bitsPerRgbValue: UInt8
    let screenIndex: Int
}

/// Render a visualId symbolically. `0` is CopyFromParent on the CreateWindow
/// path (the spec sentinel); anywhere else, falls back to hex if the catalog
/// hasn't been populated or the id wasn't advertised.
func visualDisplay(_ id: UInt32, ctx: ChronoContext) -> String {
    if id == 0 { return "CopyFromParent" }
    let hex = String(format: "0x%X", id)
    guard let v = ctx.visualCatalog[id] else { return hex }
    return "\(hex)(\(v.visualClass.shortName) d\(v.depth))"
}

extension VisualClass {
    /// Compact label for dumper output. Matches the spec capitalization so
    /// readers used to grep'ing for "PseudoColor" still hit.
    var shortName: String {
        switch self {
        case .staticGray:   return "StaticGray"
        case .grayScale:    return "GrayScale"
        case .staticColor:  return "StaticColor"
        case .pseudoColor:  return "PseudoColor"
        case .trueColor:    return "TrueColor"
        case .directColor:  return "DirectColor"
        }
    }
}

func windowDisplay(_ w: UInt32) -> String {
    return hx(w)
}

// MARK: - Chrono dump field vocabulary
//
// One consistent set of formatters so opcode lines don't drift: a fixed
// name column, uppercase `0x` for every resource id and mask/flag value,
// `(x,y)` for points, `WxH` for sizes, and `WxH at (x,y)` for placed
// geometry. Change a convention here and every opcode follows.

/// Width the message name is padded to before its fields. The longest core
/// name is "ChangeActivePointerGrab" (23), so 24 leaves at least one space.
private let dumpNameColumn = 24

/// `name` padded to the field column, then its fields. Empty fields → just
/// the name (e.g. NoOperation, GrabServer).
private func row(_ name: String, _ fields: String = "") -> String {
    guard !fields.isEmpty else { return name }
    let pad = name.count < dumpNameColumn
        ? String(repeating: " ", count: dumpNameColumn - name.count)
        : " "
    return name + pad + fields
}

/// Resource id or mask/flag value in uppercase `0x` form. Generic so it
/// takes any width (CARD8/16/32) without per-call casts.
func hx<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16, uppercase: true) }

/// A point `(x,y)`. Coordinates are INT16 in some requests, CARD16 in
/// others (Expose etc.), so accept any integer type.
private func pt<T: BinaryInteger>(_ x: T, _ y: T) -> String { "(\(x),\(y))" }
/// A size `WxH`.
private func sz<T: BinaryInteger>(_ w: T, _ h: T) -> String { "\(w)x\(h)" }
/// Placed geometry `WxH at (x,y)`.
private func geom<S: BinaryInteger, P: BinaryInteger>(_ w: S, _ h: S, _ x: P, _ y: P) -> String {
    "\(sz(w, h)) at \(pt(x, y))"
}

/// Drop leading spaces; detail strings are built as " field=..." but `row`
/// adds the column gap itself, so the leading space would double up.
private func stripLead(_ s: String) -> String {
    String(s.drop(while: { $0 == " " }))
}

/// Fixed-width "[seq=N]" field so everything after it lines up vertically
/// across request / reply / error lines. The 6-digit field covers the full
/// UInt16 sequence range (max 65535 = 5 digits) with a column of headroom.
private func seqField(_ seq: UInt16) -> String {
    String(format: "[seq=%-6d]", seq)
}

/// Blank the width of `seqField(...)` + its trailing space (12 + 1), used to
/// indent event lines — which carry no request sequence number — so their
/// bodies align in the same column as the seq-bearing lines.
private let seqBlank = String(repeating: " ", count: 13)

func formatRequest(_ req: Request, seq: UInt16, ctx: ChronoContext, byteOrder: ByteOrder = .msbFirst) -> String {
    let seqStr = seqField(seq)
    let body: String
    switch req {
    case .createWindow(let r):
        // depth=0 + visual=0 = CopyFromParent for both, per spec. Render
        // each independently — clients sometimes copy depth but pin a
        // specific visual (or vice versa for InputOnly which uses
        // CopyFromParent visual).
        let depthStr = r.depth == 0 ? "CopyFromParent" : "\(r.depth)"
        body = row("CreateWindow", "wid=\(windowDisplay(r.wid)) parent=\(windowDisplay(r.parent)) \(geom(r.width, r.height, r.x, r.y)) class=\(r.windowClass) depth=\(depthStr) visual=\(visualDisplay(r.visual, ctx: ctx)) mask=\(hx(r.valueMask))\(decodeWindowAttrs(mask: r.valueMask, values: r.valueList, byteOrder: byteOrder))")
    case .changeWindowAttributes(let r):
        body = row("ChangeWindowAttributes", "window=\(windowDisplay(r.window)) mask=\(hx(r.valueMask))\(decodeWindowAttrs(mask: r.valueMask, values: r.valueList, byteOrder: byteOrder))")
    case .getWindowAttributes(let r):
        body = row("GetWindowAttributes", "window=\(windowDisplay(r.window))")
    case .destroyWindow(let r):
        body = row("DestroyWindow", "window=\(windowDisplay(r.window))")
    case .destroySubwindows(let r):
        body = row("DestroySubwindows", "window=\(windowDisplay(r.window))")
    case .reparentWindow(let r):
        body = row("ReparentWindow", "window=\(windowDisplay(r.window)) parent=\(windowDisplay(r.parent)) at \(pt(r.x, r.y))")
    case .mapWindow(let r):
        body = row("MapWindow", "window=\(windowDisplay(r.window))")
    case .mapSubwindows(let r):
        body = row("MapSubwindows", "window=\(windowDisplay(r.window))")
    case .unmapWindow(let r):
        body = row("UnmapWindow", "window=\(windowDisplay(r.window))")
    case .unmapSubwindows(let r):
        body = row("UnmapSubwindows", "window=\(windowDisplay(r.window))")
    case .configureWindow(let r):
        body = row("ConfigureWindow", "window=\(windowDisplay(r.window)) mask=\(hx(r.valueMask))\(decodeConfigureWindow(mask: r.valueMask, values: r.valueList, byteOrder: byteOrder))")
    case .getGeometry(let r):
        body = row("GetGeometry", "drawable=\(windowDisplay(r.drawable))")
    case .queryTree(let r):
        body = row("QueryTree", "window=\(windowDisplay(r.window))")
    case .internAtom(let r):
        let name = String(decoding: r.name, as: UTF8.self)
        body = row("InternAtom", "\"\(name)\"\(r.onlyIfExists ? " (only-if-exists)" : "")")
    case .getAtomName(let r):
        body = row("GetAtomName", "atom=\(atomDisplay(r.atom, ctx: ctx))")
    case .changeProperty(let r):
        let propName = atomDisplay(r.property, ctx: ctx)
        let typeName = atomDisplay(r.type, ctx: ctx)
        let dataPreview: String
        if let decoded = decodeKnownWMProperty(propertyName: propName,
                                               type: typeName,
                                               format: r.format.rawValue,
                                               data: r.data,
                                               byteOrder: byteOrder,
                                               ctx: ctx) {
            dataPreview = decoded
        } else {
            dataPreview = previewBytes(r.data, format: r.format)
        }
        body = row("ChangeProperty", "window=\(windowDisplay(r.window)) prop=\(propName) type=\(typeName) format=\(r.format.rawValue) \(dataPreview)")
    case .deleteProperty(let r):
        body = row("DeleteProperty", "window=\(windowDisplay(r.window)) prop=\(atomDisplay(r.property, ctx: ctx))")
    case .getProperty(let r):
        body = row("GetProperty", "window=\(windowDisplay(r.window)) prop=\(atomDisplay(r.property, ctx: ctx))\(r.delete ? " (delete)" : "")")
    case .setSelectionOwner(let r):
        body = row("SetSelectionOwner", "selection=\(atomDisplay(r.selection, ctx: ctx)) owner=\(windowDisplay(r.owner))")
    case .getSelectionOwner(let r):
        body = row("GetSelectionOwner", "selection=\(atomDisplay(r.selection, ctx: ctx))")
    case .convertSelection(let r):
        body = row("ConvertSelection", "selection=\(atomDisplay(r.selection, ctx: ctx)) target=\(atomDisplay(r.target, ctx: ctx)) prop=\(atomDisplay(r.property, ctx: ctx)) requestor=\(windowDisplay(r.requestor))")
    case .sendEvent(let r):
        body = row("SendEvent", "dest=\(windowDisplay(r.destination)) propagate=\(r.propagate)")
    case .grabPointer:
        body = row("GrabPointer")
    case .ungrabPointer:
        body = row("UngrabPointer")
    case .grabButton(let r):
        body = row("GrabButton", "window=\(windowDisplay(r.grabWindow)) button=\(r.button) modifiers=\(grabModifierString(r.modifiers))")
    case .changeActivePointerGrab(let r):
        body = row("ChangeActivePointerGrab", "cursor=\(windowDisplay(r.cursor)) eventMask=\(hx(r.eventMask))")
    case .grabKeyboard(let r):
        body = row("GrabKeyboard", "window=\(windowDisplay(r.grabWindow))")
    case .ungrabKeyboard:
        body = row("UngrabKeyboard")
    case .grabKey(let r):
        body = row("GrabKey", "window=\(windowDisplay(r.grabWindow)) key=\(r.key) modifiers=\(grabModifierString(r.modifiers))")
    case .allowEvents(let r):
        body = row("AllowEvents", "mode=\(r.mode)")
    case .grabServer:    body = row("GrabServer")
    case .ungrabServer:  body = row("UngrabServer")
    case .queryPointer(let r):
        body = row("QueryPointer", "window=\(windowDisplay(r.window))")
    case .translateCoordinates(let r):
        body = row("TranslateCoordinates", "src=\(windowDisplay(r.srcWindow)) dst=\(windowDisplay(r.dstWindow)) \(pt(r.srcX, r.srcY))")
    case .warpPointer(let r):
        body = row("WarpPointer", "dst=\(windowDisplay(r.dstWindow)) \(pt(r.dstX, r.dstY))")
    case .setInputFocus(let r):
        body = row("SetInputFocus", "focus=\(windowDisplay(r.focus)) revertTo=\(r.revertTo)")
    case .getInputFocus:    body = row("GetInputFocus")
    case .queryKeymap:      body = row("QueryKeymap")
    case .openFont(let r):
        body = row("OpenFont", "fid=\(windowDisplay(r.fid)) name=\"\(String(decoding: r.name, as: UTF8.self))\"")
    case .closeFont(let r):
        body = row("CloseFont", "font=\(windowDisplay(r.font))")
    case .queryFont(let r):
        body = row("QueryFont", "font=\(windowDisplay(r.font))")
    case .listFonts(let r):
        body = row("ListFonts", "pattern=\"\(String(decoding: r.pattern, as: UTF8.self))\" max=\(r.maxNames)")
    case .listFontsWithInfo(let r):
        body = row("ListFontsWithInfo", "pattern=\"\(String(decoding: r.pattern, as: UTF8.self))\" max=\(r.maxNames)")
    case .createPixmap(let r):
        body = row("CreatePixmap", "pid=\(windowDisplay(r.pid)) drawable=\(windowDisplay(r.drawable)) \(sz(r.width, r.height)) depth=\(r.depth)")
    case .freePixmap(let r):
        body = row("FreePixmap", "pixmap=\(windowDisplay(r.pixmap))")
    case .createGC(let r):
        body = row("CreateGC", "cid=\(windowDisplay(r.cid)) drawable=\(windowDisplay(r.drawable)) mask=\(hx(r.valueMask))\(decodeGCFgBg(mask: r.valueMask, values: r.valueList, byteOrder: byteOrder))")
    case .changeGC(let r):
        body = row("ChangeGC", "gc=\(windowDisplay(r.gc)) mask=\(hx(r.valueMask))\(decodeGCFgBg(mask: r.valueMask, values: r.valueList, byteOrder: byteOrder))")
    // The fg/bg annotation above is intentional and load-bearing: it's how
    // we tell whether a Motif client wrote whitePixel vs blackPixel into
    // its drawing GC. Useful for the dtcalc-LCD class of bugs where the
    // wire pattern is identical to gold but the rendered output diverges;
    // diff'ing fg/bg on each ChangeGC narrows the bug to either the
    // server's GC update path or its rendering path.
    case .freeGC(let r):
        body = row("FreeGC", "gc=\(windowDisplay(r.gc))")
    case .setDashes(let r):
        body = row("SetDashes", "gc=\(windowDisplay(r.gc)) offset=\(r.dashOffset) dashes=\(r.dashes.count)")
    case .setClipRectangles(let r):
        body = row("SetClipRectangles", "gc=\(windowDisplay(r.gc)) origin=\(pt(r.clipXOrigin, r.clipYOrigin)) rects=\(r.rectangles.count)")
    case .clearArea(let r):
        body = row("ClearArea", "window=\(windowDisplay(r.window)) \(geom(r.width, r.height, r.x, r.y)) exposures=\(r.exposures)")
    case .copyArea(let r):
        body = row("CopyArea", "src=\(windowDisplay(r.srcDrawable)) dst=\(windowDisplay(r.dstDrawable)) gc=\(windowDisplay(r.gc)) \(pt(r.srcX, r.srcY))→\(pt(r.dstX, r.dstY)) \(sz(r.width, r.height))")
    case .polyLine(let r):
        body = row("PolyLine", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) points=\(r.points.count)")
    case .polySegment(let r):
        body = row("PolySegment", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) segments=\(r.segments.count)")
    case .polyArc(let r):
        body = row("PolyArc", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) arcs=\(r.arcs.count)")
    case .fillPoly(let r):
        body = row("FillPoly", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) points=\(r.points.count) shape=\(r.shape)")
    case .polyRectangle(let r):
        body = row("PolyRectangle", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) rects=\(r.rectangles.count)")
    case .polyFillRectangle(let r):
        body = row("PolyFillRectangle", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) rects=\(r.rectangles.count)")
    case .polyFillArc(let r):
        body = row("PolyFillArc", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) arcs=\(r.arcs.count)")
    case .putImage(let r):
        body = row("PutImage", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) \(geom(r.width, r.height, r.dstX, r.dstY)) format=\(r.format) depth=\(r.depth) data=\(r.data.count)b")
    case .polyText8(let r):
        body = row("PolyText8", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at \(pt(r.x, r.y)) items=\(r.items.count)b")
    case .imageText8(let r):
        let s = String(decoding: r.string, as: UTF8.self)
        body = row("ImageText8", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at \(pt(r.x, r.y)) \"\(s)\"")
    case .allocColor(let r):
        body = row("AllocColor", "cmap=\(windowDisplay(r.cmap)) rgb=(\(r.red),\(r.green),\(r.blue))")
    case .allocNamedColor(let r):
        body = row("AllocNamedColor", "cmap=\(windowDisplay(r.cmap)) name=\"\(String(decoding: r.name, as: UTF8.self))\"")
    case .queryColors(let r):
        body = row("QueryColors", "cmap=\(windowDisplay(r.cmap)) pixels=\(r.pixels.count)")
    case .lookupColor(let r):
        body = row("LookupColor", "cmap=\(windowDisplay(r.cmap)) name=\"\(String(decoding: r.name, as: UTF8.self))\"")
    case .createCursor(let r):
        body = row("CreateCursor", "cid=\(windowDisplay(r.cid)) source=\(windowDisplay(r.source)) mask=\(windowDisplay(r.mask)) hotspot=\(pt(r.x, r.y))")
    case .createGlyphCursor(let r):
        body = row("CreateGlyphCursor", "cid=\(windowDisplay(r.cid)) sourceFont=\(windowDisplay(r.sourceFont)) char=\(r.sourceChar)")
    case .freeCursor(let r):
        body = row("FreeCursor", "cursor=\(windowDisplay(r.cursor))")
    case .recolorCursor(let r):
        body = row("RecolorCursor", "cursor=\(windowDisplay(r.cursor))")
    case .queryBestSize(let r):
        body = row("QueryBestSize", "class=\(r.sizeClass) drawable=\(windowDisplay(r.drawable)) \(sz(r.width, r.height))")
    case .queryExtension(let r):
        body = row("QueryExtension", "name=\"\(String(decoding: r.name, as: UTF8.self))\"")
    case .listExtensions:    body = row("ListExtensions")
    case .getKeyboardMapping(let r):
        body = row("GetKeyboardMapping", "firstKeycode=\(r.firstKeycode) count=\(r.count)")
    case .getModifierMapping: body = row("GetModifierMapping")
    case .getPointerMapping:  body = row("GetPointerMapping")
    case .ungrabButton(let r):
        body = row("UngrabButton", "button=\(r.button) grabWindow=\(windowDisplay(r.grabWindow)) modifiers=\(grabModifierString(r.modifiers))")
    case .ungrabKey(let r):
        body = row("UngrabKey", "key=\(r.key) grabWindow=\(windowDisplay(r.grabWindow)) modifiers=\(grabModifierString(r.modifiers))")
    case .getMotionEvents(let r):
        body = row("GetMotionEvents", "window=\(windowDisplay(r.window)) start=\(r.start) stop=\(r.stop)")
    case .allocColorCells(let r):
        body = row("AllocColorCells", "cmap=\(windowDisplay(r.cmap)) colors=\(r.colors) planes=\(r.planes) contiguous=\(r.contiguous)")
    case .setCloseDownMode(let r):
        body = row("SetCloseDownMode", "mode=\(r.mode)")
    case .killClient(let r):
        body = row("KillClient", "resource=\(windowDisplay(r.resource))")
    case .noOperation:
        body = row("NoOperation")
    case .createColormap(let r):
        body = row("CreateColormap", "mid=\(windowDisplay(r.mid)) window=\(windowDisplay(r.window)) visual=\(visualDisplay(r.visual, ctx: ctx)) alloc=\(r.alloc)")
    case .freeColormap(let r):
        body = row("FreeColormap", "cmap=\(windowDisplay(r.cmap))")
    case .copyColormapAndFree(let r):
        body = row("CopyColormapAndFree", "mid=\(windowDisplay(r.mid)) srcCmap=\(windowDisplay(r.srcCmap))")
    case .installColormap(let r):
        body = row("InstallColormap", "cmap=\(windowDisplay(r.cmap))")
    case .uninstallColormap(let r):
        body = row("UninstallColormap", "cmap=\(windowDisplay(r.cmap))")
    case .listInstalledColormaps(let r):
        body = row("ListInstalledColormaps", "window=\(windowDisplay(r.window))")
    case .allocColorPlanes(let r):
        body = row("AllocColorPlanes", "cmap=\(windowDisplay(r.cmap)) colors=\(r.colors) rgb=(\(r.red),\(r.green),\(r.blue)) contiguous=\(r.contiguous)")
    case .freeColors(let r):
        body = row("FreeColors", "cmap=\(windowDisplay(r.cmap)) planeMask=\(hx(r.planeMask)) pixels=\(r.pixels.count)")
    case .storeColors(let r):
        body = row("StoreColors", "cmap=\(windowDisplay(r.cmap)) items=\(r.rawItems.count / 12)")
    case .storeNamedColor(let r):
        body = row("StoreNamedColor", "cmap=\(windowDisplay(r.cmap)) pixel=\(r.pixel) name=\"\(String(decoding: r.name, as: UTF8.self))\" flags=\(hx(r.flags))")
    case .circulateWindow(let r):
        body = row("CirculateWindow", "window=\(windowDisplay(r.window)) direction=\(r.direction == 0 ? "RaiseLowest" : "LowerHighest")")
    case .queryTextExtents(let r):
        body = row("QueryTextExtents", "fid=\(windowDisplay(r.fid)) nChars=\(r.stringBytes.count / 2)")
    case .polyPoint(let r):
        body = row("PolyPoint", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) mode=\(r.coordinateMode) points=\(r.points.count)")
    case .bell(let r):
        body = row("Bell", "percent=\(r.percent)")
    case .getScreenSaver:
        body = row("GetScreenSaver")
    case .setScreenSaver(let r):
        body = row("SetScreenSaver", "timeout=\(r.timeout) interval=\(r.interval) preferBlanking=\(r.preferBlanking) allowExposures=\(r.allowExposures)")
    case .forceScreenSaver(let r):
        body = row("ForceScreenSaver", "mode=\(r.mode == 0 ? "Reset" : "Activate")")
    case .getImage(let r):
        body = row("GetImage", "drawable=\(windowDisplay(r.drawable)) \(geom(r.width, r.height, r.x, r.y)) format=\(r.format) planeMask=\(hx(r.planeMask))")
    case .polyText16(let r):
        body = row("PolyText16", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at \(pt(r.x, r.y)) items=\(r.items.count)b")
    case .imageText16(let r):
        body = row("ImageText16", "drawable=\(windowDisplay(r.drawable)) gc=\(windowDisplay(r.gc)) at \(pt(r.x, r.y)) nChars=\(r.characters.count)")
    case .copyPlane(let r):
        body = row("CopyPlane", "src=\(windowDisplay(r.srcDrawable)) dst=\(windowDisplay(r.dstDrawable)) gc=\(windowDisplay(r.gc)) \(pt(r.srcX, r.srcY))→\(pt(r.dstX, r.dstY)) \(sz(r.width, r.height)) bitPlane=\(hx(r.bitPlane))")
    case .changeSaveSet(let r):
        body = row("ChangeSaveSet", "mode=\(r.mode == .insert ? "Insert" : "Delete") window=\(windowDisplay(r.window))")
    case .listProperties(let r):
        body = row("ListProperties", "window=\(windowDisplay(r.window))")
    case .setFontPath(let r):
        body = row("SetFontPath", "paths=\(r.path.count) [\(r.path.prefix(3).joined(separator: ", "))\(r.path.count > 3 ? ", ..." : "")]")
    case .getFontPath:
        body = row("GetFontPath", "")
    case .copyGC(let r):
        body = row("CopyGC", "src=\(windowDisplay(r.srcGC)) dst=\(windowDisplay(r.dstGC)) mask=\(hx(r.valueMask))")
    case .changeKeyboardMapping(let r):
        body = row("ChangeKeyboardMapping", "firstKeyCode=\(r.firstKeyCode) perKey=\(r.keysymsPerKeycode) keycodes=\(r.keycodeCount) \(formatKeysymRows(firstKeycode: r.firstKeyCode, keysymsPerKeycode: r.keysymsPerKeycode, flat: r.keysyms))")
    case .changeKeyboardControl(let r):
        body = row("ChangeKeyboardControl", "mask=\(hx(r.valueMask)) values=\(r.valueList.count / 4)")
    case .getKeyboardControl:
        body = row("GetKeyboardControl", "")
    case .changePointerControl(let r):
        body = row("ChangePointerControl", "accel=\(r.accelerationNumerator)/\(r.accelerationDenominator) threshold=\(r.threshold) doAccel=\(r.doAcceleration) doThresh=\(r.doThreshold)")
    case .getPointerControl:
        body = row("GetPointerControl", "")
    case .changeHosts(let r):
        body = row("ChangeHosts", "mode=\(r.mode == .insert ? "Insert" : "Delete") family=\(r.family) addr=\(r.address.count)b")
    case .listHosts:
        body = row("ListHosts", "")
    case .setAccessControl(let r):
        body = row("SetAccessControl", "mode=\(r.mode == .enable ? "Enable" : "Disable")")
    case .rotateProperties(let r):
        body = row("RotateProperties", "window=\(windowDisplay(r.window)) delta=\(r.delta) properties=\(r.properties.count)")
    case .setPointerMapping(let r):
        body = row("SetPointerMapping", "map=\(r.map.count) bytes")
    case .setModifierMapping(let r):
        body = row("SetModifierMapping", "perModifier=\(r.keycodesPerModifier) keycodes=\(r.keycodes.count)")
    case .unknown(let op, let raw):
        // Extension request: route through the ExtensionDumperRegistry if
        // we've seen the QueryExtension reply that negotiated this major
        // opcode. Three-tier fallback:
        //   1. Registered decoder + recognized minor → fully decoded line.
        //   2. Named extension (any reason its decoder didn't accept the
        //      minor — unregistered, or registered but unknown minor) →
        //      labeled-undecoded "<ExtName> minor=N".
        //   3. Truly unknown extension → "Request opcode=N (untyped)".
        if let extName = ctx.extensionMajorToName[op] {
            if let decoder = ExtensionDumperRegistry.decoder(forName: extName),
               let line = decoder.formatRequest(bytes: raw, byteOrder: byteOrder) {
                body = line
            } else {
                let minor = raw.count >= 2 ? String(raw[1]) : "?"
                body = row(extName, "opcode=\(op) minor=\(minor) (undecoded)")
            }
        } else {
            body = "Request opcode=\(op) (untyped)"
        }
    }
    return "\(seqStr) \(body)"
}

// SHAPE-specific request/event formatters moved to
// Extensions/ShapeDumper.swift on 2026-05-30 as part of Phase 2's
// extension-dumper registry. Anything related to a specific extension
// belongs in its own file under Extensions/, registered via
// ExtensionDumperRegistry — not inline here.

/// Map a request's Create*/Free* shape into the resource registry. Called
/// from the request-dispatch loop in `dump()`. Treats glyph-cursor and
/// regular-cursor the same kind (both are CURSOR resources); CopyGC is
/// registered as the destination GC's creation (the source must already
/// exist for the request to be valid). FreeColors targets color cells
/// inside a colormap, not the colormap itself, so it doesn't register.
public func trackResourceLifecycle(_ req: Request, seq: UInt16, registry: inout ResourceRegistry) {
    switch req {
    case .createWindow(let r):
        registry.registerCreate(r.wid, kind: .window, atSeq: seq)
    case .destroyWindow(let r):
        registry.registerFree(r.window, atSeq: seq)
    case .createPixmap(let r):
        registry.registerCreate(r.pid, kind: .pixmap, atSeq: seq)
    case .freePixmap(let r):
        registry.registerFree(r.pixmap, atSeq: seq)
    case .createGC(let r):
        registry.registerCreate(r.cid, kind: .gc, atSeq: seq)
    case .copyGC(let r):
        // CopyGC's destination must already be a CreateGC'd id, per spec —
        // but in practice we sometimes see CopyGC against an id we missed
        // a CreateGC for (capture started mid-session). Registering here
        // makes the destination visible to lineage queries either way.
        registry.registerCreate(r.dstGC, kind: .gc, atSeq: seq)
    case .freeGC(let r):
        registry.registerFree(r.gc, atSeq: seq)
    case .openFont(let r):
        registry.registerCreate(r.fid, kind: .font, atSeq: seq)
    case .closeFont(let r):
        registry.registerFree(r.font, atSeq: seq)
    case .createCursor(let r):
        registry.registerCreate(r.cid, kind: .cursor, atSeq: seq)
    case .createGlyphCursor(let r):
        registry.registerCreate(r.cid, kind: .cursor, atSeq: seq)
    case .freeCursor(let r):
        registry.registerFree(r.cursor, atSeq: seq)
    case .createColormap(let r):
        registry.registerCreate(r.mid, kind: .colormap, atSeq: seq)
    case .freeColormap(let r):
        registry.registerFree(r.cmap, atSeq: seq)
    default:
        return
    }
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
                    if parsed.present {
                        ctx.extensionMajorToName[parsed.majorOpcode] = name
                        // Record event-base too so extension events get
                        // routed through the registry just like requests.
                        // firstEvent=0 means "no events" per the spec.
                        if parsed.firstEvent != 0 {
                            ctx.extensionFirstEventToName[parsed.firstEvent] = name
                        }
                    }
                    detail = " name=\(name) present=\(parsed.present) major=\(parsed.majorOpcode) firstEvent=\(parsed.firstEvent) firstError=\(parsed.firstError)"
                }
            }
            if op == QueryFont.opcode {
                if let parsed = try? QueryFontReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " ascent/descent=\(parsed.fontAscent)/\(parsed.fontDescent) chars=\(parsed.charInfos.count) properties=\(parsed.properties.count)"
                }
            }
            // AllocColor / AllocNamedColor reply pixel value. Without this
            // we constantly have to mentally count prior allocations to
            // figure out "what RGB is pixel 0x13?" — that question came up
            // four times in the 2026-05-20 dthelpview diagnosis.
            if op == AllocColor.opcode {
                if let parsed = try? AllocColorReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " → pixel=0x\(String(parsed.pixel, radix: 16)) rgb=(\(parsed.red),\(parsed.green),\(parsed.blue))"
                }
            }
            if op == AllocNamedColor.opcode {
                if let parsed = try? AllocNamedColorReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " → pixel=0x\(String(parsed.pixel, radix: 16)) exact=(\(parsed.exactRed),\(parsed.exactGreen),\(parsed.exactBlue))"
                }
            }
            if op == GetProperty.opcode {
                if let parsed = try? GetPropertyReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    if parsed.format == 0 || parsed.type == 0 {
                        detail = " (no value)"
                    } else {
                        let typeName = atomDisplay(parsed.type, ctx: ctx)
                        let propAtom = ctx.seqToGetPropertyAtom[seq] ?? 0
                        let propName = propAtom == 0 ? "?" : atomDisplay(propAtom, ctx: ctx)
                        let body: String
                        if let decoded = decodeKnownWMProperty(propertyName: propName,
                                                               type: typeName,
                                                               format: parsed.format,
                                                               data: parsed.value,
                                                               byteOrder: byteOrder,
                                                               ctx: ctx) {
                            body = decoded
                        } else {
                            body = previewBytesRaw(parsed.value, format: parsed.format)
                        }
                        let after = parsed.bytesAfter == 0 ? "" : " bytesAfter=\(parsed.bytesAfter)"
                        detail = " prop=\(propName) type=\(typeName) format=\(parsed.format)\(after) \(body)"
                    }
                }
                ctx.seqToGetPropertyAtom.removeValue(forKey: seq)
            }
            // GetInputFocus: most-fired reply in the corpus (1654 hits across
            // all captures). Toolkits poll for it before nearly every focus
            // operation. Two CARD32s on the wire: revert-to mode + focus
            // window. Render `revertTo` as its named enum.
            if op == GetInputFocus.opcode {
                if let parsed = try? GetInputFocusReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let focus: String
                    switch parsed.focus {
                    case 0: focus = "None"
                    case 1: focus = "PointerRoot"
                    default: focus = String(format: "0x%X", parsed.focus)
                    }
                    detail = " focus=\(focus) revertTo=\(parsed.revertTo)"
                }
            }
            // GetAtomName: the inverse of InternAtom. Server returns the
            // name string for a known atom; we propagate it into ctx.atomToName
            // so later references to that atom resolve symbolically.
            if op == GetAtomName.opcode, let atom = ctx.seqToGetAtomName[seq] {
                if let parsed = try? GetAtomNameReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let name = String(decoding: parsed.name, as: UTF8.self)
                    if !name.isEmpty {
                        ctx.atomToName[atom] = name
                    }
                    detail = " atom=\(String(format: "0x%X", atom)) → name=\"\(name)\""
                }
                ctx.seqToGetAtomName.removeValue(forKey: seq)
            }
            // GetGeometry: drawable bounds + depth + root.
            if op == GetGeometry.opcode {
                if let parsed = try? GetGeometryReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " root=\(windowDisplay(parsed.root)) at \(pt(parsed.x, parsed.y)) \(sz(parsed.width, parsed.height)) border=\(parsed.borderWidth) depth=\(parsed.depth)"
                }
            }
            // QueryTree: surfaces parent + child stacking. Truncate the
            // child list at 8 so a 60-child container doesn't blow out the line.
            if op == QueryTree.opcode {
                if let parsed = try? QueryTreeReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let parentStr = parsed.parent == 0 ? "None" : windowDisplay(parsed.parent)
                    let total = parsed.children.count
                    let shown = min(total, 8)
                    let kids = parsed.children.prefix(shown).map { String(format: "0x%X", $0) }
                    var listBody = kids.joined(separator: ",")
                    if total > shown { listBody += ",…(+\(total - shown))" }
                    detail = " root=\(windowDisplay(parsed.root)) parent=\(parentStr) children=[\(listBody)]"
                }
            }
            // GetWindowAttributes: visualId resolves through the catalog;
            // override-redirect + map-state are the workhorse fields toolkits
            // poll for. Render the windowClass enum by name.
            if op == GetWindowAttributes.opcode {
                if let parsed = try? GetWindowAttributesReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let cls: String
                    switch parsed.windowClass {
                    case 1: cls = "InputOutput"
                    case 2: cls = "InputOnly"
                    default: cls = "class=\(parsed.windowClass)"
                    }
                    let mapState: String
                    switch parsed.mapState {
                    case 0: mapState = "Unmapped"
                    case 1: mapState = "Unviewable"
                    case 2: mapState = "Viewable"
                    default: mapState = "mapState=\(parsed.mapState)"
                    }
                    detail = " \(cls) visual=\(visualDisplay(parsed.visualId, ctx: ctx)) mapState=\(mapState) override=\(parsed.overrideRedirect) eventMask=\(hx(parsed.allEventMasks))"
                }
            }
            // QueryColors: list of RGB triples for the queried pixels. Cap at
            // first 4 entries so a 256-pixel query stays readable.
            if op == QueryColors.opcode {
                if let parsed = try? QueryColorsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let total = parsed.colors.count
                    let shown = min(total, 4)
                    let rgbs = parsed.colors.prefix(shown).map {
                        "(\($0.red >> 8),\($0.green >> 8),\($0.blue >> 8))"
                    }
                    var body = rgbs.joined(separator: ",")
                    if total > shown { body += ",…(+\(total - shown))" }
                    detail = " rgb=[\(body)]"
                }
            }
            // GetModifierMapping: 8 fixed modifier slots (Shift / Lock / Ctrl
            // / Mod1..Mod5), each holding `keycodesPerModifier` keycodes.
            // Render as a compact `Shift=[50,62] Ctrl=[37]` form, skipping
            // slots whose keycodes are all zero (unmapped).
            if op == GetModifierMapping.opcode {
                if let parsed = try? GetModifierMappingReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let kpm = Int(parsed.keycodesPerModifier)
                    let modNames = ["Shift", "Lock", "Ctrl", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5"]
                    var parts: [String] = []
                    for i in 0..<min(8, parsed.keycodes.count / max(kpm, 1)) {
                        let row = parsed.keycodes[i*kpm..<(i+1)*kpm].filter { $0 != 0 }
                        guard !row.isEmpty else { continue }
                        parts.append("\(modNames[i])=[\(row.map { String($0) }.joined(separator: ","))]")
                    }
                    let body = parts.isEmpty ? "(empty)" : parts.joined(separator: " ")
                    detail = " perMod=\(kpm) \(body)"
                }
            }
            // GrabPointer / GrabKeyboard: single status byte. Same reply
            // struct + status enum; cover both with one block.
            if op == GrabPointer.opcode || op == GrabKeyboard.opcode {
                if let parsed = try? GrabReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " status=\(parsed.status)"
                }
            }
            // GetSelectionOwner: single owner window id.
            if op == GetSelectionOwner.opcode {
                if let parsed = try? GetSelectionOwnerReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let owner = parsed.owner == 0 ? "None" : windowDisplay(parsed.owner)
                    detail = " owner=\(owner)"
                }
            }
            // QueryPointer: root-relative + window-relative coords + button
            // mask + child-window-under-pointer.
            if op == QueryPointer.opcode {
                if let parsed = try? QueryPointerReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let child = parsed.child == 0 ? "None" : windowDisplay(parsed.child)
                    detail = " root=\(windowDisplay(parsed.root)) rootAt=\(pt(parsed.rootX, parsed.rootY)) winAt=\(pt(parsed.winX, parsed.winY)) child=\(child) buttons=\(modifierMaskString(parsed.mask)) sameScreen=\(parsed.sameScreen)"
                }
            }
            // TranslateCoordinates: result coords + which child window the
            // translated point landed in.
            if op == TranslateCoordinates.opcode {
                if let parsed = try? TranslateCoordinatesReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let child = parsed.child == 0 ? "None" : windowDisplay(parsed.child)
                    detail = " dst=\(pt(parsed.dstX, parsed.dstY)) child=\(child) sameScreen=\(parsed.sameScreen)"
                }
            }
            // QueryBestSize: cursor/tile/stipple closest-supported dimensions.
            if op == QueryBestSize.opcode {
                if let parsed = try? QueryBestSizeReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " best=\(sz(parsed.width, parsed.height))"
                }
            }
            // ListProperties: array of atom ids on a window. Resolve via
            // atom table when known.
            if op == ListProperties.opcode {
                if let parsed = try? ListPropertiesReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let total = parsed.atoms.count
                    let shown = min(total, 8)
                    let names = parsed.atoms.prefix(shown).map { atomDisplay($0, ctx: ctx) }
                    var body = names.joined(separator: ",")
                    if total > shown { body += ",…(+\(total - shown))" }
                    detail = " atoms=[\(body)]"
                }
            }
            // ListFonts: array of font name strings. STR8s ≤ 255 chars each;
            // truncate the list at 4 since font lists are commonly large.
            if op == ListFonts.opcode {
                if let parsed = try? ListFontsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let total = parsed.names.count
                    let shown = min(total, 4)
                    let names = parsed.names.prefix(shown).map { "\"" + String(decoding: $0, as: UTF8.self) + "\"" }
                    var body = names.joined(separator: ",")
                    if total > shown { body += ",…(+\(total - shown))" }
                    detail = " count=\(total) names=[\(body)]"
                }
            }
            // ListFontsWithInfo: returns one reply per matched font plus a
            // final empty-name terminator. Surface the name + ascent/descent.
            if op == ListFontsWithInfo.opcode {
                if let parsed = try? ListFontsWithInfoReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    if parsed.name.isEmpty {
                        detail = " (end of list)"
                    } else {
                        let name = String(decoding: parsed.name, as: UTF8.self)
                        detail = " name=\"\(name)\" ascent/descent=\(parsed.fontAscent)/\(parsed.fontDescent)"
                    }
                }
            }
            // GetFontPath: array of directory strings the server searches.
            if op == GetFontPath.opcode {
                if let parsed = try? GetFontPathReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let total = parsed.path.count
                    let shown = min(total, 4)
                    let dirs = parsed.path.prefix(shown).map { "\"\($0)\"" }
                    var body = dirs.joined(separator: ",")
                    if total > shown { body += ",…(+\(total - shown))" }
                    detail = " path=[\(body)]"
                }
            }
            // ListExtensions: array of extension name strings.
            if op == ListExtensions.opcode {
                if let parsed = try? ListExtensionsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let names = parsed.names.map { String(decoding: $0, as: UTF8.self) }
                    detail = " count=\(names.count) names=[\(names.joined(separator: ","))]"
                }
            }
            // ListInstalledColormaps: array of colormap ids in install order.
            if op == ListInstalledColormaps.opcode {
                if let parsed = try? ListInstalledColormapsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let cmaps = parsed.colormaps.map { String(format: "0x%X", $0) }
                    detail = " colormaps=[\(cmaps.joined(separator: ","))]"
                }
            }
            // ListHosts: access-control list + enabled flag.
            if op == ListHosts.opcode {
                if let parsed = try? ListHostsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " enabled=\(parsed.enabled) hosts=\(parsed.hosts.count)"
                }
            }
            // GetImage: raw pixel data. Just surface size + depth + visual;
            // the actual pixels are too big to inline.
            if op == GetImage.opcode {
                if let parsed = try? GetImageReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " depth=\(parsed.depth) visual=\(visualDisplay(parsed.visual, ctx: ctx)) bytes=\(parsed.imageData.count)"
                }
            }
            // GetKeyboardControl: per-keyboard settings. The autoRepeats
            // bitmap is 256 bits dense; report on/off only.
            if op == GetKeyboardControl.opcode {
                if let parsed = try? GetKeyboardControlReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " autoRepeat=\(parsed.globalAutoRepeat) ledMask=\(hx(parsed.ledMask)) keyClick=\(parsed.keyClickPercent)% bell=\(parsed.bellPercent)%@\(parsed.bellPitch)Hz/\(parsed.bellDuration)ms"
                }
            }
            // GetPointerControl: acceleration ratio + threshold pixels.
            if op == GetPointerControl.opcode {
                if let parsed = try? GetPointerControlReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " accel=\(parsed.accelerationNumerator)/\(parsed.accelerationDenominator) threshold=\(parsed.threshold)"
                }
            }
            // GetPointerMapping: button id → logical button mapping. Empty
            // map keeps server default (typically [1,2,3] for left/middle/right).
            if op == GetPointerMapping.opcode {
                if let parsed = try? GetPointerMappingReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let body = parsed.map.map { String($0) }.joined(separator: ",")
                    detail = " map=[\(body)]"
                }
            }
            // GetScreenSaver: blanking + auto-screensaver settings.
            if op == GetScreenSaver.opcode {
                if let parsed = try? GetScreenSaverReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " timeout=\(parsed.timeout)s interval=\(parsed.interval)s preferBlanking=\(parsed.preferBlanking) allowExposures=\(parsed.allowExposures)"
                }
            }
            // QueryKeymap: 256-bit dense bitmap of currently-down keys; count
            // the set bits so the reader sees "how many keys are pressed"
            // without us inlining a 256-bit string.
            if op == QueryKeymap.opcode {
                if let parsed = try? QueryKeymapReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let down = parsed.keys.reduce(0) { $0 + $1.nonzeroBitCount }
                    detail = " keysDown=\(down)"
                }
            }
            // QueryTextExtents: surface the overall width plus ascent/descent.
            // The font/overall extents are what callers (xlsfonts, xfontsel)
            // actually use; left/right are typically the same magnitudes.
            if op == QueryTextExtents.opcode {
                if let parsed = try? QueryTextExtentsReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let dir = parsed.drawDirection == 0 ? "LtoR" : "RtoL"
                    detail = " width=\(parsed.overallWidth) ascent/descent=\(parsed.overallAscent)/\(parsed.overallDescent) dir=\(dir)"
                }
            }
            // LookupColor: client asked for a color by name. The exact /
            // visual triples diverge when the visual class can't represent
            // the requested color precisely (8-bit PseudoColor with a full
            // colormap, say).
            if op == LookupColor.opcode {
                if let parsed = try? LookupColorReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    detail = " exact=(\(parsed.exactRed >> 8),\(parsed.exactGreen >> 8),\(parsed.exactBlue >> 8)) visual=(\(parsed.visualRed >> 8),\(parsed.visualGreen >> 8),\(parsed.visualBlue >> 8))"
                }
            }
            // SetModifierMapping / SetPointerMapping replies — both share
            // SetMappingReply, status byte only.
            if op == SetModifierMapping.opcode || op == SetPointerMapping.opcode {
                if let parsed = try? SetMappingReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    let name: String
                    switch parsed.status {
                    case 0: name = "Success"
                    case 1: name = "Busy"
                    case 2: name = "Failed"
                    default: name = "status=\(parsed.status)"
                    }
                    detail = " status=\(name)"
                }
            }
            if op == GetKeyboardMapping.opcode, let req = ctx.seqToGetKeyboardMapping[seq] {
                if let parsed = try? GetKeyboardMappingReply.decode(from: r.bytes, byteOrder: byteOrder) {
                    ctx.installKeysyms(firstKeycode: req.firstKeycode,
                                       keysymsPerKeycode: parsed.keysymsPerKeycode,
                                       flat: parsed.keysyms)
                    detail = " perKey=\(parsed.keysymsPerKeycode) keycodes=\(req.count) (keymap populated)"
                }
                ctx.seqToGetKeyboardMapping.removeValue(forKey: seq)
            }
        }
        return "\(seqField(seq)) \(row("Reply (\(opName))", stripLead(detail)))"
    case .event(let e):
        // Extension events route through the registry. Core events always
        // have a static name; extension events (code ≥ 64, codes 35-63 are
        // reserved but unused per the spec) get looked up by event-base.
        let extBinding = e.code >= 35 ? ctx.extensionForEvent(code: e.code) : nil
        var codeName = eventName(e.code) ?? "Event#\(e.code)"
        let prefix = e.sentEvent ? "[SendEvent] " : ""
        var detail = ""
        // Try the extension's typed event formatter first — if it succeeds,
        // we use its output verbatim (no codeName prefix, the extension
        // names its own event).
        if let binding = extBinding,
           let decoder = ExtensionDumperRegistry.decoder(forName: binding.name),
           let line = decoder.formatEvent(bytes: e.bytes, firstEvent: binding.firstEvent, byteOrder: byteOrder) {
            let seq = e.code == 11 ? seqBlank : seqField(e.sequenceNumber(byteOrder: byteOrder))
            return "\(seq) \(prefix)\(line)"
        }
        // Named extension but no typed decoder: label it.
        if let binding = extBinding {
            codeName = "\(binding.name)-Event#\(e.code - binding.firstEvent)"
        }
        if let decoded = try? DecodedEvent.decode(from: e, byteOrder: byteOrder) {
            switch decoded {
            case .keyPress(let i), .keyRelease(let i):
                let keyLabel: String
                if let name = ctx.keysymName(forKeycode: i.detail) {
                    keyLabel = "\(name) (keycode=\(i.detail))"
                } else {
                    keyLabel = "keycode=\(i.detail)"
                }
                detail = " window=\(windowDisplay(i.event)) at \(pt(i.eventX, i.eventY)) \(keyLabel) state=\(modifierMaskString(i.state))"
            case .buttonPress(let i), .buttonRelease(let i), .motionNotify(let i):
                detail = " window=\(windowDisplay(i.event)) at \(pt(i.eventX, i.eventY)) root=\(pt(i.rootX, i.rootY)) button=\(i.detail) state=\(modifierMaskString(i.state))"
            case .enterNotify(let c), .leaveNotify(let c):
                detail = " window=\(windowDisplay(c.event)) at \(pt(c.eventX, c.eventY)) mode=\(c.mode)"
            case .focusIn(let f), .focusOut(let f):
                detail = " window=\(windowDisplay(f.event)) detail=\(f.detail) mode=\(f.mode)"
            case .expose(let ex):
                detail = " window=\(windowDisplay(ex.window)) \(geom(ex.width, ex.height, ex.x, ex.y)) count=\(ex.count)"
            case .graphicsExposure(let ge):
                detail = " drawable=\(windowDisplay(ge.drawable)) \(geom(ge.width, ge.height, ge.x, ge.y))"
            case .noExposure(let ne):
                detail = " drawable=\(windowDisplay(ne.drawable))"
            case .createNotify(let cn):
                detail = " window=\(windowDisplay(cn.window)) parent=\(windowDisplay(cn.parent)) \(geom(cn.width, cn.height, cn.x, cn.y))"
            case .destroyNotify(let dn):
                detail = " window=\(windowDisplay(dn.window))"
            case .unmapNotify(let un):
                detail = " window=\(windowDisplay(un.window))"
            case .mapNotify(let mn):
                detail = " window=\(windowDisplay(mn.window))"
            case .mapRequest(let mr):
                detail = " window=\(windowDisplay(mr.window)) parent=\(windowDisplay(mr.parent))"
            case .reparentNotify(let rn):
                detail = " window=\(windowDisplay(rn.window)) parent=\(windowDisplay(rn.parent)) at \(pt(rn.x, rn.y))"
            case .configureNotify(let cn):
                detail = " window=\(windowDisplay(cn.window)) \(geom(cn.width, cn.height, cn.x, cn.y))"
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
                let typeName = atomDisplay(cm.type, ctx: ctx)
                let payload = decodeClientMessageData(type: typeName, format: cm.format.rawValue,
                                                      data: cm.data, byteOrder: byteOrder, ctx: ctx)
                detail = " window=\(windowDisplay(cm.window)) type=\(typeName) format=\(cm.format.rawValue) \(payload)"
            case .mappingNotify(let mn):
                detail = " request=\(mn.request)"
            case .visibilityNotify(let vn):
                detail = " window=\(windowDisplay(vn.window)) state=\(vn.state)"
            case .configureRequest(let cr):
                detail = " parent=\(windowDisplay(cr.parent)) window=\(windowDisplay(cr.window)) \(geom(cr.width, cr.height, cr.x, cr.y)) mask=\(hx(cr.valueMask))"
            case .gravityNotify(let gn):
                detail = " window=\(windowDisplay(gn.window)) at \(pt(gn.x, gn.y))"
            case .resizeRequest(let rr):
                detail = " window=\(windowDisplay(rr.window)) \(sz(rr.width, rr.height))"
            case .circulateRequest(let cr):
                detail = " parent=\(windowDisplay(cr.parent)) window=\(windowDisplay(cr.window)) place=\(cr.place == 0 ? "Top" : "Bottom")"
            case .colormapNotify(let cn):
                detail = " window=\(windowDisplay(cn.window)) colormap=\(hx(cn.colormap)) new=\(cn.isNew) state=\(cn.state == 1 ? "Installed" : "Uninstalled")"
            case .keymapNotify:
                detail = ""
            case .unknown:
                detail = ""
            }
        }
        // Events carry the last-processed request's sequence number on the
        // wire (per the spec, every core event except KeymapNotify), so show
        // it too — every server→client line then has a consistent [seq=N].
        // KeymapNotify (code 11) has no seq field (those bytes are keymap data).
        let eventBody = row("\(prefix)\(codeName)", stripLead(detail))
        if e.code == 11 {
            return "\(seqBlank)\(eventBody)"
        }
        return "\(seqField(e.sequenceNumber(byteOrder: byteOrder))) \(eventBody)"
    case .xError(let err):
        let errName = errorName(err.errorCode) ?? "Error#\(err.errorCode)"
        let majorName = opcodeName(err.majorOpcode) ?? "?"
        let seq = err.sequenceNumber(byteOrder: byteOrder)
        return "\(seqField(seq)) \(row(errName, "major=\(err.majorOpcode) (\(majorName)) bad=\(hx(err.badResourceId(byteOrder: byteOrder)))"))"
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
    case .listFontsWithInfo:         return ListFontsWithInfo.opcode
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
    case .getScreenSaver:            return GetScreenSaver.opcode
    case .setScreenSaver:            return SetScreenSaver.opcode
    case .forceScreenSaver:          return ForceScreenSaver.opcode
    case .getImage:                  return GetImage.opcode
    case .polyText16:                return PolyText16.opcode
    case .imageText16:               return ImageText16.opcode
    case .copyPlane:                 return CopyPlane.opcode
    case .changeSaveSet:             return ChangeSaveSet.opcode
    case .listProperties:            return ListProperties.opcode
    case .setFontPath:               return SetFontPath.opcode
    case .getFontPath:               return GetFontPath.opcode
    case .copyGC:                    return CopyGC.opcode
    case .changeKeyboardMapping:     return ChangeKeyboardMapping.opcode
    case .changeKeyboardControl:     return ChangeKeyboardControl.opcode
    case .getKeyboardControl:        return GetKeyboardControl.opcode
    case .changePointerControl:      return ChangePointerControl.opcode
    case .getPointerControl:         return GetPointerControl.opcode
    case .changeHosts:               return ChangeHosts.opcode
    case .listHosts:                 return ListHosts.opcode
    case .setAccessControl:          return SetAccessControl.opcode
    case .rotateProperties:          return RotateProperties.opcode
    case .setPointerMapping:         return SetPointerMapping.opcode
    case .setModifierMapping:        return SetModifierMapping.opcode
    case .unknown(let op, _):        return op
    }
}

// X11 GC value-list decoder for foreground (bit 2 = 0x4) and background
// (bit 3 = 0x8). Values are 4-byte aligned, listed in bit-order (lowest bit
// first), in connection byte order. Used by the dumper to show what pixel
// values dtcalc et al. write into their drawing GCs.
// CreateWindow / ChangeWindowAttributes value-list decoder. Surfaces the
// fields that matter for window-background and resize-paint bugs:
// bg-pixmap (so we can spot ParentRelative=1 vs solid-pixel), bg-pixel,
// border-pixel, bit-gravity, win-gravity, override-redirect, save-under.
// Event-mask and dont-propagate are intentionally elided here — they're
// noisy and rarely the answer to "why is this region the wrong color."
//
// Compact rendering of a ChangeKeyboardMapping / GetKeyboardMapping
// keysym list. Shows the first N rows in `kc<n>=[ks0,ks1,...]` form
// (NoSymbol entries omitted from each row), capped so a full 256-keycode
// dump doesn't blow up a single line.
func formatKeysymRows(firstKeycode: UInt8, keysymsPerKeycode: UInt8, flat: [UInt32]) -> String {
    let kpk = Int(keysymsPerKeycode)
    guard kpk > 0, !flat.isEmpty else { return "" }
    let rowCount = flat.count / kpk
    let shown = min(rowCount, 8)
    var rows: [String] = []
    for i in 0..<shown {
        let lo = i * kpk
        let row = flat[lo..<lo+kpk]
        let names = row.map { keysymName($0) }.filter { $0 != "NoSymbol" }
        let body = names.isEmpty ? "NoSymbol" : names.joined(separator: ",")
        rows.append("kc\(Int(firstKeycode)+i)=[\(body)]")
    }
    if rowCount > shown { rows.append("…(+\(rowCount - shown))") }
    return rows.joined(separator: " ")
}

// Spec ordering (X11 protocol §10): the value-list is emitted in
// ascending bit order, one 4-byte slot per set bit, regardless of the
// actual field width. So we walk bits 0..14 in order.
func decodeWindowAttrs(mask: UInt32, values: [UInt8], byteOrder: ByteOrder) -> String {
    func read32(at offset: Int) -> UInt32 {
        let b = values[offset..<offset+4]
        if byteOrder == .msbFirst {
            return (UInt32(b[b.startIndex]) << 24)
                 | (UInt32(b[b.startIndex+1]) << 16)
                 | (UInt32(b[b.startIndex+2]) << 8)
                 |  UInt32(b[b.startIndex+3])
        } else {
            return  UInt32(b[b.startIndex])
                 | (UInt32(b[b.startIndex+1]) << 8)
                 | (UInt32(b[b.startIndex+2]) << 16)
                 | (UInt32(b[b.startIndex+3]) << 24)
        }
    }

    func gravityName(_ v: UInt32, isWin: Bool) -> String {
        // X11 bit-gravity: 0=Forget. X11 win-gravity: 0=Unmap. Rest match.
        switch v {
        case 0:  return isWin ? "Unmap" : "Forget"
        case 1:  return "NorthWest"
        case 2:  return "North"
        case 3:  return "NorthEast"
        case 4:  return "West"
        case 5:  return "Center"
        case 6:  return "East"
        case 7:  return "SouthWest"
        case 8:  return "South"
        case 9:  return "SouthEast"
        case 10: return "Static"
        default: return "?\(v)"
        }
    }

    var pieces: [String] = []
    var offset = 0
    for bit in 0..<15 {
        let bitMask: UInt32 = 1 << bit
        guard mask & bitMask != 0 else { continue }
        if offset + 4 > values.count { break }
        let v = read32(at: offset)
        switch bitMask {
        case 0x0001: // CWBackPixmap
            let s: String
            if v == 0 { s = "None" }
            else if v == 1 { s = "ParentRelative" }
            else { s = "0x\(String(v, radix: 16))" }
            pieces.append("bg-pixmap=\(s)")
        case 0x0002: // CWBackPixel
            pieces.append("bg-px=0x\(String(v, radix: 16))")
        case 0x0004: // CWBorderPixmap
            let s = (v == 0) ? "CopyFromParent" : "0x\(String(v, radix: 16))"
            pieces.append("border-pixmap=\(s)")
        case 0x0008: // CWBorderPixel
            pieces.append("border-px=0x\(String(v, radix: 16))")
        case 0x0010: // CWBitGravity
            pieces.append("bit-grav=\(gravityName(v, isWin: false))")
        case 0x0020: // CWWinGravity
            pieces.append("win-grav=\(gravityName(v, isWin: true))")
        case 0x0200: // CWOverrideRedirect
            pieces.append("override=\(v != 0)")
        case 0x0400: // CWSaveUnder
            pieces.append("save-under=\(v != 0)")
        default:
            break
        }
        offset += 4
    }
    return pieces.isEmpty ? "" : " [\(pieces.joined(separator: " "))]"
}

// ConfigureWindow value-list decoder. Geometry/stack changes are the main
// thing we read these for; the prior dump only showed "mask=0xc" which
// required cross-referencing the resulting ConfigureNotify to know what
// actually changed. Now we get inline "x=10 y=20 w=800 h=600".
//
// Spec ordering (X11 protocol §10): value-list is in ascending bit order,
// one 4-byte slot per set bit, regardless of field width.
func decodeConfigureWindow(mask: UInt16, values: [UInt8], byteOrder: ByteOrder) -> String {
    func read32(at offset: Int) -> UInt32 {
        let b = values[offset..<offset+4]
        if byteOrder == .msbFirst {
            return (UInt32(b[b.startIndex]) << 24)
                 | (UInt32(b[b.startIndex+1]) << 16)
                 | (UInt32(b[b.startIndex+2]) << 8)
                 |  UInt32(b[b.startIndex+3])
        } else {
            return  UInt32(b[b.startIndex])
                 | (UInt32(b[b.startIndex+1]) << 8)
                 | (UInt32(b[b.startIndex+2]) << 16)
                 | (UInt32(b[b.startIndex+3]) << 24)
        }
    }
    var pieces: [String] = []
    var offset = 0
    for bit in 0..<7 {
        let bitMask: UInt16 = 1 << bit
        guard mask & bitMask != 0 else { continue }
        if offset + 4 > values.count { break }
        let v = read32(at: offset)
        switch bitMask {
        case 0x01: pieces.append("x=\(Int16(bitPattern: UInt16(v & 0xFFFF)))")
        case 0x02: pieces.append("y=\(Int16(bitPattern: UInt16(v & 0xFFFF)))")
        case 0x04: pieces.append("w=\(UInt16(v & 0xFFFF))")
        case 0x08: pieces.append("h=\(UInt16(v & 0xFFFF))")
        case 0x10: pieces.append("bw=\(UInt16(v & 0xFFFF))")
        case 0x20: pieces.append("sibling=0x\(String(v, radix: 16))")
        case 0x40:
            // Stack-mode: 0=Above 1=Below 2=TopIf 3=BottomIf 4=Opposite
            let names = ["Above", "Below", "TopIf", "BottomIf", "Opposite"]
            let n = Int(v & 0xFF)
            pieces.append("stack=\(n < names.count ? names[n] : "?\(n)")")
        default: break
        }
        offset += 4
    }
    return pieces.isEmpty ? "" : " [\(pieces.joined(separator: " "))]"
}

func decodeGCFgBg(mask: UInt32, values: [UInt8], byteOrder: ByteOrder) -> String {
    var pieces: [String] = []
    var offset = 0
    for bit in 0..<23 {
        let bitMask: UInt32 = 1 << bit
        guard mask & bitMask != 0 else { continue }
        if offset + 4 > values.count { break }
        let v: UInt32 = {
            let b = values[offset..<offset+4]
            if byteOrder == .msbFirst {
                return (UInt32(b[b.startIndex]) << 24)
                     | (UInt32(b[b.startIndex+1]) << 16)
                     | (UInt32(b[b.startIndex+2]) << 8)
                     |  UInt32(b[b.startIndex+3])
            } else {
                return  UInt32(b[b.startIndex])
                     | (UInt32(b[b.startIndex+1]) << 8)
                     | (UInt32(b[b.startIndex+2]) << 16)
                     | (UInt32(b[b.startIndex+3]) << 24)
            }
        }()
        if bitMask == 0x4 { pieces.append("fg=0x\(String(v, radix: 16))") }
        else if bitMask == 0x8 { pieces.append("bg=0x\(String(v, radix: 16))") }
        else if bitMask == 0x20000 { pieces.append("clipXOrigin=\(Int16(bitPattern: UInt16(truncatingIfNeeded: v)))") }
        else if bitMask == 0x40000 { pieces.append("clipYOrigin=\(Int16(bitPattern: UInt16(truncatingIfNeeded: v)))") }
        else if bitMask == 0x80000 { pieces.append(v == 0 ? "clipMask=None" : "clipMask=0x\(String(v, radix: 16))") }
        offset += 4
    }
    return pieces.isEmpty ? "" : " [\(pieces.joined(separator: " "))]"
}

func previewBytes(_ data: [UInt8], format: PropertyFormat) -> String {
    previewBytesRaw(data, format: format.rawValue)
}

/// `format` here is the raw wire value (8/16/32) so reply paths can call
/// it without re-deriving the enum from a request-only type.
func previewBytesRaw(_ data: [UInt8], format: UInt8) -> String {
    if format == 8 && data.count <= 64 {
        let s = String(decoding: data.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
        if !s.isEmpty {
            return "data=\"\(s)\""
        }
    }
    return "data=\(data.count)b"
}
