// Symbolic decode for X11 keysyms and modifier masks. Decode-side only —
// the protocol carries integers; this file lifts them to readable names
// so the dumper output reads as `Escape state=Ctrl` instead of
// `keycode=27 state=0x4`.
//
// The keysym table itself lives in Keysyms.generated.swift, regenerated
// from reference/X11R6/xc/include/keysymdef.h via Tools/regen_keysyms.sh.

import Foundation

/// Look up a keysym's canonical name. NoSymbol (0) renders as "NoSymbol";
/// anything not in the table renders as its hex value so the reader still
/// sees the raw protocol value.
public func keysymName(_ keysym: UInt32) -> String {
    if keysym == 0 { return "NoSymbol" }
    if let name = xKeysymNames[keysym] { return name }
    return String(format: "0x%X", keysym)
}

/// X11 KEYBUTMASK bits, per X11 protocol spec section 5 (Common Types).
/// The low 8 bits are modifier keys; the high 5 bits below 0x2000 are the
/// pointer button states (Button1–Button5). Bits 0x2000+ are reserved.
private let modifierMaskBits: [(UInt16, String)] = [
    (0x0001, "Shift"),
    (0x0002, "Lock"),
    (0x0004, "Ctrl"),
    (0x0008, "Mod1"),    // typically Alt
    (0x0010, "Mod2"),    // typically NumLock
    (0x0020, "Mod3"),
    (0x0040, "Mod4"),    // typically Super
    (0x0080, "Mod5"),    // typically AltGr / ISO_Level3_Shift
    (0x0100, "Button1"),
    (0x0200, "Button2"),
    (0x0400, "Button3"),
    (0x0800, "Button4"),
    (0x1000, "Button5"),
]

/// Render a KEYBUTMASK (or its CARD16 SETofKEYBUTMASK form) symbolically.
/// `0` → `none`; a non-empty mask → bits joined with `|` in low-to-high
/// order, e.g. `Shift|Ctrl` or `Ctrl|Button1`. Unknown bits (anything
/// above the documented range) get appended as `0xNNNN` so the reader
/// can still see them.
public func modifierMaskString<T: FixedWidthInteger & UnsignedInteger>(_ mask: T) -> String {
    if mask == 0 { return "none" }
    let m = UInt16(truncatingIfNeeded: mask)
    var parts: [String] = []
    var consumed: UInt16 = 0
    for (bit, name) in modifierMaskBits where m & bit != 0 {
        parts.append(name)
        consumed |= bit
    }
    let leftover = m & ~consumed
    if leftover != 0 {
        parts.append(String(format: "0x%X", leftover))
    }
    return parts.joined(separator: "|")
}

/// Render an AnyModifier (CARD16, used by GrabButton/GrabKey where the
/// value `0x8000` means "any combination of modifiers"). Spec section 12.
public func grabModifierString<T: FixedWidthInteger & UnsignedInteger>(_ mask: T) -> String {
    if UInt16(truncatingIfNeeded: mask) == 0x8000 { return "AnyModifier" }
    return modifierMaskString(mask)
}
