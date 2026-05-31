import XCTest
@testable import SwiftXCaptureCore
import Framer

// Decoder coverage for the five ICCCM WM_* properties. Each test builds a
// real wire-shape property body (all CARD32s, fixed field order per
// xPropSizeHints / xPropWMHints / xPropWMState in
// reference/libX11/src/Xatomtype.h), then asserts the dumper rendering.

final class WMPropertyTests: XCTestCase {

    private func u32(_ v: UInt32, _ byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }

    private func i32(_ v: Int32, _ byteOrder: ByteOrder) -> [UInt8] {
        u32(UInt32(bitPattern: v), byteOrder)
    }

    private func dispatch(name: String, type: String = "", format: UInt8 = 32,
                          data: [UInt8], byteOrder: ByteOrder = .msbFirst,
                          ctx: ChronoContext = ChronoContext()) -> String? {
        decodeKnownWMProperty(propertyName: name, type: type, format: format,
                              data: data, byteOrder: byteOrder, ctx: ctx)
    }

    // MARK: - WM_NORMAL_HINTS

    func testWMNormalHintsModernShape() {
        // flags = PSize | PMinSize | PResizeInc | PBaseSize | PWinGravity
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = []
        b += u32(0x008 | 0x010 | 0x040 | 0x100 | 0x200, bo)  // flags
        b += i32(0, bo); b += i32(0, bo)                       // x, y (pre-ICCCM)
        b += i32(484, bo); b += i32(316, bo)                   // width, height
        b += i32(40, bo); b += i32(40, bo)                     // min
        b += i32(0, bo); b += i32(0, bo)                       // max (unused)
        b += i32(6, bo); b += i32(13, bo)                      // inc (xterm cell)
        b += i32(0, bo); b += i32(0, bo)                       // minAspect
        b += i32(0, bo); b += i32(0, bo)                       // maxAspect
        b += i32(11, bo); b += i32(17, bo)                     // base
        b += i32(1, bo)                                        // winGravity = NorthWest
        let s = dispatch(name: "WM_NORMAL_HINTS", type: "WM_SIZE_HINTS", data: b, byteOrder: bo)
        XCTAssertEqual(s, "flags=PSize|PMinSize|PResizeInc|PBaseSize|PWinGravity PSize=484x316 min=40x40 inc=6x13 base=11x17 gravity=NorthWest")
    }

    func testWMNormalHintsAspect() {
        let bo: ByteOrder = .lsbFirst
        var b: [UInt8] = []
        b += u32(0x080, bo)                                    // PAspect only
        for _ in 0..<10 { b += i32(0, bo) }                   // skip to aspects
        b += i32(4, bo); b += i32(3, bo)                       // minAspect 4/3
        b += i32(16, bo); b += i32(9, bo)                      // maxAspect 16/9
        b += i32(0, bo); b += i32(0, bo); b += i32(0, bo)     // base + winGravity unused
        let s = dispatch(name: "WM_NORMAL_HINTS", type: "WM_SIZE_HINTS", data: b, byteOrder: bo)
        XCTAssertEqual(s, "flags=PAspect aspect=4/3..16/9")
    }

    func testWMNormalHintsPrefersUSPositionOverPPosition() {
        // Spec: USPosition and PPosition both reference (x,y). When both are
        // set, USPosition is the more specific declaration; we render it once
        // rather than twice.
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = []
        b += u32(0x001 | 0x004, bo)                            // USPosition | PPosition
        b += i32(100, bo); b += i32(200, bo)                   // x, y
        for _ in 0..<15 { b += i32(0, bo) }                   // rest
        let s = dispatch(name: "WM_NORMAL_HINTS", type: "WM_SIZE_HINTS", data: b, byteOrder: bo)!
        XCTAssertTrue(s.contains("USPosition=(100,200)"))
        XCTAssertFalse(s.contains("PPosition="))
    }

    // MARK: - WM_HINTS

    func testWMHintsInputAndState() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = []
        b += u32(0x001 | 0x002, bo)         // InputHint | StateHint
        b += u32(1, bo)                      // input = true
        b += u32(1, bo)                      // initialState = Normal
        for _ in 0..<6 { b += u32(0, bo) }  // unused fields
        let s = dispatch(name: "WM_HINTS", type: "WM_HINTS", data: b, byteOrder: bo)
        XCTAssertEqual(s, "flags=Input|State input=true initialState=Normal")
    }

    func testWMHintsUrgency() {
        let bo: ByteOrder = .lsbFirst
        var b: [UInt8] = []
        b += u32(0x100, bo)                  // UrgencyHint only
        for _ in 0..<8 { b += u32(0, bo) }
        let s = dispatch(name: "WM_HINTS", type: "WM_HINTS", data: b, byteOrder: bo)
        XCTAssertEqual(s, "flags=Urgency urgent")
    }

    // MARK: - WM_STATE

    func testWMState() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(1, bo)          // Normal
        b += u32(0x123456, bo)               // icon window id
        let s = dispatch(name: "WM_STATE", type: "WM_STATE", data: b, byteOrder: bo)
        XCTAssertEqual(s, "state=Normal iconWindow=0x123456")
    }

    func testWMStateIconic() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(3, bo)          // Iconic
        b += u32(0, bo)                      // None
        let s = dispatch(name: "WM_STATE", type: "WM_STATE", data: b, byteOrder: bo)
        XCTAssertEqual(s, "state=Iconic iconWindow=None")
    }

    // MARK: - WM_CLASS

    func testWMClass() {
        let data: [UInt8] = Array("xterm\u{0}XTerm\u{0}".utf8)
        let s = dispatch(name: "WM_CLASS", type: "STRING", format: 8, data: data)
        XCTAssertEqual(s, "instance=\"xterm\" class=\"XTerm\"")
    }

    func testWMClassMissingClass() {
        // Older clients sometimes wrote a single NUL-terminated res_name and
        // omitted the class; decoder should not crash.
        let data: [UInt8] = Array("xclock\u{0}".utf8)
        let s = dispatch(name: "WM_CLASS", type: "STRING", format: 8, data: data)
        XCTAssertEqual(s, "instance=\"xclock\" class=\"\"")
    }

    // MARK: - WM_PROTOCOLS

    func testWMProtocols() {
        var ctx = ChronoContext()
        ctx.atomToName[0x123] = "WM_DELETE_WINDOW"
        ctx.atomToName[0x456] = "WM_TAKE_FOCUS"
        let bo: ByteOrder = .msbFirst
        let data = u32(0x123, bo) + u32(0x456, bo)
        let s = dispatch(name: "WM_PROTOCOLS", type: "ATOM", data: data, byteOrder: bo, ctx: ctx)
        XCTAssertEqual(s, "atoms=[WM_DELETE_WINDOW,WM_TAKE_FOCUS]")
    }

    func testWMProtocolsFallsBackToHexForUnknownAtoms() {
        let bo: ByteOrder = .lsbFirst
        let data = u32(0xABCDEF, bo)
        let s = dispatch(name: "WM_PROTOCOLS", type: "ATOM", data: data, byteOrder: bo)
        XCTAssertEqual(s, "atoms=[0xABCDEF]")
    }

    // MARK: - WM_COMMAND

    func testWMCommandSingleArg() {
        // xterm with no args: just "xterm\0".
        let data = Array("xterm\u{0}".utf8)
        XCTAssertEqual(dispatch(name: "WM_COMMAND", type: "STRING", format: 8, data: data),
                       "argv=[\"xterm\"]")
    }

    func testWMCommandMultipleArgs() {
        // xterm -bg black -fg cyan -e ls
        let data = Array("xterm\u{0}-bg\u{0}black\u{0}-fg\u{0}cyan\u{0}-e\u{0}ls\u{0}".utf8)
        XCTAssertEqual(dispatch(name: "WM_COMMAND", type: "STRING", format: 8, data: data),
                       "argv=[\"xterm\", \"-bg\", \"black\", \"-fg\", \"cyan\", \"-e\", \"ls\"]")
    }

    func testWMCommandMalformedTrailingFragment() {
        // No trailing NUL after the last arg — forgive and surface the
        // fragment rather than dropping it on the floor.
        let data = Array("xclock\u{0}-update\u{0}1".utf8)
        XCTAssertEqual(dispatch(name: "WM_COMMAND", type: "STRING", format: 8, data: data),
                       "argv=[\"xclock\", \"-update\", \"1\"]")
    }

    func testWMCommandEmpty() {
        XCTAssertEqual(dispatch(name: "WM_COMMAND", type: "STRING", format: 8, data: []),
                       "argv=[]")
    }

    func testWMCommandRejectsFormat32() {
        // WM_COMMAND is spec'd format=8. format=32 is a wire-level bug.
        XCTAssertNil(dispatch(name: "WM_COMMAND", type: "STRING", format: 32, data: [0, 0, 0, 0]))
    }

    // MARK: - WM_TRANSIENT_FOR

    func testWMTransientFor() {
        let bo: ByteOrder = .msbFirst
        let s = dispatch(name: "WM_TRANSIENT_FOR", type: "WINDOW", data: u32(0x2800042, bo), byteOrder: bo)
        XCTAssertEqual(s, "window=0x2800042")
    }

    // MARK: - Dispatch

    func testDispatcherReturnsNilForUnknownNameAndUnknownType() {
        // Name doesn't match a WM_* / _MOTIF_* case AND type isn't in the
        // type-driven fallback set → returns nil so caller uses previewBytes.
        XCTAssertNil(dispatch(name: "_NET_VENDOR_BLOB", type: "VENDOR_OPAQUE",
                              format: 32, data: [0, 0, 0, 0]))
    }

    func testDispatcherTypeFallbackHandlesUTF8String() {
        // Confirmed Yes path after the type-fallback wedge landed: unknown
        // name + recognized type renders via type alone.
        XCTAssertEqual(dispatch(name: "_NET_WM_NAME", type: "UTF8_STRING",
                                format: 8, data: [0x68, 0x69]),
                       "value=\"hi\"")
    }

    func testDispatcherFallsBackToAtomListForGenericAtomType() {
        var ctx = ChronoContext()
        ctx.atomToName[0x99] = "FOO"
        let bo: ByteOrder = .msbFirst
        let s = dispatch(name: "_NET_SUPPORTED", type: "ATOM", data: u32(0x99, bo),
                         byteOrder: bo, ctx: ctx)
        XCTAssertEqual(s, "atoms=[FOO]")
    }

    func testDispatcherSkipsWhenFormatWrong() {
        // Format=8 on a WM_NORMAL_HINTS atom is a wire-level bug; decoder
        // should refuse to interpret rather than mis-render.
        XCTAssertNil(dispatch(name: "WM_NORMAL_HINTS", type: "WM_SIZE_HINTS", format: 8,
                              data: [0, 1, 2, 3]))
    }
}
