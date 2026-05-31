import XCTest
@testable import SwiftXCaptureCore
import Framer

// Decoder coverage for the four _MOTIF_* properties added 2026-05-31:
// _MOTIF_WM_HINTS, _MOTIF_WM_INFO, _MOTIF_DRAG_WINDOW (reuses the generic
// single-WINDOW path), and _MOTIF_DRAG_RECEIVER_INFO. Wire layouts mirror
// what reference/motif/lib/Xm/MwmUtil.h and DragICCI.h declare.

final class MotifPropertyTests: XCTestCase {

    private func u32(_ v: UInt32, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }
    private func u16(_ v: UInt16, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8(v >> 8)]
        case .msbFirst: return [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
    }
    private func dispatch(name: String, type: String = "", format: UInt8 = 32,
                          data: [UInt8], byteOrder: ByteOrder = .msbFirst,
                          ctx: ChronoContext = ChronoContext()) -> String? {
        decodeKnownWMProperty(propertyName: name, type: type, format: format,
                              data: data, byteOrder: byteOrder, ctx: ctx)
    }

    // MARK: - _MOTIF_WM_HINTS

    func testMotifWMHintsDialogDecorations() {
        // Typical Motif dialog: flags=DECORATIONS, decorations=BORDER|TITLE.
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0x2, bo)        // flags=DECORATIONS (bit 1)
        b += u32(0, bo)                      // functions (gated off)
        b += u32(0x02 | 0x08, bo)            // decorations = BORDER|TITLE
        b += u32(0, bo)                      // inputMode
        b += u32(0, bo)                      // status
        XCTAssertEqual(dispatch(name: "_MOTIF_WM_HINTS", type: "_MOTIF_WM_HINTS", data: b, byteOrder: bo),
                       "flags=DECORATIONS decorations=BORDER|TITLE")
    }

    func testMotifWMHintsFullSet() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0xF, bo)        // flags = all four bits
        b += u32(0x02 | 0x04, bo)            // functions = RESIZE|MOVE
        b += u32(0x01, bo)                   // decorations = ALL
        b += u32(1, bo)                      // inputMode = PRIMARY_APPLICATION_MODAL
        b += u32(0x1, bo)                    // status = TEAROFF_WINDOW
        XCTAssertEqual(dispatch(name: "_MOTIF_WM_HINTS", type: "_MOTIF_WM_HINTS", data: b, byteOrder: bo),
                       "flags=FUNCTIONS|DECORATIONS|INPUT_MODE|STATUS functions=RESIZE|MOVE decorations=ALL inputMode=PRIMARY_APPLICATION_MODAL status=TEAROFF_WINDOW")
    }

    func testMotifWMHintsInputModeOnly() {
        // What's actually in the dogs capture: client claims MODELESS so the
        // WM doesn't pin it as modal. Common Motif idiom.
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0x4, bo)        // flags = INPUT_MODE
        b += u32(0, bo) + u32(0, bo)         // functions, decorations (gated off)
        b += u32(0, bo)                      // inputMode = MODELESS
        b += u32(0, bo)                      // status
        XCTAssertEqual(dispatch(name: "_MOTIF_WM_HINTS", type: "_MOTIF_WM_HINTS", data: b, byteOrder: bo),
                       "flags=INPUT_MODE inputMode=MODELESS")
    }

    func testMotifWMHintsAlsoMatchesMwmAlias() {
        // Some libraries (and the source itself) use the _MWM_HINTS alias.
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0, bo) + u32(0, bo) + u32(0, bo) + u32(0, bo) + u32(0, bo)
        XCTAssertEqual(dispatch(name: "_MWM_HINTS", type: "_MWM_HINTS", data: b, byteOrder: bo),
                       "flags=0")
    }

    // MARK: - _MOTIF_WM_INFO

    func testMotifWMInfo() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0x1, bo)        // STARTUP_STANDARD
        b += u32(0x2400001, bo)              // wmWindow
        XCTAssertEqual(dispatch(name: "_MOTIF_WM_INFO", type: "_MOTIF_WM_INFO", data: b, byteOrder: bo),
                       "flags=STARTUP_STANDARD wmWindow=0x2400001")
    }

    func testMotifWMInfoNoneWMWindow() {
        let bo: ByteOrder = .msbFirst
        var b: [UInt8] = u32(0, bo) + u32(0, bo)
        XCTAssertEqual(dispatch(name: "_MOTIF_WM_INFO", type: "_MOTIF_WM_INFO", data: b, byteOrder: bo),
                       "flags=0 wmWindow=None")
    }

    // MARK: - _MOTIF_DRAG_WINDOW

    func testMotifDragWindow() {
        let bo: ByteOrder = .msbFirst
        XCTAssertEqual(dispatch(name: "_MOTIF_DRAG_WINDOW", type: "WINDOW",
                                data: u32(0x2400001, bo), byteOrder: bo),
                       "window=0x2400001")
    }

    // MARK: - _MOTIF_DRAG_RECEIVER_INFO

    func testMotifDragReceiverInfoLSB() {
        // 16-byte header: byte_order='l' protocol_version=0 style=5 (DYNAMIC)
        // pad proxyWindow=0x2400055 numDropSites=3 pad heap_offset=72.
        var b: [UInt8] = [UInt8(ascii: "l"), 0, 5, 0]   // header + style
        b += u32(0x2400055, .lsbFirst)
        b += u16(3, .lsbFirst)
        b += u16(0, .lsbFirst)
        b += u32(72, .lsbFirst)
        XCTAssertEqual(dispatch(name: "_MOTIF_DRAG_RECEIVER_INFO", type: "_MOTIF_DRAG_RECEIVER_INFO",
                                format: 8, data: b, byteOrder: .msbFirst),
                       "endian=lsb protocol=0 style=DYNAMIC proxy=0x2400055 sites=3 heap=72")
    }

    func testMotifDragReceiverInfoMSBWithNoneProxy() {
        // The fileview capture pattern: msb, style=PREFER_PREREGISTER,
        // proxy=0 (None), 2 sites, heap=72.
        var b: [UInt8] = [UInt8(ascii: "B"), 0, 2, 0]
        b += u32(0, .msbFirst)
        b += u16(2, .msbFirst)
        b += u16(0, .msbFirst)
        b += u32(72, .msbFirst)
        XCTAssertEqual(dispatch(name: "_MOTIF_DRAG_RECEIVER_INFO", type: "_MOTIF_DRAG_RECEIVER_INFO",
                                format: 8, data: b, byteOrder: .lsbFirst /* unrelated to property body */),
                       "endian=msb protocol=0 style=PREFER_PREREGISTER proxy=None sites=2 heap=72")
    }

    func testMotifDragReceiverInfoRejectsShortBody() {
        // Less than 16 bytes — header doesn't fit, decoder should bail.
        XCTAssertNil(dispatch(name: "_MOTIF_DRAG_RECEIVER_INFO", type: "_MOTIF_DRAG_RECEIVER_INFO",
                              format: 8, data: [UInt8(ascii: "l"), 0, 0]))
    }

    // MARK: - Dispatcher boundaries

    func testFormatMismatchSkipsMotifWMHints() {
        // format=8 on a 32-bit Motif property is a wire bug; refuse to
        // interpret rather than mis-render.
        XCTAssertNil(dispatch(name: "_MOTIF_WM_HINTS", type: "_MOTIF_WM_HINTS",
                              format: 8, data: [0, 1, 2, 3]))
    }
}
