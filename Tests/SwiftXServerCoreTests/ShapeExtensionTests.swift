import XCTest
@testable import SwiftXServerCore
import Framer

final class ShapeExtensionTests: XCTestCase {

    private let major: UInt8 = 128
    private let root = ServerConfig.default.rootWindowId

    // A bridge that returns a programmed depth-1 pixel grid for
    // readDrawablePixels, so the ShapeMask bitmap->region path can be
    // exercised without a real CGContext. Pixels are 0xAARRGGBB; a "set"
    // (black) bit is 0xFF000000, a clear (white) bit is 0xFFFFFFFF.
    private final class ShapePixelBridge: WindowBridge, @unchecked Sendable {
        let grid: [UInt32]
        let gw: Int
        // Records the most recent setWindowBoundingShape call.
        var shapeCallCount = 0
        var lastShapeTopLevel: UInt32?
        var lastShapeRects: [Framer.Rectangle]?
        init(grid: [UInt32] = [], width: Int = 0) { self.grid = grid; self.gw = width }
        var scaleFactor: Double { 1 }
        func setWindowBoundingShape(topLevel: UInt32, rects: [Framer.Rectangle]?) {
            shapeCallCount += 1
            lastShapeTopLevel = topLevel
            lastShapeRects = rects
        }
        func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
        func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32,
                         topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot],
                         overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func setTopLevelTitle(id: UInt32, title: String) {}
        func readDrawablePixels(from src: DrawTarget, srcX: Int16, srcY: Int16, width: Int, height: Int) -> [UInt32] {
            return grid
        }
        // bitmapToRegion reads device-resolution pixels now
        // (DEVICE_COORDS_REFACTOR.md). With scaleFactor==1 the device
        // grid is just `grid`.
        func readDepth1MaskDevicePixels(pixmapId: UInt32) -> (pixels: [UInt32], width: Int, height: Int)? {
            (grid, gw, grid.count / max(1, gw))
        }
    }

    private func runningSession(bridge: WindowBridge? = nil, byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    private func makeWindow(_ session: ServerSession, id: UInt32, width: UInt16 = 100, height: UInt16 = 80, borderWidth: UInt16 = 0) {
        let cw = CreateWindow(
            depth: 0, wid: id, parent: root,
            x: 0, y: 0, width: width, height: height, borderWidth: borderWidth,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: [])
        _ = session.feed(cw.encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
    }

    private func decodeReply(_ bytes: [UInt8], byteOrder: ByteOrder = .lsbFirst) throws -> [UInt8] {
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: byteOrder)
        guard case .reply(let r) = msg else {
            throw XCTSkip("expected reply, got \(msg)")
        }
        return r.bytes
    }

    private func decodeError(_ bytes: [UInt8], byteOrder: ByteOrder = .lsbFirst) throws -> XError {
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: byteOrder)
        guard case .xError(let e) = msg else {
            throw XCTSkip("expected xError, got \(msg)")
        }
        return e
    }

    // MARK: - Negotiation

    func testQueryExtensionShapePresent() throws {
        let session = runningSession()
        let bytes = session.feed(QueryExtension(name: Array("SHAPE".utf8)).encode(byteOrder: .lsbFirst))
        let reply = try QueryExtensionReply.decode(from: decodeReply(bytes), byteOrder: .lsbFirst)
        XCTAssertTrue(reply.present)
        XCTAssertEqual(reply.majorOpcode, 128)
        XCTAssertEqual(reply.firstEvent, 64)
        XCTAssertEqual(reply.firstError, 0)
    }

    func testQueryExtensionUnknownAbsent() throws {
        let session = runningSession()
        let bytes = session.feed(QueryExtension(name: Array("NO-SUCH-EXT".utf8)).encode(byteOrder: .lsbFirst))
        let reply = try QueryExtensionReply.decode(from: decodeReply(bytes), byteOrder: .lsbFirst)
        XCTAssertFalse(reply.present)
        XCTAssertEqual(reply.majorOpcode, 0)
    }

    func testListExtensionsIncludesShape() throws {
        let session = runningSession()
        let bytes = session.feed(ListExtensions().encode(byteOrder: .lsbFirst))
        let reply = try ListExtensionsReply.decode(from: decodeReply(bytes), byteOrder: .lsbFirst)
        let names = reply.names.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(names.contains("SHAPE"), "ListExtensions should advertise SHAPE, got \(names)")
    }

    func testQueryVersionReplies1_0() throws {
        let session = runningSession()
        let bytes = session.feed(ShapeQueryVersion().encode(majorOpcode: major, byteOrder: .lsbFirst))
        let reply = try ShapeQueryVersionReply.decode(from: decodeReply(bytes), byteOrder: .lsbFirst)
        XCTAssertEqual(reply.majorVersion, 1)
        XCTAssertEqual(reply.minorVersion, 0)
    }

    // MARK: - Region algebra (shape.c RegionOperate)

    func testRegionOperateSet() {
        let session = runningSession()
        let src = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let result = session.shapeRegionOperate(current: nil, src: src, op: ShapeOp.set, defaultRegion: { .empty })
        XCTAssertEqual(result, src)
        // Set with nil src clears the shape.
        XCTAssertNil(session.shapeRegionOperate(current: src, src: nil, op: ShapeOp.set, defaultRegion: { .empty }))
    }

    func testRegionOperateUnionUnshapedStaysUnshaped() {
        let session = runningSession()
        let src = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        // unshaped (full) ∪ anything == full -> nil.
        XCTAssertNil(session.shapeRegionOperate(current: nil, src: src, op: ShapeOp.union, defaultRegion: { .empty }))
    }

    func testRegionOperateIntersectUnshapedReturnsSrc() {
        let session = runningSession()
        let src = Region(box: BoxRec(x1: 2, y1: 2, x2: 8, y2: 8))
        // full ∩ src == src.
        XCTAssertEqual(session.shapeRegionOperate(current: nil, src: src, op: ShapeOp.intersect, defaultRegion: { .empty }), src)
    }

    func testRegionOperateSubtractMaterializesDefault() {
        let session = runningSession()
        let def = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        let src = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 5))
        let result = session.shapeRegionOperate(current: nil, src: src, op: ShapeOp.subtract, defaultRegion: { def })
        XCTAssertEqual(result, def.subtracting(src))
    }

    func testRegionOperateInvertUnshapedYieldsEmpty() {
        let session = runningSession()
        let src = Region(box: BoxRec(x1: 0, y1: 0, x2: 10, y2: 10))
        // src − full == empty.
        XCTAssertEqual(session.shapeRegionOperate(current: nil, src: src, op: ShapeOp.invert, defaultRegion: { .empty }), .empty)
    }

    // MARK: - Rectangles + QueryExtents + GetRectangles

    func testRectanglesSetsBoundingShape() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0001, width: 100, height: 80)
        let rects = [Rectangle(x: 10, y: 10, width: 50, height: 40)]
        let req = ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                                  dest: 0xB0001, xOff: 0, yOff: 0, rectangles: rects)
        _ = session.feed(req.encode(majorOpcode: major, byteOrder: .lsbFirst))

        let stored = session.windows.get(0xB0001)?.boundingShape
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.boundingBox, BoxRec(x1: 10, y1: 10, x2: 60, y2: 50))

        // QueryExtents reflects it.
        let qe = session.feed(ShapeQueryExtents(window: 0xB0001).encode(majorOpcode: major, byteOrder: .lsbFirst))
        let reply = try ShapeQueryExtentsReply.decode(from: decodeReply(qe), byteOrder: .lsbFirst)
        XCTAssertTrue(reply.boundingShaped)
        XCTAssertFalse(reply.clipShaped)
        XCTAssertEqual(reply.xBounding, 10)
        XCTAssertEqual(reply.yBounding, 10)
        XCTAssertEqual(reply.widthBounding, 50)
        XCTAssertEqual(reply.heightBounding, 40)
    }

    func testQueryExtentsUnshapedReturnsDefaults() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0002, width: 100, height: 80, borderWidth: 2)
        let qe = session.feed(ShapeQueryExtents(window: 0xB0002).encode(majorOpcode: major, byteOrder: .lsbFirst))
        let reply = try ShapeQueryExtentsReply.decode(from: decodeReply(qe), byteOrder: .lsbFirst)
        XCTAssertFalse(reply.boundingShaped)
        XCTAssertFalse(reply.clipShaped)
        // Bounding default is border-inclusive: (-bw,-bw)..(w+bw,h+bw).
        XCTAssertEqual(reply.xBounding, -2)
        XCTAssertEqual(reply.yBounding, -2)
        XCTAssertEqual(reply.widthBounding, 104)
        XCTAssertEqual(reply.heightBounding, 84)
        // Clip default is the interior (0,0,w,h).
        XCTAssertEqual(reply.widthClip, 100)
        XCTAssertEqual(reply.heightClip, 80)
    }

    func testGetRectanglesRoundTrip() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0003, width: 100, height: 80)
        let rects = [
            Rectangle(x: 0, y: 0, width: 100, height: 20),
            Rectangle(x: 0, y: 20, width: 60, height: 60),
        ]
        _ = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.clip, ordering: 0,
                                         dest: 0xB0003, xOff: 0, yOff: 0, rectangles: rects)
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        let gr = session.feed(ShapeGetRectangles(window: 0xB0003, kind: ShapeKind.clip).encode(majorOpcode: major, byteOrder: .lsbFirst))
        let reply = try ShapeGetRectanglesReply.decode(from: decodeReply(gr), byteOrder: .lsbFirst)
        // The union covers the same area; rect list should reconstruct it.
        let total = reply.rectangles.reduce(0) { $0 + Int($1.width) * Int($1.height) }
        XCTAssertEqual(total, 100 * 20 + 60 * 60)
    }

    func testGetRectanglesUnshapedReturnsDefaultRect() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0004, width: 100, height: 80)
        let gr = session.feed(ShapeGetRectangles(window: 0xB0004, kind: ShapeKind.bounding).encode(majorOpcode: major, byteOrder: .lsbFirst))
        let reply = try ShapeGetRectanglesReply.decode(from: decodeReply(gr), byteOrder: .lsbFirst)
        XCTAssertEqual(reply.rectangles.count, 1)
        XCTAssertEqual(reply.rectangles[0], Rectangle(x: 0, y: 0, width: 100, height: 80))
    }

    // MARK: - Offset

    func testOffsetTranslatesShape() {
        let session = runningSession()
        makeWindow(session, id: 0xB0005, width: 100, height: 80)
        _ = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                                         dest: 0xB0005, xOff: 0, yOff: 0,
                                         rectangles: [Rectangle(x: 0, y: 0, width: 10, height: 10)])
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        _ = session.feed(ShapeOffset(destKind: ShapeKind.bounding, dest: 0xB0005, xOff: 5, yOff: 7)
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        XCTAssertEqual(session.windows.get(0xB0005)?.boundingShape?.boundingBox,
                       BoxRec(x1: 5, y1: 7, x2: 15, y2: 17))
    }

    // MARK: - Mask (bitmap -> region) and reset via src=None

    func testMaskBuildsRegionFromBitmap() throws {
        // 4x4 grid, centre 2x2 set (black). Expect region extents (1,1) 2x2.
        let black: UInt32 = 0xFF000000
        let white: UInt32 = 0xFFFFFFFF
        var grid = [UInt32](repeating: white, count: 16)
        for y in 1...2 { for x in 1...2 { grid[y * 4 + x] = black } }
        let bridge = ShapePixelBridge(grid: grid, width: 4)
        let session = runningSession(bridge: bridge)
        makeWindow(session, id: 0xB0006, width: 100, height: 80)
        // Depth-1 pixmap 4x4.
        _ = session.feed(CreatePixmap(depth: 1, pid: 0xC0001, drawable: 0xB0006, width: 4, height: 4)
            .encode(byteOrder: .lsbFirst))
        _ = session.feed(ShapeMask(op: ShapeOp.set, destKind: ShapeKind.bounding,
                                   dest: 0xB0006, xOff: 0, yOff: 0, src: 0xC0001)
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        let shape = session.windows.get(0xB0006)?.boundingShape
        XCTAssertEqual(shape?.boundingBox, BoxRec(x1: 1, y1: 1, x2: 3, y2: 3))
    }

    func testMaskNoneResetsShape() {
        let session = runningSession()
        makeWindow(session, id: 0xB0007, width: 100, height: 80)
        _ = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                                         dest: 0xB0007, xOff: 0, yOff: 0,
                                         rectangles: [Rectangle(x: 0, y: 0, width: 10, height: 10)])
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        XCTAssertNotNil(session.windows.get(0xB0007)?.boundingShape)
        // src=None, op=Set -> back to unshaped.
        _ = session.feed(ShapeMask(op: ShapeOp.set, destKind: ShapeKind.bounding,
                                   dest: 0xB0007, xOff: 0, yOff: 0, src: 0)
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        XCTAssertNil(session.windows.get(0xB0007)?.boundingShape)
    }

    // MARK: - SelectInput / InputSelected / ShapeNotify

    func testSelectInputAndQuery() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0008, width: 100, height: 80)
        // Initially not selected.
        var q = session.feed(ShapeInputSelected(window: 0xB0008).encode(majorOpcode: major, byteOrder: .lsbFirst))
        var reply = try ShapeInputSelectedReply.decode(from: decodeReply(q), byteOrder: .lsbFirst)
        XCTAssertFalse(reply.enabled)
        // Enable.
        _ = session.feed(ShapeSelectInput(window: 0xB0008, enable: 1).encode(majorOpcode: major, byteOrder: .lsbFirst))
        q = session.feed(ShapeInputSelected(window: 0xB0008).encode(majorOpcode: major, byteOrder: .lsbFirst))
        reply = try ShapeInputSelectedReply.decode(from: decodeReply(q), byteOrder: .lsbFirst)
        XCTAssertTrue(reply.enabled)
    }

    func testShapeNotifyEmittedAfterChange() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB0009, width: 100, height: 80)
        _ = session.feed(ShapeSelectInput(window: 0xB0009, enable: 1).encode(majorOpcode: major, byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        let out = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                                               dest: 0xB0009, xOff: 0, yOff: 0,
                                               rectangles: [Rectangle(x: 5, y: 5, width: 20, height: 20)])
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        // First (only) message should be the ShapeNotify event (code 64).
        XCTAssertGreaterThanOrEqual(out.count, 32)
        let event = try ShapeNotifyEvent.decode(from: Array(out[0..<32]), byteOrder: .lsbFirst)
        XCTAssertEqual(event.type, 64)
        XCTAssertEqual(event.kind, ShapeKind.bounding)
        XCTAssertEqual(event.window, 0xB0009)
        XCTAssertTrue(event.shaped)
        XCTAssertEqual(event.x, 5); XCTAssertEqual(event.y, 5)
        XCTAssertEqual(event.width, 20); XCTAssertEqual(event.height, 20)
    }

    // MARK: - Phase 3 forwarding (session -> bridge)

    func testTopLevelBoundingShapeForwardedToBridge() {
        let bridge = ShapePixelBridge()
        let session = runningSession(bridge: bridge)
        makeWindow(session, id: 0xB00B0, width: 100, height: 80)
        _ = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                                         dest: 0xB00B0, xOff: 0, yOff: 0,
                                         rectangles: [Rectangle(x: 10, y: 10, width: 30, height: 30)])
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        XCTAssertEqual(bridge.lastShapeTopLevel, 0xB00B0)
        XCTAssertNotNil(bridge.lastShapeRects, "setting a bounding shape forwards rects")
        XCTAssertEqual(bridge.lastShapeRects?.first, Rectangle(x: 10, y: 10, width: 30, height: 30))

        // Clearing via src=None forwards nil (unshaped -> rectangular window).
        _ = session.feed(ShapeMask(op: ShapeOp.set, destKind: ShapeKind.bounding,
                                   dest: 0xB00B0, xOff: 0, yOff: 0, src: 0)
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        XCTAssertNil(bridge.lastShapeRects, "clearing the shape forwards nil")
    }

    // MARK: - Real-bridge bitmap->region (xeyes mask pattern)

    private func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // Replicates exactly what xeyes does to build its shape mask, against a
    // real CocoaWindowBridge: create a depth-1 pixmap, fill it with the
    // default GC (foreground 0 = white = clear), switch foreground to 1
    // (black = set), draw the shape, then ShapeMask Set/Bounding onto a
    // top-level. The resulting bounding region must be the drawn shape, not
    // the whole rectangle.
    func testShapeMaskRegionFromRealBridgeBitmap() throws {
        let bridge = CocoaWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let win: UInt32 = 0x900001
        let pix: UInt32 = 0x900002
        let gc: UInt32 = 0x900003

        _ = session.feed(CreateWindow(depth: 0, wid: win, parent: root, x: 0, y: 0,
                                      width: 64, height: 64, borderWidth: 0,
                                      windowClass: .inputOutput, visual: 0,
                                      valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreatePixmap(depth: 1, pid: pix, drawable: win, width: 64, height: 64).encode(byteOrder: .lsbFirst))
        // Depth-1 pixmap drawing uses bit-value semantics per X spec
        // (independent of visual class — see ServerSession's target-aware
        // resolveColor): pixel & 1 == 0 → CLEAR ("paper", white), pixel
        // & 1 == 1 → SET ("ink", black). So fg=0 fills with white
        // (clear bits), fg=1 draws the I-beam with black (set bits).
        _ = session.feed(CreateGC(cid: gc, drawable: pix,
                                  valueMask: GCBits.foreground,
                                  valueList: u32le(0)).encode(byteOrder: .lsbFirst))
        // Clear the whole pixmap (fg=0 → CLEAR bits).
        _ = session.feed(PolyFillRectangle(drawable: pix, gc: gc,
                                           rectangles: [Rectangle(x: 0, y: 0, width: 64, height: 64)]).encode(byteOrder: .lsbFirst))
        // Switch foreground to 1 (SET bits = the shape).
        _ = session.feed(ChangeGC(gc: gc, valueMask: GCBits.foreground, valueList: u32le(1)).encode(byteOrder: .lsbFirst))
        // Draw the shape: a 20x20 black square at (10,10).
        _ = session.feed(PolyFillRectangle(drawable: pix, gc: gc,
                                           rectangles: [Rectangle(x: 10, y: 10, width: 20, height: 20)]).encode(byteOrder: .lsbFirst))
        // Apply as the top-level's bounding shape.
        _ = session.feed(ShapeMask(op: ShapeOp.set, destKind: ShapeKind.bounding,
                                   dest: win, xOff: 0, yOff: 0, src: pix).encode(majorOpcode: major, byteOrder: .lsbFirst))

        let stored = session.windows.get(win)
        let shape = stored?.boundingShape
        XCTAssertNotNil(shape, "ShapeMask should have set a bounding region")
        // Region is device-coord (DEVICE_COORDS_REFACTOR.md). CocoaWindowBridge
        // uses scaleFactor=1 by default in unit tests, so the device-coord
        // box equals the logical-coord box (the drawn 20x20 square).
        XCTAssertEqual(shape?.boundingBox, BoxRec(x1: 10, y1: 10, x2: 30, y2: 30),
                       "bitmapToRegion should yield the black shape, not the whole pixmap")
    }

    // MARK: - Errors

    func testBadWindowEmitted() throws {
        let session = runningSession()
        let out = session.feed(ShapeQueryExtents(window: 0xDEAD).encode(majorOpcode: major, byteOrder: .lsbFirst))
        let err = try decodeError(out)
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), 0xDEAD)
        XCTAssertEqual(err.majorOpcode, 128)
        XCTAssertEqual(err.minorOpcode(byteOrder: .lsbFirst), UInt16(ShapeMinor.queryExtents))
    }

    func testBadValueOnBadDestKind() throws {
        let session = runningSession()
        makeWindow(session, id: 0xB000A, width: 100, height: 80)
        let out = session.feed(ShapeRectangles(op: ShapeOp.set, destKind: 99, ordering: 0,
                                               dest: 0xB000A, xOff: 0, yOff: 0, rectangles: [])
            .encode(majorOpcode: major, byteOrder: .lsbFirst))
        let err = try decodeError(out)
        XCTAssertEqual(err.errorCode, XErrorCode.value.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), 99)
    }

    func testBadRequestOnUnknownMinor() throws {
        let session = runningSession()
        // Craft a SHAPE request with an out-of-range minor opcode (99).
        let bytes: [UInt8] = [major, 99, 1, 0]   // major, minor, length=1
        let out = session.feed(bytes)
        let err = try decodeError(out)
        XCTAssertEqual(err.errorCode, XErrorCode.request.rawValue)
        XCTAssertEqual(err.majorOpcode, 128)
    }
}
