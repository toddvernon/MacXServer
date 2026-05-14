import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Recording bridge for verifying font + text dispatch paths.
private final class RecBridge: WindowBridge, @unchecked Sendable {
    struct ImageText8Call: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var background: RGB16
        var fontName: String
        var pointSize: Double
        var cellWidth: Int
        var cellHeight: Int
        var x: Int16
        var y: Int16
        var string: [UInt8]
    }
    struct FillRectsCall: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var rectangles: [Framer.Rectangle]
    }

    var imageText8Calls: [ImageText8Call] = []
    var fillRectsCalls: [FillRectsCall] = []

    func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
    func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func setTopLevelTitle(id: UInt32, title: String) {}

    func drawImageText8(
        topLevel: UInt32, foreground: RGB16, background: RGB16,
        font: ResolvedFont, x: Int16, y: Int16, string: [UInt8],
        clipRectangles: [Framer.Rectangle]?
    ) {
        imageText8Calls.append(ImageText8Call(
            topLevel: topLevel, foreground: foreground, background: background,
            fontName: font.macFontName, pointSize: font.pointSize,
            cellWidth: font.cellWidth, cellHeight: font.cellHeight,
            x: x, y: y, string: string
        ))
    }
    func drawPolyFillRectangle(topLevel: UInt32, foreground: RGB16, function: UInt8, rectangles: [Framer.Rectangle], clipRectangles: [Framer.Rectangle]?) {
        fillRectsCalls.append(FillRectsCall(
            topLevel: topLevel, foreground: foreground, rectangles: rectangles
        ))
    }
}

final class FontDispatchTests: XCTestCase {

    func testOpenFontStoresResolvedMetadata() {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        let req = OpenFont(fid: 0x4400005, name: Array("9x15".utf8))
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        let entry = session.fonts.get(0x4400005)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.resolved.macFontName, "Monaco")
        // 9x15 alias → Monaco's natural cell at integer pointSize 11
        // (advance ratio ~0.6, lineHeight ratio ~1.34): 7×15.
        XCTAssertEqual(entry?.resolved.cellWidth, 7)
        XCTAssertEqual(entry?.resolved.cellHeight, 15)
    }

    func testQueryFontReplyMatchesResolvedMetrics() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        _ = session.feed(OpenFont(fid: 0x4400005, name: Array("7x14".utf8))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(QueryFont(font: 0x4400005)
            .encode(byteOrder: .lsbFirst))

        let reply = try QueryFontReply.decode(from: bytes, byteOrder: .lsbFirst)
        // 7x14 alias drifts to Monaco's natural cell at pointSize 10 (6x13).
        // QueryFont reports the truth so xterm sizes its window from real
        // metrics that match what we render.
        XCTAssertEqual(reply.minBounds.characterWidth, 6)
        XCTAssertEqual(reply.maxBounds.characterWidth, 6)
        XCTAssertEqual(reply.fontAscent + reply.fontDescent, 13)
        XCTAssertTrue(reply.allCharsExist)
        XCTAssertEqual(reply.minCharOrByte2, 32)
        XCTAssertEqual(reply.maxCharOrByte2, 126)
        // Monospace optimisation: charInfos empty means use minBounds for all.
        XCTAssertTrue(reply.charInfos.isEmpty)
    }

    func testImageText8DispatchesWithGCFontMetadata() {
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level window
        let createWin = CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        )
        _ = session.feed(createWin.encode(byteOrder: .lsbFirst))

        // Open a 9x15 font
        _ = session.feed(OpenFont(fid: 0x4400005, name: Array("9x15".utf8))
            .encode(byteOrder: .lsbFirst))

        // Allocate red so AllocColor returns pixel=16 with R=0xFFFF
        _ = session.feed(AllocColor(cmap: 0x21, red: 0xFFFF, green: 0, blue: 0)
            .encode(byteOrder: .lsbFirst))

        // CreateGC with foreground=16 + font=0x4400005
        let foregroundBytes = encodeUInt32(16, byteOrder: .lsbFirst)
        let backgroundBytes = encodeUInt32(0xFFFFFF, byteOrder: .lsbFirst)
        let fontBytes = encodeUInt32(0x4400005, byteOrder: .lsbFirst)
        let valueMask = GCBits.foreground | GCBits.background | GCBits.font
        // Bits in ascending order: foreground (1<<2), background (1<<3), font (1<<14)
        let valueList = foregroundBytes + backgroundBytes + fontBytes
        let gc = CreateGC(cid: 0xB0001, drawable: 0xA0001,
                          valueMask: valueMask, valueList: valueList)
        _ = session.feed(gc.encode(byteOrder: .lsbFirst))

        // ImageText8 "Hi" at (10, 30)
        let req = ImageText8(drawable: 0xA0001, gc: 0xB0001,
                             x: 10, y: 30, string: Array("Hi".utf8))
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.imageText8Calls.count, 1)
        let call = bridge.imageText8Calls[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        XCTAssertEqual(call.fontName, "Monaco")
        // 9x15 alias → Monaco-natural 7x15 at pointSize 11.
        XCTAssertEqual(call.cellWidth, 7)
        XCTAssertEqual(call.cellHeight, 15)
        XCTAssertEqual(call.foreground, RGB16(red: 0xFFFF, green: 0, blue: 0))
        XCTAssertEqual(call.background, RGB16(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
        XCTAssertEqual(call.x, 10)
        XCTAssertEqual(call.y, 30)
        XCTAssertEqual(call.string, Array("Hi".utf8))
    }

    func testPolyFillRectangleDispatchTranslatesCoordinates() {
        let bridge = RecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level + descendant at offset (10, 20)
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: 0xA0002, parent: 0xA0001,
            x: 10, y: 20, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))

        let gc = CreateGC(cid: 0xB0001, drawable: 0xA0002, valueMask: 0, valueList: [])
        _ = session.feed(gc.encode(byteOrder: .lsbFirst))

        // Fill a 50x50 rect at (5, 5) in the descendant.
        let req = PolyFillRectangle(drawable: 0xA0002, gc: 0xB0001,
                                    rectangles: [Framer.Rectangle(x: 5, y: 5, width: 50, height: 50)])
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.fillRectsCalls.count, 1)
        let call = bridge.fillRectsCalls[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        // Translated: descendant offset (10, 20) + rect (5, 5) = (15, 25)
        XCTAssertEqual(call.rectangles, [Framer.Rectangle(x: 15, y: 25, width: 50, height: 50)])
    }

    private func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }
}
