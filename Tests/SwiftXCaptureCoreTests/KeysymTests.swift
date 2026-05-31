import XCTest
@testable import SwiftXCaptureCore

// Symbolic decode for keysyms and modifier masks. Smoke-level coverage:
// pick well-known values, assert they map. The generated table is regenerated
// from keysymdef.h so we don't need to enumerate it here.

final class KeysymTests: XCTestCase {

    // MARK: - keysym table

    func testWellKnownKeysymsResolve() {
        XCTAssertEqual(keysymName(0xFF08), "BackSpace")
        XCTAssertEqual(keysymName(0xFF09), "Tab")
        XCTAssertEqual(keysymName(0xFF0D), "Return")
        XCTAssertEqual(keysymName(0xFF1B), "Escape")
        XCTAssertEqual(keysymName(0xFF51), "Left")
        XCTAssertEqual(keysymName(0xFF54), "Down")
        XCTAssertEqual(keysymName(0xFFE1), "Shift_L")
        XCTAssertEqual(keysymName(0xFFE3), "Control_L")
        XCTAssertEqual(keysymName(0xFFE9), "Alt_L")
        XCTAssertEqual(keysymName(0x0020), "space")
        XCTAssertEqual(keysymName(0x0041), "A")
        XCTAssertEqual(keysymName(0x0061), "a")
        XCTAssertEqual(keysymName(0x0030), "0")
    }

    func testNoSymbolRendersByName() {
        XCTAssertEqual(keysymName(0), "NoSymbol")
    }

    func testUnknownKeysymRendersAsHex() {
        // Pick a value that's reserved/unallocated in the 0xFF00 plane.
        XCTAssertEqual(keysymName(0xFFFE), "0xFFFE")
    }

    // MARK: - modifier mask

    func testModifierMaskNamedBits() {
        XCTAssertEqual(modifierMaskString(UInt16(0x0001)), "Shift")
        XCTAssertEqual(modifierMaskString(UInt16(0x0004)), "Ctrl")
        XCTAssertEqual(modifierMaskString(UInt16(0x0005)), "Shift|Ctrl")
        XCTAssertEqual(modifierMaskString(UInt16(0x000D)), "Shift|Ctrl|Mod1")
        XCTAssertEqual(modifierMaskString(UInt16(0x0100)), "Button1")
        XCTAssertEqual(modifierMaskString(UInt16(0x0104)), "Ctrl|Button1")
    }

    func testModifierMaskEmpty() {
        XCTAssertEqual(modifierMaskString(UInt16(0)), "none")
    }

    func testModifierMaskUnknownBits() {
        // Bit 0x2000 isn't named — should fall through as hex.
        XCTAssertEqual(modifierMaskString(UInt16(0x2001)), "Shift|0x2000")
    }

    // MARK: - grab modifier

    func testGrabModifierAnyModifier() {
        XCTAssertEqual(grabModifierString(UInt16(0x8000)), "AnyModifier")
    }

    func testGrabModifierFallsThroughToMaskString() {
        XCTAssertEqual(grabModifierString(UInt16(0x0005)), "Shift|Ctrl")
        XCTAssertEqual(grabModifierString(UInt16(0)), "none")
    }

    // MARK: - ChronoContext keymap

    func testInstallKeysymsPopulatesKeymap() {
        var ctx = ChronoContext()
        // Two keycodes, keysymsPerKeycode = 2: kc7 → [Tab, ISO_Left_Tab],
        // kc8 → [Return, NoSymbol].
        let flat: [UInt32] = [0xFF09, 0xFE20, 0xFF0D, 0]
        ctx.installKeysyms(firstKeycode: 7, keysymsPerKeycode: 2, flat: flat)
        XCTAssertEqual(ctx.keysymName(forKeycode: 7), "Tab")
        XCTAssertEqual(ctx.keysymName(forKeycode: 8), "Return")
        XCTAssertNil(ctx.keysymName(forKeycode: 9))
    }

    func testInstallKeysymsSkipsAllNoSymbolRow() {
        var ctx = ChronoContext()
        ctx.installKeysyms(firstKeycode: 50, keysymsPerKeycode: 2, flat: [0, 0])
        // Row exists but is all NoSymbol → lookup returns nil so the caller
        // falls back to keycode=N rather than rendering "NoSymbol".
        XCTAssertNil(ctx.keysymName(forKeycode: 50))
    }

    func testKeysymRowsCompactRendering() {
        let flat: [UInt32] = [0xFF09, 0xFE20, 0xFF0D, 0]
        let s = formatKeysymRows(firstKeycode: 7, keysymsPerKeycode: 2, flat: flat)
        XCTAssertEqual(s, "kc7=[Tab,ISO_Left_Tab] kc8=[Return]")
    }

    func testKeysymRowsTruncates() {
        // 10 keycodes × 1 keysym each — only 8 should render plus an ellipsis.
        let flat: [UInt32] = (0..<10).map { _ in UInt32(0xFF09) }
        let s = formatKeysymRows(firstKeycode: 0, keysymsPerKeycode: 1, flat: flat)
        XCTAssertTrue(s.contains("kc7=[Tab]"))
        XCTAssertFalse(s.contains("kc8="))
        XCTAssertTrue(s.contains("…(+2)"))
    }
}
