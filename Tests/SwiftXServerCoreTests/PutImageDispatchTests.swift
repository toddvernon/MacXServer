import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

private final class RecPutImageBridge: WindowBridge, @unchecked Sendable {
    struct Call: Equatable {
        var width: UInt16
        var height: UInt16
        var dstX: Int16
        var dstY: Int16
        var leftPad: UInt8
        var foreground: RGB16
        var background: RGB16
        var data: [UInt8]
    }
    struct ARGBCall: Equatable {
        var width: UInt16
        var height: UInt16
        var dstX: Int16
        var dstY: Int16
        var argb: [UInt8]
    }
    var calls: [Call] = []
    var argbCalls: [ARGBCall] = []

    func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
    func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func setTopLevelTitle(id: UInt32, title: String) {}

    func drawPutImage(
        target: DrawTarget,
        sourceData: [UInt8],
        sourceWidth: UInt16, sourceHeight: UInt16,
        dstX: Int16, dstY: Int16,
        leftPad: UInt8,
        foreground: RGB16, background: RGB16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        calls.append(Call(
            width: sourceWidth, height: sourceHeight,
            dstX: dstX, dstY: dstY, leftPad: leftPad,
            foreground: foreground, background: background,
            data: sourceData
        ))
    }

    func drawPutImageARGB(
        target: DrawTarget,
        argb: [UInt8],
        width: UInt16, height: UInt16,
        dstX: Int16, dstY: Int16,
        clipRectangles: [Framer.Rectangle]?
    ) {
        argbCalls.append(ARGBCall(
            width: width, height: height,
            dstX: dstX, dstY: dstY,
            argb: argb
        ))
    }
}

final class PutImageDispatchTests: XCTestCase {

    /// The quickplot icon-button path:
    ///   CreatePixmap depth=8 → CreateGC on it → PutImage format=Bitmap depth=1
    /// PutImage was a documented silent-drop before 2026-05-21, so icon
    /// buttons rendered blank. This locks in the dispatch: a valid bitmap
    /// PutImage on a known pixmap reaches the bridge with the right fg/bg
    /// resolved from the GC.
    func testBitmapPutImageDispatchesToBridge() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let pixmapId: UInt32 = 0x4400010
        let gcId: UInt32 = 0x4400011

        // Mirror quickplot: depth-8 pixmap, then GC with fg=black bg=white,
        // then PutImage format=Bitmap depth=1.
        _ = session.feed(CreatePixmap(
            depth: 8, pid: pixmapId, drawable: 0x28,    // root drawable id
            width: 16, height: 16
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(
            cid: gcId, drawable: pixmapId,
            valueMask: 0x4 | 0x8,   // foreground + background
            valueList: [
                // CreateGC value-list: each value is a 32-bit word. fg=1
                // (blackPixel), bg=0 (whitePixel) per our ServerConfig pins.
                0x01, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ]
        ).encode(byteOrder: .lsbFirst))

        // 16x16 bitmap with scanline-pad=32: 4 bytes per scanline × 16 rows = 64 bytes.
        // Pattern: row 0 all-1s (foreground), all other rows all-0s (background).
        var data = [UInt8](repeating: 0, count: 64)
        data[0] = 0xFF; data[1] = 0xFF       // row 0: 16 bits = 1
        // bytes 2,3 are scanline-pad; rows 1..15 stay zero.

        _ = session.feed(PutImage(
            format: .bitmap, drawable: pixmapId, gc: gcId,
            width: 16, height: 16, dstX: 0, dstY: 0,
            leftPad: 0, depth: 1, data: data
        ).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.calls.count, 1, "PutImage must dispatch to bridge.drawPutImage")
        let call = bridge.calls[0]
        XCTAssertEqual(call.width, 16)
        XCTAssertEqual(call.height, 16)
        XCTAssertEqual(call.dstX, 0)
        XCTAssertEqual(call.dstY, 0)
        XCTAssertEqual(call.leftPad, 0)
        XCTAssertEqual(call.data, data)
        // fg=1 was pinned to black (0,0,0); bg=0 to white (65535,65535,65535)
        // per ColorTable initialisation.
        XCTAssertEqual(call.foreground, RGB16(red: 0, green: 0, blue: 0))
        XCTAssertEqual(call.background, RGB16(red: 65535, green: 65535, blue: 65535))
    }

    /// ZPixmap depth=8 (motifbur's menu-icon path): one byte per pixel,
    /// each byte a colormap index. Session walks the bytes through ColorTable
    /// and hands the bridge a row-major BGRA buffer. Pre-2026-06-01 this
    /// was silent-dropped.
    func testZPixmapDepth8DispatchesToBridge() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let pixmapId: UInt32 = 0x4400020
        let gcId: UInt32 = 0x4400021
        _ = session.feed(CreatePixmap(depth: 8, pid: pixmapId, drawable: 0x28,
                                       width: 4, height: 2).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: gcId, drawable: pixmapId,
                                   valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))

        // 4x2 ZPixmap depth=8: bpp=8, scanline-pad=32 → 4 bytes per row
        // (width=4 already on the 32-bit boundary). Row 0: 1,1,1,1 (black);
        // row 1: 0,0,0,0 (white). ColorTable pins pixel 0=white, pixel 1=black.
        let data: [UInt8] = [
            0x01, 0x01, 0x01, 0x01,
            0x00, 0x00, 0x00, 0x00,
        ]
        _ = session.feed(PutImage(
            format: .zPixmap, drawable: pixmapId, gc: gcId,
            width: 4, height: 2, dstX: 0, dstY: 0,
            leftPad: 0, depth: 8, data: data
        ).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.calls.count, 0, "ZPixmap must route through ARGB path, not Bitmap")
        XCTAssertEqual(bridge.argbCalls.count, 1, "ZPixmap depth=8 must dispatch to drawPutImageARGB")
        let call = bridge.argbCalls[0]
        XCTAssertEqual(call.width, 4); XCTAssertEqual(call.height, 2)
        XCTAssertEqual(call.argb.count, 4 * 2 * 4, "ARGB buffer must be width*height*4")
        // Row 0 (black=pixel 1): B,G,R,A = 0,0,0,255
        XCTAssertEqual(Array(call.argb.prefix(4)), [0, 0, 0, 255])
        // Row 1 first pixel (white=pixel 0): B,G,R,A = 255,255,255,255
        XCTAssertEqual(Array(call.argb[16...19]), [255, 255, 255, 255])
    }

    /// ZPixmap depth=1 (viewres/xgas/xgc's button-glyph path): packed 1bpp
    /// source, pixel 0→ColorTable[0]=white, pixel 1→ColorTable[1]=black.
    /// Same scanline-pad=32 packing as Bitmap, different color resolution.
    func testZPixmapDepth1DispatchesToBridge() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let pixmapId: UInt32 = 0x4400030
        let gcId: UInt32 = 0x4400031
        _ = session.feed(CreatePixmap(depth: 1, pid: pixmapId, drawable: 0x28,
                                       width: 6, height: 3).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: gcId, drawable: pixmapId,
                                   valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))

        // xgc-style 6x3 ZPixmap depth=1 = 12 bytes (4 bytes/scanline × 3 rows).
        // Row 0: all 1-bits (in the first 6 MSB positions of byte 0).
        // Row 1: all 0-bits. Row 2: alternating 101010.
        var data = [UInt8](repeating: 0, count: 12)
        data[0] = 0b11111100   // row 0 first byte: 6 of 8 high bits set
        // row 1: zero already
        data[8] = 0b10101000   // row 2: 101010 then pad
        _ = session.feed(PutImage(
            format: .zPixmap, drawable: pixmapId, gc: gcId,
            width: 6, height: 3, dstX: 0, dstY: 0,
            leftPad: 0, depth: 1, data: data
        ).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.calls.count, 0)
        XCTAssertEqual(bridge.argbCalls.count, 1, "ZPixmap depth=1 must dispatch to drawPutImageARGB")
        let call = bridge.argbCalls[0]
        XCTAssertEqual(call.width, 6); XCTAssertEqual(call.height, 3)
        XCTAssertEqual(call.argb.count, 6 * 3 * 4)
        // Row 0 pixel 0 (bit=1 → black): B,G,R,A = 0,0,0,255
        XCTAssertEqual(Array(call.argb.prefix(4)), [0, 0, 0, 255])
        // Row 1 pixel 0 (bit=0 → white): B,G,R,A = 255,255,255,255
        let row1Start = 6 * 4
        XCTAssertEqual(Array(call.argb[row1Start..<row1Start + 4]), [255, 255, 255, 255])
        // Row 2: alternating black, white, black, white, black, white
        let row2Start = 12 * 4
        XCTAssertEqual(Array(call.argb[row2Start..<row2Start + 4]), [0, 0, 0, 255])
        XCTAssertEqual(Array(call.argb[row2Start + 4..<row2Start + 8]), [255, 255, 255, 255])
    }

    /// XYPixmap and other depth combinations stay silent-dropped — see
    /// SHORTCUTS for the open ledger. This pins that behaviour so a
    /// future accidental implementation gets caught.
    func testXYPixmapPutImageStillSilentDropped() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let pixmapId: UInt32 = 0x4400040
        let gcId: UInt32 = 0x4400041
        _ = session.feed(CreatePixmap(depth: 8, pid: pixmapId, drawable: 0x28,
                                       width: 4, height: 4).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: gcId, drawable: pixmapId,
                                   valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))
        _ = session.feed(PutImage(
            format: .xyPixmap, drawable: pixmapId, gc: gcId,
            width: 4, height: 4, dstX: 0, dstY: 0,
            leftPad: 0, depth: 8, data: [UInt8](repeating: 0, count: 16)
        ).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bridge.calls.count, 0, "XYPixmap stays silent-dropped")
        XCTAssertEqual(bridge.argbCalls.count, 0, "XYPixmap stays silent-dropped")
    }

    /// Bad drawable must produce BadDrawable on the wire, not a silent drop.
    func testPutImageWithBadDrawableEmitsXError() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let beforeErr = session.outbound.drain().count
        _ = beforeErr

        // Unknown drawable id; no CreatePixmap/CreateGC.
        let bytes = session.feed(PutImage(
            format: .bitmap, drawable: 0xDEADBEEF, gc: 0x4400030,
            width: 4, height: 4, dstX: 0, dstY: 0,
            leftPad: 0, depth: 1, data: [UInt8](repeating: 0, count: 16)
        ).encode(byteOrder: .lsbFirst))
        // First byte of an X error packet is 0; second byte is the error code.
        // BadDrawable = 9.
        XCTAssertGreaterThan(bytes.count, 0, "must emit something on bad drawable")
        XCTAssertEqual(bytes[0], 0, "X error first byte is 0")
        XCTAssertEqual(bytes[1], 9, "error code 9 = BadDrawable")
        XCTAssertEqual(bridge.calls.count, 0)
    }
}
