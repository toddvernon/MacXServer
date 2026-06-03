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
        var capStyle: UInt8
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
        var rects: [Framer.Rectangle]
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

    func drawPolySegment(target: DrawTarget, foreground: RGB16, lineWidth: UInt32, capStyle: UInt8, segments: [LineSegment], clipRectangles: [Framer.Rectangle]?, dashes: [UInt8]?, dashOffset: UInt32) {
        guard case .window(_, let topLevel, _, _) = target else { return }
        polySegments.append(PolySegmentCall(topLevel: topLevel, foreground: foreground, lineWidth: lineWidth, capStyle: capStyle, segments: segments))
    }
    func drawFillPoly(target: DrawTarget, foreground: RGB16, points: [DrawPoint], evenOdd: Bool, clipRectangles: [Framer.Rectangle]?) {
        guard case .window(_, let topLevel, _, _) = target else { return }
        fillPolys.append(FillPolyCall(topLevel: topLevel, foreground: foreground, points: points, evenOdd: evenOdd))
    }
    func clearArea(topLevel: UInt32, rects: [Framer.Rectangle], background: RGB16) {
        clearAreas.append(ClearAreaCall(topLevel: topLevel, rects: rects, background: background))
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
        // Default cap-style is Butt (1) per X11 spec.
        XCTAssertEqual(call.capStyle, 1)
    }

    /// Regression: cap-style from CreateGC must propagate through GCState
    /// into the bridge so CG can set the line cap. xcalc/Athena's
    /// `XmuShapeOval` draws each button's bounding-shape pixmap as a single
    /// thick line with `cap_style = CapRound` (2) + `line_width = button
    /// height`, relying on the rounded caps to turn the line into a
    /// stadium. Pre-fix the byte was silently dropped, CG defaulted to
    /// butt, the bounding pixmap read back as a flat-ended rectangle, and
    /// buttons rendered square with black blocks on the sides.
    func testPolySegmentPropagatesCapStyle() {
        let bridge = RecordingBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200)

        // GC mask = lineWidth | capStyle; values = lineWidth=15 then capStyle=2 (Round).
        // GCBits order in the values list is by bit index (function ... capStyle).
        var values: [UInt8] = []
        values.append(contentsOf: encodeUInt32(15, byteOrder: .lsbFirst))           // lineWidth
        values.append(contentsOf: encodeUInt32(2,  byteOrder: .lsbFirst))           // capStyle = CapRound
        let createGC = CreateGC(cid: 0xB0001, drawable: 0xA0001,
                                valueMask: GCBits.lineWidth | GCBits.capStyle,
                                valueList: values)
        _ = session.feed(createGC.encode(byteOrder: .lsbFirst))

        _ = session.feed(PolySegment(drawable: 0xA0001, gc: 0xB0001, segments: [
            Segment(x1: 5, y1: 5, x2: 50, y2: 5)
        ]).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.polySegments.count, 1)
        XCTAssertEqual(bridge.polySegments[0].capStyle, 2)
        XCTAssertEqual(bridge.polySegments[0].lineWidth, 15)
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
        // Map so the window has a non-empty clipList; without this, the
        // post-2026-05-20 ClearArea-clipped-by-visible-region semantics
        // give zero clipped rects (unmapped windows are fully obscured).
        _ = session.feed(Request.mapWindow(MapWindow(window: 0xA0001)).encode(byteOrder: .lsbFirst))

        let req = ClearArea(exposures: false, window: 0xA0001, x: 5, y: 5, width: 50, height: 50)
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.clearAreas.count, 1)
        let call = bridge.clearAreas[0]
        XCTAssertEqual(call.topLevel, 0xA0001)
        XCTAssertEqual(call.background, RGB16(red: 0x8000, green: 0x4000, blue: 0x2000))
        // Single rect; window is unobscured so clipList ∩ request = request.
        // Request is (5,5,50,50) in window-local coords; window is the
        // top-level so window-local == top-level coords.
        XCTAssertEqual(call.rects.count, 1)
        XCTAssertEqual(call.rects[0].x, 5)
        XCTAssertEqual(call.rects[0].y, 5)
        XCTAssertEqual(call.rects[0].width, 50)
        XCTAssertEqual(call.rects[0].height, 50)
    }

    /// Regression: ClearArea on a parent must be clipped to the parent's
    /// visible region. Without this, the parent's bg pixel paints right
    /// through any mapped descendant whose clipList would mask the parent
    /// — the dthelpview 2026-05-19 "leftover blue button rectangles inside
    /// the white DisplayArea on expand" bug.
    func testClearAreaClippedByMappedChildren() {
        let bridge = RecordingBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        let backPixel = encodeUInt32(0, byteOrder: .lsbFirst)
        let parentCW = CreateWindow(
            depth: 0, wid: 0xA0001, parent: root,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: CW.backPixel, valueList: backPixel
        )
        _ = session.feed(parentCW.encode(byteOrder: .lsbFirst))
        // Child covering the middle (50,50)-(150,150) of the parent.
        let childCW = CreateWindow(
            depth: 0, wid: 0xA0002, parent: 0xA0001,
            x: 50, y: 50, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: CW.backPixel, valueList: backPixel
        )
        _ = session.feed(childCW.encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.mapWindow(MapWindow(window: 0xA0001)).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.mapWindow(MapWindow(window: 0xA0002)).encode(byteOrder: .lsbFirst))
        bridge.clearAreas.removeAll()

        // ClearArea on the PARENT, asking for the full window area. Spec
        // says clip to parent's visible region — i.e., everywhere the
        // child doesn't cover.
        let req = ClearArea(exposures: false, window: 0xA0001, x: 0, y: 0, width: 200, height: 200)
        _ = session.feed(req.encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.clearAreas.count, 1)
        let rects = bridge.clearAreas[0].rects
        // The parent has visible area = 200*200 - 100*100 = 30000 sq pixels.
        let totalArea = rects.reduce(0) { $0 + Int($1.width) * Int($1.height) }
        XCTAssertEqual(totalArea, 200 * 200 - 100 * 100,
                       "clipped rect union should equal parent area minus child area")

        // No clipped rect should contain a point inside the child's region.
        // (100,100) is the dead center of the child window.
        for r in rects {
            let xs = Int(r.x), xe = xs + Int(r.width)
            let ys = Int(r.y), ye = ys + Int(r.height)
            XCTAssertFalse((100 >= xs && 100 < xe) && (100 >= ys && 100 < ye),
                           "rect \(r) overlaps the child's covered area")
        }
        // Corner (10,10) is in the parent's visible region — at least one
        // rect should cover it.
        XCTAssertTrue(rects.contains { r in
            let xs = Int(r.x), xe = xs + Int(r.width)
            let ys = Int(r.y), ye = ys + Int(r.height)
            return 10 >= xs && 10 < xe && 10 >= ys && 10 < ye
        }, "expected at least one rect to cover the (10,10) corner of the parent")
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
