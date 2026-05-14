import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Recording bridge that captures every drawing call. Test verifies that
// ServerSession resolves drawables to top-levels, translates coordinates,
// resolves colors via ColorTable, and applies GC state.
private final class RecordingBridge: WindowBridge, @unchecked Sendable {
    struct PolySegmentCall: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var lineWidth: UInt32
        var segments: [LineSegment]
    }
    struct FillPolyCall: Equatable {
        var topLevel: UInt32
        var foreground: RGB16
        var points: [DrawPoint]
        var evenOdd: Bool
    }
    struct ClearAreaCall: Equatable {
        var topLevel: UInt32
        var x: Int16; var y: Int16; var width: UInt16; var height: UInt16
        var background: RGB16
    }

    var polySegments: [PolySegmentCall] = []
    var fillPolys: [FillPolyCall] = []
    var clearAreas: [ClearAreaCall] = []
    var registered: [(UInt32, TopLevelGeometry)] = []

    func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {
        registered.append((id, geometry))
    }
    func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
    func setTopLevelTitle(id: UInt32, title: String) {}

    func drawPolySegment(topLevel: UInt32, foreground: RGB16, lineWidth: UInt32, segments: [LineSegment]) {
        polySegments.append(PolySegmentCall(topLevel: topLevel, foreground: foreground, lineWidth: lineWidth, segments: segments))
    }
    func drawFillPoly(topLevel: UInt32, foreground: RGB16, points: [DrawPoint], evenOdd: Bool) {
        fillPolys.append(FillPolyCall(topLevel: topLevel, foreground: foreground, points: points, evenOdd: evenOdd))
    }
    func clearArea(topLevel: UInt32, x: Int16, y: Int16, width: UInt16, height: UInt16, background: RGB16) {
        clearAreas.append(ClearAreaCall(topLevel: topLevel, x: x, y: y, width: width, height: height, background: background))
    }
}

final class DrawingDispatchTests: XCTestCase {

    func testPolySegmentResolvesTopLevelAndForeground() {
        let bridge = RecordingBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level
        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200)
        // Child at (10, 20) inside top-level
        sendCreate(session, wid: 0xA0002, parent: 0xA0001, x: 10, y: 20, w: 100, h: 100)

        // Allocate a red color so we have a known pixel for the GC.
        let alloc = AllocColor(cmap: 0x21, red: 0xFFFF, green: 0, blue: 0)
        _ = session.feed(alloc.encode(byteOrder: .lsbFirst))

        // The first AllocColor returns pixel = 16 (ColorTable.nextPixel start).
        // Build a CreateGC with foreground=16.
        let foregroundBytes = encodeUInt32(16, byteOrder: .lsbFirst)
        let createGC = CreateGC(cid: 0xB0001, drawable: 0xA0002,
                                valueMask: GCBits.foreground,
                                valueList: foregroundBytes)
        _ = session.feed(createGC.encode(byteOrder: .lsbFirst))

        // PolySegment in child's coords (5, 5) → (50, 50). Should land at
        // top-level coords (15, 25) → (60, 70) because child is at (10, 20).
        let req = PolySegment(drawable: 0xA0002, gc: 0xB0001, segments: [
            Segment(x1: 5, y1: 5, x2: 50, y2: 50)
        ])
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.polySegments.count, 1)
        let call = bridge.polySegments[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        XCTAssertEqual(call.foreground, RGB16(red: 0xFFFF, green: 0, blue: 0))
        XCTAssertEqual(call.segments, [LineSegment(x1: 15, y1: 25, x2: 60, y2: 70)])
    }

    func testFillPolyEvenOddDefault() {
        let bridge = RecordingBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200)
        let createGC = CreateGC(cid: 0xB0001, drawable: 0xA0001,
                                valueMask: 0, valueList: [])
        _ = session.feed(createGC.encode(byteOrder: .lsbFirst))

        let req = FillPoly(drawable: 0xA0001, gc: 0xB0001, shape: .convex,
                           coordinateMode: .origin,
                           points: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 5, y: 10)])
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.fillPolys.count, 1)
        let call = bridge.fillPolys[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        // Default fill rule is EvenOdd per X11 spec.
        XCTAssertTrue(call.evenOdd)
        XCTAssertEqual(call.points, [
            DrawPoint(x: 0, y: 0), DrawPoint(x: 10, y: 0), DrawPoint(x: 5, y: 10)
        ])
    }

    func testClearAreaUsesWindowBackground() {
        let bridge = RecordingBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Allocate color (0x8000, 0x4000, 0x2000) — pixel = 16.
        _ = session.feed(AllocColor(cmap: 0x21, red: 0x8000, green: 0x4000, blue: 0x2000).encode(byteOrder: .lsbFirst))

        // CreateWindow with CWBackPixel = 16
        let backPixel = encodeUInt32(16, byteOrder: .lsbFirst)
        let createWin = CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: CW.backPixel, valueList: backPixel
        )
        _ = session.feed(createWin.encode(byteOrder: .lsbFirst))

        let req = ClearArea(exposures: false, window: 0xA0001, x: 5, y: 5, width: 50, height: 50)
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.clearAreas.count, 1)
        let call = bridge.clearAreas[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        XCTAssertEqual(call.background, RGB16(red: 0x8000, green: 0x4000, blue: 0x2000))
        XCTAssertEqual(call.width, 50)
        XCTAssertEqual(call.height, 50)
    }

    // MARK: - Helpers

    private func sendCreate(_ session: ServerSession, wid: UInt32, parent: UInt32, x: Int16, y: Int16, w: UInt16, h: UInt16) {
        let req = CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }

    private func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }
}
