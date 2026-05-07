import Foundation

// US-ASCII keyboard mapping: macOS NSEvent virtual keyCodes → X11 keysyms.
//
// X keycode = macOS keyCode + 8 (so X 8 = macOS 0 = 'A'). Our SetupAccepted
// reports minKeycode=8, maxKeycode=255, so the full macOS keyCode range
// (0..127) fits cleanly.
//
// Phase 1 layout: US-ASCII letters / digits / common punctuation, plus
// Enter / Tab / Escape / Backspace / arrows / modifier keys. International
// layouts, dead keys, function keys, keypad, etc. are Phase 4 polish.
//
// References:
//   - macOS virtual keycodes: HIToolbox/Events.h kVK_ANSI_*
//   - X11 keysyms: keysymdef.h XK_*

public enum USKeymap {

    /// Phase 1 reports 2 keysyms per keycode (unshifted, shifted). Phase 4
    /// extends to 4 (adds AltGr group).
    public static let keysymsPerKeycode: UInt8 = 2

    /// X keycode for a given macOS virtual keyCode. Identity + 8.
    public static func xKeycode(forMacKeyCode mac: UInt8) -> UInt8 {
        mac &+ 8
    }

    /// macOS keyCode for a given X keycode (inverse of `xKeycode(forMacKeyCode:)`).
    /// Returns nil for X keycodes outside the macOS range.
    public static func macKeyCode(forXKeycode x: UInt8) -> UInt8? {
        guard x >= 8 else { return nil }
        let mac = Int(x) - 8
        guard mac < 128 else { return nil }
        return UInt8(mac)
    }

    /// (lower, upper) X keysyms for a given macOS keyCode. NoSymbol (0) for
    /// unmapped keys.
    public static func keysyms(forMacKeyCode mac: UInt8) -> (lower: UInt32, upper: UInt32) {
        return mappings[Int(mac)] ?? (0, 0)
    }

    /// Translate macOS NSEvent.modifierFlags raw value to an X state mask.
    public static func translateModifiers(_ rawFlags: UInt) -> UInt16 {
        // NSEvent.ModifierFlags raw values:
        //   capsLock = 1 << 16
        //   shift    = 1 << 17
        //   control  = 1 << 18
        //   option   = 1 << 19
        //   command  = 1 << 20
        var state: UInt16 = 0
        if rawFlags & (1 << 17) != 0 { state |= 1 << 0 }    // Shift
        if rawFlags & (1 << 16) != 0 { state |= 1 << 1 }    // Lock (CapsLock)
        if rawFlags & (1 << 18) != 0 { state |= 1 << 2 }    // Control
        if rawFlags & (1 << 19) != 0 { state |= 1 << 3 }    // Mod1 (Option/Alt)
        if rawFlags & (1 << 20) != 0 { state |= 1 << 6 }    // Mod4 (Command)
        return state
    }

    // MARK: - Modifier mapping (for GetModifierMappingReply)

    /// X11 has 8 modifier groups in fixed order. Each group has up to N
    /// keycodes assigned to it. Phase 1: 2 keycodes per modifier (left+right
    /// where applicable, else one keycode and a 0 padding slot).
    public static let keycodesPerModifier: UInt8 = 2

    /// 8 groups × 2 slots = 16 X keycodes, in the order
    ///   Shift, Lock, Control, Mod1, Mod2, Mod3, Mod4, Mod5
    /// 0 = unassigned slot.
    public static let modifierKeycodes: [UInt8] = [
        // Shift: Shift_L (mac 0x38 → X 0x40), Shift_R (mac 0x3C → X 0x44)
        0x40, 0x44,
        // Lock: CapsLock (mac 0x39 → X 0x41), unused
        0x41, 0,
        // Control: Control_L (mac 0x3B → X 0x43), Control_R (mac 0x3E → X 0x46)
        0x43, 0x46,
        // Mod1 (Alt/Option): Option_L (mac 0x3A → X 0x42), Option_R (mac 0x3D → X 0x45)
        0x42, 0x45,
        // Mod2: unused
        0, 0,
        // Mod3: unused
        0, 0,
        // Mod4 (Command/Super): Command_L (mac 0x37 → X 0x3F), Command_R (mac 0x36 → X 0x3E)
        0x3F, 0x3E,
        // Mod5: unused
        0, 0,
    ]

    // MARK: - Keymap payload (for GetKeyboardMappingReply)

    /// Returns `count * keysymsPerKeycode` keysyms, in keycode-then-group
    /// order. firstKeycode is X-side (typically >= 8).
    public static func keymapPayload(firstKeycode: UInt8, count: UInt8) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(Int(count) * Int(keysymsPerKeycode))
        for i in 0..<Int(count) {
            let xKeycode = Int(firstKeycode) + i
            let macKeycode = xKeycode - 8
            if macKeycode < 0 || macKeycode > 127 {
                result.append(0); result.append(0)
            } else {
                let (lower, upper) = keysyms(forMacKeyCode: UInt8(macKeycode))
                result.append(lower); result.append(upper)
            }
        }
        return result
    }

    // MARK: - Mapping table

    private static let mappings: [Int: (lower: UInt32, upper: UInt32)] = {
        var m: [Int: (UInt32, UInt32)] = [:]

        // Letters (X keysyms: lowercase = ASCII, uppercase = ASCII)
        m[0x00] = (0x61, 0x41)  // A
        m[0x01] = (0x73, 0x53)  // S
        m[0x02] = (0x64, 0x44)  // D
        m[0x03] = (0x66, 0x46)  // F
        m[0x04] = (0x68, 0x48)  // H
        m[0x05] = (0x67, 0x47)  // G
        m[0x06] = (0x7A, 0x5A)  // Z
        m[0x07] = (0x78, 0x58)  // X
        m[0x08] = (0x63, 0x43)  // C
        m[0x09] = (0x76, 0x56)  // V
        m[0x0B] = (0x62, 0x42)  // B
        m[0x0C] = (0x71, 0x51)  // Q
        m[0x0D] = (0x77, 0x57)  // W
        m[0x0E] = (0x65, 0x45)  // E
        m[0x0F] = (0x72, 0x52)  // R
        m[0x10] = (0x79, 0x59)  // Y
        m[0x11] = (0x74, 0x54)  // T
        m[0x1F] = (0x6F, 0x4F)  // O
        m[0x20] = (0x75, 0x55)  // U
        m[0x22] = (0x69, 0x49)  // I
        m[0x23] = (0x70, 0x50)  // P
        m[0x25] = (0x6C, 0x4C)  // L
        m[0x26] = (0x6A, 0x4A)  // J
        m[0x28] = (0x6B, 0x4B)  // K
        m[0x2D] = (0x6E, 0x4E)  // N
        m[0x2E] = (0x6D, 0x4D)  // M

        // Number row (with US shifted symbols)
        m[0x12] = (0x31, 0x21)  // 1 / !
        m[0x13] = (0x32, 0x40)  // 2 / @
        m[0x14] = (0x33, 0x23)  // 3 / #
        m[0x15] = (0x34, 0x24)  // 4 / $
        m[0x17] = (0x35, 0x25)  // 5 / %
        m[0x16] = (0x36, 0x5E)  // 6 / ^
        m[0x1A] = (0x37, 0x26)  // 7 / &
        m[0x1C] = (0x38, 0x2A)  // 8 / *
        m[0x19] = (0x39, 0x28)  // 9 / (
        m[0x1D] = (0x30, 0x29)  // 0 / )

        // Punctuation
        m[0x18] = (0x3D, 0x2B)  // = / +
        m[0x1B] = (0x2D, 0x5F)  // - / _
        m[0x1E] = (0x5D, 0x7D)  // ] / }
        m[0x21] = (0x5B, 0x7B)  // [ / {
        m[0x27] = (0x27, 0x22)  // ' / "
        m[0x29] = (0x3B, 0x3A)  // ; / :
        m[0x2A] = (0x5C, 0x7C)  // \ / |
        m[0x2B] = (0x2C, 0x3C)  // , / <
        m[0x2C] = (0x2F, 0x3F)  // / / ?
        m[0x2F] = (0x2E, 0x3E)  // . / >
        m[0x32] = (0x60, 0x7E)  // ` / ~

        // Whitespace / control
        m[0x24] = (0xFF0D, 0xFF0D)  // Return                XK_Return
        m[0x30] = (0xFF09, 0xFF09)  // Tab                   XK_Tab
        m[0x31] = (0x0020, 0x0020)  // Space                 XK_space
        m[0x33] = (0xFF08, 0xFF08)  // Delete (backspace)    XK_BackSpace
        m[0x35] = (0xFF1B, 0xFF1B)  // Escape                XK_Escape

        // Modifiers — keycode produces the keysym for the modifier itself.
        m[0x37] = (0xFFE7, 0xFFE7)  // Command_L             XK_Meta_L
        m[0x38] = (0xFFE1, 0xFFE1)  // Shift_L               XK_Shift_L
        m[0x39] = (0xFFE5, 0xFFE5)  // CapsLock              XK_Caps_Lock
        m[0x3A] = (0xFFE9, 0xFFE9)  // Option_L              XK_Alt_L
        m[0x3B] = (0xFFE3, 0xFFE3)  // Control_L             XK_Control_L
        m[0x3C] = (0xFFE2, 0xFFE2)  // Shift_R               XK_Shift_R
        m[0x3D] = (0xFFEA, 0xFFEA)  // Option_R              XK_Alt_R
        m[0x3E] = (0xFFE4, 0xFFE4)  // Control_R             XK_Control_R
        m[0x36] = (0xFFE8, 0xFFE8)  // Command_R             XK_Meta_R

        // Arrows
        m[0x7B] = (0xFF51, 0xFF51)  // Left                  XK_Left
        m[0x7C] = (0xFF53, 0xFF53)  // Right                 XK_Right
        m[0x7D] = (0xFF54, 0xFF54)  // Down                  XK_Down
        m[0x7E] = (0xFF52, 0xFF52)  // Up                    XK_Up

        // Page navigation / home / end / delete-forward
        m[0x73] = (0xFF50, 0xFF50)  // Home                  XK_Home
        m[0x74] = (0xFF55, 0xFF55)  // PageUp                XK_Page_Up
        m[0x77] = (0xFF57, 0xFF57)  // End                   XK_End
        m[0x79] = (0xFF56, 0xFF56)  // PageDown              XK_Page_Down
        m[0x75] = (0xFFFF, 0xFFFF)  // ForwardDelete         XK_Delete

        return m
    }()
}
