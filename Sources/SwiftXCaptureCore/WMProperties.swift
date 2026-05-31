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
    default:
        // Fallback by type, not name. Any property typed ATOM with format=32
        // can be rendered as an atom list — covers WM_PROTOCOLS lookalikes
        // (CDE _MOTIF_WM_HINTS_LIST etc. are similar shapes).
        if type == "ATOM", format == 32, data.count >= 4 {
            return decodeAtomList(data, byteOrder: byteOrder, ctx: ctx)
        }
        return nil
    }
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

// MARK: - Helpers

private func hexId(_ id: UInt32) -> String {
    id == 0 ? "None" : String(format: "0x%X", id)
}
