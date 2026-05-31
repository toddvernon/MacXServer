import XCTest
@testable import SwiftXCaptureCore
import Framer

// ClientMessage payload decode by type atom. WM_PROTOCOLS (close-window /
// take-focus handshake) is the by-far most common shape in vintage X
// debugging; _MOTIF_WM_MESSAGES (mwm function-id dispatch) is the second.
// Generic fallback renders 5×CARD32 / 10×CARD16 / 20×byte lists.

final class ClientMessageDecodeTests: XCTestCase {

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

    /// Build a canonical 20-byte payload: protocol atom in slot 0,
    /// timestamp in slot 1, zero-padded to 20.
    private func wmProtocolsPayload(atom: UInt32, time: UInt32, _ bo: ByteOrder) -> [UInt8] {
        var b = u32(atom, bo) + u32(time, bo)
        b += Array(repeating: 0, count: 20 - b.count)
        return b
    }

    // MARK: - WM_PROTOCOLS

    func testWMDeleteWindow() {
        var ctx = ChronoContext()
        ctx.atomToName[0x123] = "WM_DELETE_WINDOW"
        let bo: ByteOrder = .msbFirst
        let payload = wmProtocolsPayload(atom: 0x123, time: 12345, bo)
        XCTAssertEqual(decodeClientMessageData(type: "WM_PROTOCOLS", format: 32,
                                                data: payload, byteOrder: bo, ctx: ctx),
                       "protocol=WM_DELETE_WINDOW time=12345")
    }

    func testWMTakeFocus() {
        var ctx = ChronoContext()
        ctx.atomToName[0x456] = "WM_TAKE_FOCUS"
        let bo: ByteOrder = .lsbFirst
        let payload = wmProtocolsPayload(atom: 0x456, time: 0, bo)
        XCTAssertEqual(decodeClientMessageData(type: "WM_PROTOCOLS", format: 32,
                                                data: payload, byteOrder: bo, ctx: ctx),
                       "protocol=WM_TAKE_FOCUS time=CurrentTime")
    }

    func testWMProtocolsWithUnresolvedAtom() {
        let bo: ByteOrder = .msbFirst
        let payload = wmProtocolsPayload(atom: 0x9E, time: 99, bo)
        XCTAssertEqual(decodeClientMessageData(type: "WM_PROTOCOLS", format: 32,
                                                data: payload, byteOrder: bo,
                                                ctx: ChronoContext()),
                       "protocol=0x9E time=99")
    }

    func testWMProtocolsWithNoneAtom() {
        let bo: ByteOrder = .msbFirst
        let payload = wmProtocolsPayload(atom: 0, time: 0, bo)
        XCTAssertEqual(decodeClientMessageData(type: "WM_PROTOCOLS", format: 32,
                                                data: payload, byteOrder: bo,
                                                ctx: ChronoContext()),
                       "protocol=None time=CurrentTime")
    }

    // MARK: - _MOTIF_WM_MESSAGES

    func testMotifWMMessageKnownCode() {
        // Code 8 = MWM_F_FUNCTION_MINIMIZE per MwmUtil.h
        let bo: ByteOrder = .msbFirst
        var payload = u32(8, bo) + u32(0, bo) + u32(0xDEAD, bo)
        payload += Array(repeating: 0, count: 20 - payload.count)
        XCTAssertEqual(decodeClientMessageData(type: "_MOTIF_WM_MESSAGES", format: 32,
                                                data: payload, byteOrder: bo,
                                                ctx: ChronoContext()),
                       "message=MWM_F_FUNCTION_MINIMIZE time=0 arg=0xDEAD")
    }

    func testMotifWMMessageUnknownCode() {
        let bo: ByteOrder = .msbFirst
        var payload = u32(99, bo)
        payload += Array(repeating: 0, count: 20 - payload.count)
        let s = decodeClientMessageData(type: "_MOTIF_WM_MESSAGES", format: 32,
                                         data: payload, byteOrder: bo,
                                         ctx: ChronoContext())
        XCTAssertTrue(s.contains("message=code=99"), s)
    }

    // MARK: - Generic fallback

    func testGenericFormat32() {
        let bo: ByteOrder = .msbFirst
        let payload = u32(0x100, bo) + u32(0x200, bo) + u32(0x300, bo) + u32(0x400, bo) + u32(0x500, bo)
        XCTAssertEqual(decodeClientMessageData(type: "_VENDOR_PRIVATE", format: 32,
                                                data: payload, byteOrder: bo,
                                                ctx: ChronoContext()),
                       "data=[0x100,0x200,0x300,0x400,0x500]")
    }

    func testGenericFormat16() {
        let bo: ByteOrder = .lsbFirst
        var payload: [UInt8] = []
        for v in UInt16(0)..<10 { payload += u16(v, bo) }
        XCTAssertEqual(decodeClientMessageData(type: "_VENDOR_PRIVATE", format: 16,
                                                data: payload, byteOrder: bo,
                                                ctx: ChronoContext()),
                       "data=[0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8,0x9]")
    }

    func testGenericFormat8() {
        let payload: [UInt8] = (0..<20).map { UInt8($0) }
        let s = decodeClientMessageData(type: "_VENDOR_PRIVATE", format: 8,
                                         data: payload, byteOrder: .msbFirst,
                                         ctx: ChronoContext())
        XCTAssertEqual(s, "data=00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13")
    }

    func testWrongDataLengthRejected() {
        let s = decodeClientMessageData(type: "WM_PROTOCOLS", format: 32,
                                         data: [0, 1, 2, 3], byteOrder: .msbFirst,
                                         ctx: ChronoContext())
        XCTAssertEqual(s, "data=4b")
    }
}
