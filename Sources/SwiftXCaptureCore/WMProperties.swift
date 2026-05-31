// Type-aware decoders for the ICCCM-defined WM_* properties. Decode-side
// only. Lifts the byte-array bodies of ChangeProperty / GetProperty reply
// from `data=72b` into readable structure.
//
// Layouts ported from reference/libX11/src/Xatomtype.h (xPropSizeHints,
// xPropWMHints, xPropWMState) and reference/icccm/icccm.html §4. Field
// order matches the on-wire byte order — every WM_*_HINTS property is
// `format=32`, so each "long" is one CARD32 on the wire regardless of
// host word size. xPropSizeHints's `long` comment is the historical
// vestige; the wire is always 32-bit.
//
// Five properties currently covered:
//   WM_NORMAL_HINTS  (type WM_SIZE_HINTS, format 32, 18 CARD32 elements)
//   WM_HINTS         (type WM_HINTS,      format 32,  9 CARD32 elements)
//   WM_STATE         (type WM_STATE,      format 32,  2 CARD32 elements)
//   WM_CLASS         (type STRING,        format 8,   two NUL-terminated strings)
//   WM_PROTOCOLS     (type ATOM,          format 32,  array of ATOM)

import Foundation
import Framer

// MARK: - Dispatch

/// Returns a compact, human-readable rendering of a property body when the
/// property's atom name maps to a known WM_* layout, else nil. Caller falls
/// back to `previewBytes` for the generic path.
func decodeKnownWMProperty(
    propertyName: String,
    type: String,
    format: UInt8,
    data: [UInt8],
    byteOrder: ByteOrder,
    ctx: ChronoContext
) -> String? {
    switch propertyName {
    case "WM_NORMAL_HINTS", "WM_ZOOM_HINTS":
        guard format == 32, !data.isEmpty else { return nil }
        return decodeWMSizeHints(data, byteOrder: byteOrder)
    case "WM_HINTS":
        guard format == 32, !data.isEmpty else { return nil }
        return decodeWMHints(data, byteOrder: byteOrder)
    case "WM_STATE":
        guard format == 32, !data.isEmpty else { return nil }
        return decodeWMState(data, byteOrder: byteOrder)
    case "WM_CLASS":
        guard format == 8 else { return nil }
        return decodeWMClass(data)
    case "WM_PROTOCOLS":
        guard format == 32 else { return nil }
        return decodeAtomList(data, byteOrder: byteOrder, ctx: ctx)
    case "WM_TRANSIENT_FOR":
        guard format == 32, data.count >= 4 else { return nil }
        return decodeSingleWindow(data, byteOrder: byteOrder)
    case "_MOTIF_WM_HINTS", "_MWM_HINTS":
        // Motif-specific WM hints. 5 CARD32 elements; layout from
        // reference/motif/lib/Xm/MwmUtil.h `PropMotifWmHints`. Every
        // Motif client writes this at realize time so mwm/dtwm knows
        // which decorations + functions to expose.
        guard format == 32, !data.isEmpty else { return nil }
        return decodeMotifWMHints(data, byteOrder: byteOrder)
    case "_MOTIF_WM_INFO", "_MWM_INFO":
        // Set by the running mwm on the root window. Tells clients which
        // window the WM listens on for ICCCM-style messages.
        guard format == 32, !data.isEmpty else { return nil }
        return decodeMotifWMInfo(data, byteOrder: byteOrder)
    case "_MOTIF_DRAG_WINDOW":
        // Set on the root by the first Motif client to bootstrap drag-and-drop.
        // A single CARD32 WINDOW id — the proxy window every DnD-aware client
        // reads to find each other.
        guard format == 32, data.count >= 4 else { return nil }
        return decodeSingleWindow(data, byteOrder: byteOrder)
    case "_MOTIF_DRAG_RECEIVER_INFO":
        // Drop-target advertisement, set on every widget that accepts drops.
        // Wire layout from reference/motif/lib/Xm/DragICCI.h
        // `xmDragReceiverInfoStruct`. The first byte is an embedded
        // byte_order tag ('l'/'B') — Motif's DnD properties carry their
        // own endianness independent of the X11 connection. Honor it here.
        guard format == 8, data.count >= 16 else { return nil }
        return decodeMotifDragReceiverInfo(data)
    default:
        // Fallback by type, not name. Any property typed with a well-known
        // X11 type atom decodes via its type even when the property name
        // isn't in the WM_* / _MOTIF_* set. Covers _NET_*, _XKB_RULES_NAMES,
        // RESOURCE_MANAGER, SM_CLIENT_ID, and the many vendor-specific
        // properties Motif/CDE/Athena clients use that we don't enumerate.
        return decodePropertyByType(type: type, format: format, data: data,
                                    byteOrder: byteOrder, ctx: ctx)
    }
}

// MARK: - Type-driven fallback

/// Decode a property body using its type atom alone. Used when the property
/// name doesn't match any WM_* / _MOTIF_* case. Returns nil when no
/// type-specific rendering applies, so the caller falls back to
/// `previewBytes`.
private func decodePropertyByType(type: String, format: UInt8, data: [UInt8],
                                   byteOrder: ByteOrder, ctx: ChronoContext) -> String? {
    guard !data.isEmpty else { return nil }
    switch type {
    case "ATOM":
        guard format == 32, data.count >= 4 else { return nil }
        return decodeAtomList(data, byteOrder: byteOrder, ctx: ctx)
    case "WINDOW", "PIXMAP", "COLORMAP", "CURSOR", "FONT", "DRAWABLE":
        guard format == 32, data.count >= 4 else { return nil }
        return decodeResourceIdList(data, byteOrder: byteOrder, label: type.lowercased())
    case "CARDINAL":
        return decodeIntegerList(data, format: format, byteOrder: byteOrder, signed: false)
    case "INTEGER":
        return decodeIntegerList(data, format: format, byteOrder: byteOrder, signed: true)
    case "STRING", "UTF8_STRING", "COMPOUND_TEXT":
        // Render as a quoted Latin-1 / UTF-8 string. Length cap is generous
        // for the multi-KB cases (RESOURCE_MANAGER ~30 KB is common); the
        // line gets long, but the reader sees the actual content.
        guard format == 8 else { return nil }
        return decodeStringValue(data, type: type)
    default:
        return nil
    }
}

/// CARDINAL / INTEGER list. Format declares element width (8/16/32 bits);
/// signed flag controls INT vs UINT rendering. Truncated to first 8
/// elements with a `…(+N)` tail when longer.
private func decodeIntegerList(_ data: [UInt8], format: UInt8,
                                byteOrder: ByteOrder, signed: Bool) -> String? {
    let width: Int
    switch format {
    case 8:  width = 1
    case 16: width = 2
    case 32: width = 4
    default: return nil
    }
    let total = data.count / width
    guard total > 0 else { return nil }
    let shown = min(total, 8)
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    var nums: [String] = []
    nums.reserveCapacity(shown)
    for _ in 0..<shown {
        let v: Int64
        switch width {
        case 1:
            let u = (try? r.readUInt8()) ?? 0
            v = signed ? Int64(Int8(bitPattern: u)) : Int64(u)
        case 2:
            let u = (try? r.readUInt16()) ?? 0
            v = signed ? Int64(Int16(bitPattern: u)) : Int64(u)
        default:
            let u = (try? r.readUInt32()) ?? 0
            v = signed ? Int64(Int32(bitPattern: u)) : Int64(u)
        }
        nums.append(String(v))
    }
    var body = nums.joined(separator: ",")
    if total > shown { body += ",…(+\(total - shown))" }
    let label = signed ? "ints" : "cardinals"
    return "\(label)=[\(body)]"
}

/// Resource id list (windows, pixmaps, etc.). All format=32; render as
/// hex with the type as label. Truncated identically to the integer list.
private func decodeResourceIdList(_ data: [UInt8], byteOrder: ByteOrder, label: String) -> String {
    let total = data.count / 4
    let shown = min(total, 8)
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    var ids: [String] = []
    for _ in 0..<shown {
        let id = (try? r.readUInt32()) ?? 0
        ids.append(id == 0 ? "None" : String(format: "0x%X", id))
    }
    var body = ids.joined(separator: ",")
    if total > shown { body += ",…(+\(total - shown))" }
    return "\(label)s=[\(body)]"
}

/// STRING / UTF8_STRING / COMPOUND_TEXT body. Renders quoted; up to
/// 200 characters inline, then `…(N bytes total)` if longer. Newlines
/// rendered as `\\n` so the dumper line stays single-line.
private func decodeStringValue(_ data: [UInt8], type: String) -> String {
    let limit = 200
    let truncated = data.count > limit
    let slice = truncated ? Array(data.prefix(limit)) : data
    let raw: String
    if type == "UTF8_STRING" {
        raw = String(decoding: slice, as: UTF8.self)
    } else {
        // STRING is Latin-1 per the X11 spec; COMPOUND_TEXT is a
        // multi-byte encoding but Latin-1-decode is acceptable for the
        // dumper's preview (full COMPOUND_TEXT decode is a separate gap).
        raw = String(bytes: slice, encoding: .isoLatin1) ?? ""
    }
    let escaped = raw.map { c -> String in
        switch c {
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        case "\"": return "\\\""
        case "\\": return "\\\\"
        default:
            // Control characters → `?`; otherwise keep the glyph.
            let s = c.asciiValue ?? 0
            if s != 0 && s < 0x20 { return "?" }
            return String(c)
        }
    }.joined()
    if truncated {
        return "value=\"\(escaped)…\" (\(data.count) bytes)"
    }
    return "value=\"\(escaped)\""
}

// MARK: - WM_NORMAL_HINTS

/// Spec: ICCCM §4.1.2.3. Field order from xPropSizeHints in Xatomtype.h.
/// All 18 CARD32 slots are always present on the wire; the `flags` bitfield
/// says which ones the client populated. The pre-ICCCM x/y/width/height
/// slots are obsolete and ignored even when the corresponding flag is set
/// (mwm/dtwm honor only PMinSize/PMaxSize/PResizeInc/PAspect/PBaseSize/
/// PWinGravity), but we still render them when present for completeness.
private func decodeWMSizeHints(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let flags = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }

    // Read all 17 trailing INT32s up front; later fields are missing in
    // pre-ICCCM (15-element) properties — bail gracefully if short.
    func readSigned() -> Int32? {
        guard let u = try? r.readUInt32() else { return nil }
        return Int32(bitPattern: u)
    }
    let x = readSigned() ?? 0
    let y = readSigned() ?? 0
    let w = readSigned() ?? 0
    let h = readSigned() ?? 0
    let minW = readSigned() ?? 0
    let minH = readSigned() ?? 0
    let maxW = readSigned() ?? 0
    let maxH = readSigned() ?? 0
    let widthInc = readSigned() ?? 0
    let heightInc = readSigned() ?? 0
    let minAspectX = readSigned() ?? 0
    let minAspectY = readSigned() ?? 0
    let maxAspectX = readSigned() ?? 0
    let maxAspectY = readSigned() ?? 0
    let baseW = readSigned()
    let baseH = readSigned()
    let winGravity = readSigned()

    var parts: [String] = ["flags=\(formatSizeHintsFlags(flags))"]
    if flags & 0x0001 != 0 { parts.append("USPosition=(\(x),\(y))") }
    if flags & 0x0002 != 0 { parts.append("USSize=\(w)x\(h)") }
    if flags & 0x0004 != 0, flags & 0x0001 == 0 { parts.append("PPosition=(\(x),\(y))") }
    if flags & 0x0008 != 0, flags & 0x0002 == 0 { parts.append("PSize=\(w)x\(h)") }
    if flags & 0x0010 != 0 { parts.append("min=\(minW)x\(minH)") }
    if flags & 0x0020 != 0 { parts.append("max=\(maxW)x\(maxH)") }
    if flags & 0x0040 != 0 { parts.append("inc=\(widthInc)x\(heightInc)") }
    if flags & 0x0080 != 0 {
        parts.append("aspect=\(minAspectX)/\(minAspectY)..\(maxAspectX)/\(maxAspectY)")
    }
    if flags & 0x0100 != 0, let bw = baseW, let bh = baseH {
        parts.append("base=\(bw)x\(bh)")
    }
    if flags & 0x0200 != 0, let g = winGravity {
        parts.append("gravity=\(winGravityName(g))")
    }
    return parts.joined(separator: " ")
}

private func formatSizeHintsFlags(_ flags: UInt32) -> String {
    let bits: [(UInt32, String)] = [
        (0x0001, "USPosition"),
        (0x0002, "USSize"),
        (0x0004, "PPosition"),
        (0x0008, "PSize"),
        (0x0010, "PMinSize"),
        (0x0020, "PMaxSize"),
        (0x0040, "PResizeInc"),
        (0x0080, "PAspect"),
        (0x0100, "PBaseSize"),
        (0x0200, "PWinGravity"),
    ]
    var consumed: UInt32 = 0
    var parts: [String] = []
    for (bit, name) in bits where flags & bit != 0 {
        parts.append(name)
        consumed |= bit
    }
    let leftover = flags & ~consumed
    if leftover != 0 { parts.append(String(format: "0x%X", leftover)) }
    return parts.isEmpty ? "0" : parts.joined(separator: "|")
}

private func winGravityName(_ g: Int32) -> String {
    switch g {
    case 0: return "Unmap"
    case 1: return "NorthWest"
    case 2: return "North"
    case 3: return "NorthEast"
    case 4: return "West"
    case 5: return "Center"
    case 6: return "East"
    case 7: return "SouthWest"
    case 8: return "South"
    case 9: return "SouthEast"
    case 10: return "Static"
    default: return String(format: "0x%X", g)
    }
}

// MARK: - WM_HINTS

/// Spec: ICCCM §4.1.2.4. Field order from xPropWMHints in Xatomtype.h.
/// All 9 CARD32 slots are always present on the wire; the `flags` bitfield
/// gates interpretation.
private func decodeWMHints(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let flags = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }
    let input = (try? r.readUInt32()) ?? 0
    let initialState = (try? r.readUInt32()).map { Int32(bitPattern: $0) } ?? 0
    let iconPixmap = (try? r.readUInt32()) ?? 0
    let iconWindow = (try? r.readUInt32()) ?? 0
    let iconX = (try? r.readUInt32()).map { Int32(bitPattern: $0) } ?? 0
    let iconY = (try? r.readUInt32()).map { Int32(bitPattern: $0) } ?? 0
    let iconMask = (try? r.readUInt32()) ?? 0
    let windowGroup = (try? r.readUInt32()) ?? 0

    var parts: [String] = ["flags=\(formatWMHintsFlags(flags))"]
    if flags & 0x001 != 0 { parts.append("input=\(input != 0)") }
    if flags & 0x002 != 0 { parts.append("initialState=\(wmStateName(initialState))") }
    if flags & 0x004 != 0 { parts.append("iconPixmap=\(hexId(iconPixmap))") }
    if flags & 0x008 != 0 { parts.append("iconWindow=\(hexId(iconWindow))") }
    if flags & 0x010 != 0 { parts.append("iconPos=(\(iconX),\(iconY))") }
    if flags & 0x020 != 0 { parts.append("iconMask=\(hexId(iconMask))") }
    if flags & 0x040 != 0 { parts.append("windowGroup=\(hexId(windowGroup))") }
    if flags & 0x100 != 0 { parts.append("urgent") }
    return parts.joined(separator: " ")
}

private func formatWMHintsFlags(_ flags: UInt32) -> String {
    let bits: [(UInt32, String)] = [
        (0x001, "Input"),
        (0x002, "State"),
        (0x004, "IconPixmap"),
        (0x008, "IconWindow"),
        (0x010, "IconPosition"),
        (0x020, "IconMask"),
        (0x040, "WindowGroup"),
        (0x080, "Message"),
        (0x100, "Urgency"),
    ]
    var consumed: UInt32 = 0
    var parts: [String] = []
    for (bit, name) in bits where flags & bit != 0 {
        parts.append(name)
        consumed |= bit
    }
    let leftover = flags & ~consumed
    if leftover != 0 { parts.append(String(format: "0x%X", leftover)) }
    return parts.isEmpty ? "0" : parts.joined(separator: "|")
}

// MARK: - WM_STATE

/// Spec: ICCCM §4.1.3.1. Two CARD32s: state, icon window.
private func decodeWMState(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let state = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }
    let icon = (try? r.readUInt32()) ?? 0
    let stateInt = Int32(bitPattern: state)
    return "state=\(wmStateName(stateInt)) iconWindow=\(hexId(icon))"
}

private func wmStateName(_ s: Int32) -> String {
    switch s {
    case 0: return "Withdrawn"
    case 1: return "Normal"
    case 3: return "Iconic"
    default: return String(format: "0x%X", s)
    }
}

// MARK: - WM_CLASS

/// Spec: ICCCM §4.1.2.5. Two NUL-terminated 8-bit strings: res_name (the
/// instance) followed by res_class. Common shape is `xterm\0XTerm\0`.
private func decodeWMClass(_ data: [UInt8]) -> String {
    var fields: [String] = []
    var current = ""
    for b in data {
        if b == 0 {
            fields.append(current)
            current = ""
            if fields.count == 2 { break }
        } else if b >= 32, b < 127 {
            current.append(Character(UnicodeScalar(b)))
        } else {
            current.append("?")
        }
    }
    if !current.isEmpty, fields.count < 2 { fields.append(current) }
    while fields.count < 2 { fields.append("") }
    return "instance=\"\(fields[0])\" class=\"\(fields[1])\""
}

// MARK: - ATOM list (WM_PROTOCOLS and similar)

private func decodeAtomList(_ data: [UInt8], byteOrder: ByteOrder, ctx: ChronoContext) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    var names: [String] = []
    while r.remaining >= 4 {
        guard let a = try? r.readUInt32() else { break }
        if let n = predefinedAtomName(a) {
            names.append(n)
        } else if let n = ctx.atomToName[a] {
            names.append(n)
        } else {
            names.append(String(format: "0x%X", a))
        }
    }
    return "atoms=[\(names.joined(separator: ","))]"
}

// MARK: - Single WINDOW (WM_TRANSIENT_FOR)

private func decodeSingleWindow(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let id = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }
    return "window=\(hexId(id))"
}

// MARK: - _MOTIF_WM_HINTS

/// 5 CARD32s: flags, functions, decorations, inputMode, status. Bit
/// definitions from `MwmUtil.h`. The interesting fields are gated by the
/// flags bitfield — we still render the gated value when its flag bit is
/// set, omit otherwise. Most apps only flip a subset (typical Motif
/// dialog: flags=DECORATIONS, decorations=BORDER|TITLE).
private func decodeMotifWMHints(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let flags = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }
    let functions = (try? r.readUInt32()) ?? 0
    let decorations = (try? r.readUInt32()) ?? 0
    let inputMode = (try? r.readUInt32()).map { Int32(bitPattern: $0) } ?? 0
    let status = (try? r.readUInt32()) ?? 0

    var parts: [String] = ["flags=\(formatMwmHintFlags(flags))"]
    if flags & 0x1 != 0 { parts.append("functions=\(formatMwmFunctions(functions))") }
    if flags & 0x2 != 0 { parts.append("decorations=\(formatMwmDecorations(decorations))") }
    if flags & 0x4 != 0 { parts.append("inputMode=\(mwmInputModeName(inputMode))") }
    if flags & 0x8 != 0 { parts.append("status=\(formatMwmStatus(status))") }
    return parts.joined(separator: " ")
}

private func formatMwmHintFlags(_ flags: UInt32) -> String {
    let bits: [(UInt32, String)] = [
        (0x1, "FUNCTIONS"), (0x2, "DECORATIONS"),
        (0x4, "INPUT_MODE"), (0x8, "STATUS"),
    ]
    return mwmBitString(flags, bits: bits)
}

private func formatMwmFunctions(_ v: UInt32) -> String {
    let bits: [(UInt32, String)] = [
        (0x01, "ALL"), (0x02, "RESIZE"), (0x04, "MOVE"),
        (0x08, "MINIMIZE"), (0x10, "MAXIMIZE"), (0x20, "CLOSE"),
    ]
    return mwmBitString(v, bits: bits)
}

private func formatMwmDecorations(_ v: UInt32) -> String {
    let bits: [(UInt32, String)] = [
        (0x01, "ALL"), (0x02, "BORDER"), (0x04, "RESIZEH"),
        (0x08, "TITLE"), (0x10, "MENU"), (0x20, "MINIMIZE"), (0x40, "MAXIMIZE"),
    ]
    return mwmBitString(v, bits: bits)
}

private func formatMwmStatus(_ v: UInt32) -> String {
    let bits: [(UInt32, String)] = [(0x1, "TEAROFF_WINDOW")]
    return mwmBitString(v, bits: bits)
}

private func mwmBitString(_ v: UInt32, bits: [(UInt32, String)]) -> String {
    if v == 0 { return "0" }
    var consumed: UInt32 = 0
    var parts: [String] = []
    for (bit, name) in bits where v & bit != 0 {
        parts.append(name)
        consumed |= bit
    }
    let leftover = v & ~consumed
    if leftover != 0 { parts.append(String(format: "0x%X", leftover)) }
    return parts.joined(separator: "|")
}

private func mwmInputModeName(_ v: Int32) -> String {
    switch v {
    case 0: return "MODELESS"
    case 1: return "PRIMARY_APPLICATION_MODAL"
    case 2: return "SYSTEM_MODAL"
    case 3: return "FULL_APPLICATION_MODAL"
    default: return String(format: "0x%X", v)
    }
}

// MARK: - _MOTIF_WM_INFO

/// 2 CARD32s set by the running window manager on the root window:
/// flags + wmWindow id. The flags signal whether mwm started in standard
/// or customized mode; wmWindow is the listener window for ICCCM-style
/// WM communication.
private func decodeMotifWMInfo(_ data: [UInt8], byteOrder: ByteOrder) -> String {
    var r = ByteReader(bytes: data, byteOrder: byteOrder)
    guard let flags = try? r.readUInt32() else { return "data=\(data.count)b (truncated)" }
    let wmWindow = (try? r.readUInt32()) ?? 0
    let bits: [(UInt32, String)] = [
        (0x1, "STARTUP_STANDARD"), (0x2, "STARTUP_CUSTOM"),
    ]
    return "flags=\(mwmBitString(flags, bits: bits)) wmWindow=\(hexId(wmWindow))"
}

// MARK: - _MOTIF_DRAG_RECEIVER_INFO

/// 16-byte header for a drop-receiver advertisement. The first byte
/// declares the body's endianness ('l' lsb / 'B' msb) independently of
/// the X11 connection — Motif's DnD properties are self-describing this
/// way so the receiver can post the property once and have any client
/// (regardless of its own byte order) read it back. We honor that and
/// read CARD16/CARD32 trailing fields per the embedded tag.
///
/// Layout per reference/motif/lib/Xm/DragICCI.h `xmDragReceiverInfoStruct`:
///   byte_order(1) protocol_version(1) drag_protocol_style(1) pad(1)
///   proxy_window(4) num_drop_sites(2) pad(2) heap_offset(4)
private func decodeMotifDragReceiverInfo(_ data: [UInt8]) -> String {
    let byteOrderTag = data[0]
    let bo: ByteOrder = (byteOrderTag == UInt8(ascii: "l")) ? .lsbFirst : .msbFirst
    let protocolVersion = data[1]
    let dragStyle = data[2]

    var r = ByteReader(bytes: data, byteOrder: bo, offset: 4)
    let proxyWindow = (try? r.readUInt32()) ?? 0
    let nDropSites = (try? r.readUInt16()) ?? 0
    _ = try? r.readUInt16()
    let heapOffset = (try? r.readUInt32()) ?? 0

    let tag: String
    switch byteOrderTag {
    case UInt8(ascii: "l"): tag = "lsb"
    case UInt8(ascii: "B"): tag = "msb"
    default: tag = String(format: "0x%X", byteOrderTag)
    }
    return "endian=\(tag) protocol=\(protocolVersion) style=\(motifDragStyleName(dragStyle)) proxy=\(hexId(proxyWindow)) sites=\(nDropSites) heap=\(heapOffset)"
}

/// XmDRAG_* enum from reference/motif/lib/Xm/Display.h. Values 0..6.
private func motifDragStyleName(_ v: UInt8) -> String {
    switch v {
    case 0: return "NONE"
    case 1: return "DROP_ONLY"
    case 2: return "PREFER_PREREGISTER"
    case 3: return "PREREGISTER"
    case 4: return "PREFER_DYNAMIC"
    case 5: return "DYNAMIC"
    case 6: return "PREFER_RECEIVER"
    default: return "style=\(v)"
    }
}

// MARK: - Helpers

private func hexId(_ id: UInt32) -> String {
    id == 0 ? "None" : String(format: "0x%X", id)
}
