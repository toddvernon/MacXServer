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
    var calls: [Call] = []

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

    /// Non-bitmap formats (XYPixmap, ZPixmap) stay silent-dropped — none
    /// of the clients we host today exercise them. This test pins that
    /// behaviour so a future format=XYPixmap accidental implementation
    /// gets caught.
    func testZPixmapPutImageStillSilentDropped() throws {
        let bridge = RecPutImageBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let pixmapId: UInt32 = 0x4400020
        let gcId: UInt32 = 0x4400021
        _ = session.feed(CreatePixmap(depth: 8, pid: pixmapId, drawable: 0x28,
                                       width: 4, height: 4).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: gcId, drawable: pixmapId,
                                   valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))
        _ = session.feed(PutImage(
            format: .zPixmap, drawable: pixmapId, gc: gcId,
            width: 4, height: 4, dstX: 0, dstY: 0,
            leftPad: 0, depth: 8, data: [UInt8](repeating: 0, count: 16)
        ).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bridge.calls.count, 0, "ZPixmap path must stay silent-dropped")
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
