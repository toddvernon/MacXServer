import XCTest
@testable import SwiftXServerCore
import Framer

// CW* attribute round-trip via ChangeWindowAttributes + GetWindowAttributes.
// Pre-2026-05-15 we dropped most CW bits on the write side and returned
// zeros for them on the read side — an XError-honesty violation flagged
// by the comparison study (synthesis #6 "ChangeWindowAttributes attribute
// drops"). Now stored on WindowEntry and echoed back faithfully.

final class ChangeWindowAttributesTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let s = ServerSession()
        _ = s.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = s.outbound.drain()
        return s
    }

    /// Create a top-level child of root. Returns the wid.
    private func createTopLevel(_ session: ServerSession) -> UInt32 {
        let wid: UInt32 = ServerConfig.default.resourceIdBase + UInt32.random(in: 0x100...0xFFF)
        let req = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return wid
    }

    /// Build a CW* valueList from (bit, value) tuples. Values must be
    /// supplied in ascending bit-position order to match the X11 wire
    /// convention (low bits first).
    private func valueList(_ pairs: [(bit: UInt32, value: UInt32)]) -> [UInt8] {
        var out: [UInt8] = []
        for (_, v) in pairs.sorted(by: { $0.bit < $1.bit }) {
            for shift in [0, 8, 16, 24] {
                out.append(UInt8(truncatingIfNeeded: v >> shift))
            }
        }
        return out
    }

    /// Drive GetWindowAttributes and decode the reply.
    private func queryAttributes(_ session: ServerSession, _ wid: UInt32) throws -> GetWindowAttributesReply {
        let bytes = session.feed(Request.getWindowAttributes(GetWindowAttributes(window: wid))
            .encode(byteOrder: .lsbFirst))
        guard bytes.count >= 44 else {
            struct Truncated: Error {}
            throw Truncated()
        }
        return try GetWindowAttributesReply.decode(from: bytes, byteOrder: .lsbFirst)
    }

    func testGetWindowAttributesReturnsSpecDefaults() throws {
        // Brand-new window with no CW* values should report the spec
        // defaults: bit-gravity Forget (0), win-gravity NorthWest (1),
        // backing-store NotUseful (0), save-under false, override-
        // redirect false, do-not-propagate 0, colormap = default.
        let s = runningSession()
        let wid = createTopLevel(s)
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.bitGravity, 0)
        XCTAssertEqual(r.winGravity, 1)
        XCTAssertEqual(r.backingStore, 0)
        XCTAssertFalse(r.saveUnder)
        XCTAssertFalse(r.overrideRedirect)
        XCTAssertEqual(r.doNotPropagateMask, 0)
        XCTAssertEqual(r.colormap, ServerConfig.default.defaultColormapId)
        XCTAssertEqual(r.backingBitPlanes, ~UInt32(0))
    }

    func testChangeWindowAttributesPersistsBitGravity() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        // CWBitGravity = 1<<4; set to NorthEast (3).
        let vl = valueList([(CW.bitGravity, 3)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.bitGravity, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.bitGravity, 3)
    }

    func testChangeWindowAttributesPersistsBackingStore() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        // CWBackingStore set to Always (2). We don't honor it visually
        // but spec wants the read-back to echo.
        let vl = valueList([(CW.backingStore, 2)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backingStore, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.backingStore, 2)
    }

    func testChangeWindowAttributesPersistsSaveUnder() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        let vl = valueList([(CW.saveUnder, 1)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.saveUnder, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertTrue(r.saveUnder)
    }

    func testChangeWindowAttributesOverrideRedirectMidLife() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        XCTAssertFalse((try queryAttributes(s, wid)).overrideRedirect)
        let vl = valueList([(CW.overrideRedirect, 1)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.overrideRedirect, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        XCTAssertTrue((try queryAttributes(s, wid)).overrideRedirect,
                      "override-redirect mid-life flip must round-trip")
    }

    func testChangeWindowAttributesPersistsDoNotPropagate() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        let vl = valueList([(CW.dontPropagate, 0x00FF)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.dontPropagate, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.doNotPropagateMask, 0x00FF)
    }

    func testChangeWindowAttributesPersistsColormap() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        // Set a non-default colormap id. We don't validate or actually
        // install — just store and echo per spec.
        let custom: UInt32 = 0x4400077
        let vl = valueList([(CW.colormap, custom)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.colormap, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.colormap, custom)
    }

    func testChangeWindowAttributesColormapCopyFromParentSentinel() throws {
        // CWColormap = 0 means CopyFromParent. The read-back should not
        // be 0; it should resolve to (currently) the screen's default
        // since we don't walk the parent chain.
        let s = runningSession()
        let wid = createTopLevel(s)
        let vl = valueList([(CW.colormap, 0)])
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.colormap, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.colormap, ServerConfig.default.defaultColormapId)
    }

    func testCreateWindowSeedsAllCWAttributes() throws {
        // Combined CW mask at CreateWindow time: bit-gravity 5 (Center),
        // win-gravity 8 (South), backing-store 1 (WhenMapped),
        // save-under 1, override-redirect 1.
        let s = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 0x800
        let mask = CW.bitGravity | CW.winGravity | CW.backingStore
                 | CW.saveUnder | CW.overrideRedirect
        let vl = valueList([
            (CW.bitGravity, 5),
            (CW.winGravity, 8),
            (CW.backingStore, 1),
            (CW.overrideRedirect, 1),    // bit 9 — comes after backing-store(6)
            (CW.saveUnder, 1),           // bit 10 — comes after override-redirect(9)
        ])
        _ = s.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 50, height: 50, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: mask, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()

        let r = try queryAttributes(s, wid)
        XCTAssertEqual(r.bitGravity, 5)
        XCTAssertEqual(r.winGravity, 8)
        XCTAssertEqual(r.backingStore, 1)
        XCTAssertTrue(r.saveUnder)
        XCTAssertTrue(r.overrideRedirect)
    }

    // MARK: - CWBackPixmap

    /// Bridge that records calls to paintWindowFromPixmap so we can verify
    /// the bg-pixmap blit fires at MapWindow time with the right pixmap id.
    private final class PixmapPaintRecBridge: WindowBridge, @unchecked Sendable {
        struct PixmapCall: Equatable {
            var topLevel: UInt32
            var sourcePixmapId: UInt32
            var rectCount: Int
            var originDeviceX: Int32
            var originDeviceY: Int32
        }
        var pixmapCalls: [PixmapCall] = []
        func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
        func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func setTopLevelTitle(id: UInt32, title: String) {}
        func paintWindowFromPixmap(
            topLevel: UInt32, sourcePixmapId: UInt32,
            rects: [BoxRec], originDeviceX: Int32, originDeviceY: Int32
        ) {
            pixmapCalls.append(PixmapCall(
                topLevel: topLevel, sourcePixmapId: sourcePixmapId,
                rectCount: rects.count,
                originDeviceX: originDeviceX, originDeviceY: originDeviceY
            ))
        }
    }

    func testCWBackPixmapStoredAndClearsBackPixel() throws {
        // Setting CWBackPixmap = real pixmap id stores it on the WindowEntry
        // and implicitly clears any prior CWBackPixel.
        let s = runningSession()
        let wid = createTopLevel(s)
        // Pre-set backPixel so we can verify it gets cleared.
        s.windows.setBackPixel(wid, 0x00ABCDEF)
        // Allocate a matching-depth pixmap to use as the bg source.
        let pixId: UInt32 = ServerConfig.default.resourceIdBase + 0x80
        _ = s.feed(CreatePixmap(depth: 24, pid: pixId, drawable: ServerConfig.default.rootWindowId,
                                 width: 16, height: 16).encode(byteOrder: .lsbFirst))
        // Need to create the *target* window at depth 24 so the depth-match
        // validation passes (the helper makes it depth 8 by default; rebuild here).
        let depth24Wid = ServerConfig.default.resourceIdBase + 0x91
        _ = s.feed(Request.createWindow(CreateWindow(
            depth: 24, wid: depth24Wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 50, height: 50, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        s.windows.setBackPixel(depth24Wid, 0x00112233)
        _ = s.outbound.drain()

        let vl = valueList([(CW.backPixmap, pixId)])
        let bytes = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: depth24Wid, valueMask: CW.backPixmap, valueList: vl
        )).encode(byteOrder: .lsbFirst))
        // No error expected.
        if !bytes.isEmpty { XCTAssertNotEqual(bytes[0], 0, "must not emit XError on matching depth") }

        let entry = try XCTUnwrap(s.windows.get(depth24Wid))
        XCTAssertEqual(entry.backPixmapId, pixId, "CWBackPixmap stored on entry")
        XCTAssertNil(entry.backPixel, "CWBackPixel implicitly cleared by CWBackPixmap")
        XCTAssertFalse(entry.backPixmapParentRelative)

        // Reverse: setting CWBackPixel afterward clears the pixmap state.
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: depth24Wid, valueMask: CW.backPixel,
            valueList: valueList([(CW.backPixel, 0xCAFEBABE)])
        )).encode(byteOrder: .lsbFirst))
        let after = try XCTUnwrap(s.windows.get(depth24Wid))
        XCTAssertEqual(after.backPixel, 0xCAFEBABE)
        XCTAssertNil(after.backPixmapId, "CWBackPixel clears prior CWBackPixmap")
    }

    func testCWBackPixmapNoneClearsAllBgState() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        s.windows.setBackPixel(wid, 0x123456)
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, 0)])     // 0 = None
        )).encode(byteOrder: .lsbFirst))
        let e = try XCTUnwrap(s.windows.get(wid))
        XCTAssertNil(e.backPixel)
        XCTAssertNil(e.backPixmapId)
        XCTAssertFalse(e.backPixmapParentRelative)
    }

    func testCWBackPixmapParentRelativeFlag() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        _ = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, 1)])     // 1 = ParentRelative
        )).encode(byteOrder: .lsbFirst))
        let e = try XCTUnwrap(s.windows.get(wid))
        XCTAssertTrue(e.backPixmapParentRelative)
        XCTAssertNil(e.backPixmapId)
        XCTAssertNil(e.backPixel)
    }

    func testCWBackPixmapEmitsBadPixmapOnUnknownId() throws {
        let s = runningSession()
        let wid = createTopLevel(s)
        let bytes = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, 0xDEADBEEF)])
        )).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bytes[0], 0, "X error first byte is 0")
        XCTAssertEqual(bytes[1], 4, "error code 4 = BadPixmap")
        // Entry unchanged — invalid request didn't mutate stored bg state.
        let e = try XCTUnwrap(s.windows.get(wid))
        XCTAssertNil(e.backPixmapId)
    }

    func testCWBackPixmapEmitsBadMatchOnDepthMismatch() throws {
        let s = runningSession()
        let wid = createTopLevel(s)    // depth 8
        // Pixmap at depth-1 — won't match the window's depth.
        let pixId: UInt32 = ServerConfig.default.resourceIdBase + 0xA0
        _ = s.feed(CreatePixmap(depth: 1, pid: pixId, drawable: ServerConfig.default.rootWindowId,
                                 width: 8, height: 8).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        let bytes = s.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, pixId)])
        )).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 8, "error code 8 = BadMatch")
    }

    /// xli's pan idiom: outer parent window stays still, inner child has the
    /// bg-pixmap and gets ConfigureWindow'd to a more-negative Y on every
    /// MotionNotify. The newly-visible strip at the child's leading edge
    /// must be re-painted from the bg-pixmap regardless of whether the
    /// child selected ExposureMask — pre-fix, xli's child has no
    /// ExposureMask and the strip kept showing stale pixmap content from
    /// MapWindow time, producing accumulating vertical-streak smears as
    /// pan progressed.
    func testPureMoveOnBackPixmapWindowRepaintsFromPixmap() throws {
        let bridge = PixmapPaintRecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        // Parent: viewport-sized top-level (matches xli's outer 0x...6).
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 0xC0
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 24, wid: parent, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 64, height: 32, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))

        // Child: image-sized, bg-pixmap, NO ExposureMask. Mirrors xli's
        // pannable inner 0x...7 window.
        let child: UInt32 = ServerConfig.default.resourceIdBase + 0xC1
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 24, wid: child, parent: parent,
            x: 0, y: 0, width: 64, height: 128, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))

        let pixId: UInt32 = ServerConfig.default.resourceIdBase + 0xC2
        _ = session.feed(CreatePixmap(depth: 24, pid: pixId, drawable: ServerConfig.default.rootWindowId,
                                       width: 64, height: 128).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: child, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, pixId)])
        )).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.mapWindow(MapWindow(window: parent)).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.mapWindow(MapWindow(window: child)).encode(byteOrder: .lsbFirst))
        // MapWindow ran the initial paintWindowFromPixmap; clear the log so
        // we count only the pure-move repaint.
        bridge.pixmapCalls.removeAll()

        // Pan: child slides up by 4 device pixels.
        // ConfigureWindow value-mask bits: 0=x, 1=y. Each value is a 32-bit
        // slot containing a sign-extended Int16 (LE).
        _ = session.feed(Request.configureWindow(ConfigureWindow(
            window: child,
            valueMask: 0x03,
            valueList: [0, 0, 0, 0,    /* x = 0  */
                        0xFC, 0xFF, 0xFF, 0xFF /* y = -4 (sign-extended Int16) */]
        )).encode(byteOrder: .lsbFirst))

        XCTAssertGreaterThanOrEqual(
            bridge.pixmapCalls.count, 1,
            "pure-move on a bg-pixmap child must repaint the newly-exposed strip from the pixmap"
        )
        guard let call = bridge.pixmapCalls.last else { return }
        XCTAssertEqual(call.sourcePixmapId, pixId)
        // Origin tracks the moved child's new content top-left in top-level
        // device coords. At scale=1 (test default) the y-origin equals the
        // child's new y (= -4).
        XCTAssertEqual(call.originDeviceX, 0)
        XCTAssertEqual(call.originDeviceY, -4)
    }

    func testCWBackPixmapFiresBridgePaintAtMapWindow() throws {
        // End-to-end: set CWBackPixmap, map the window, verify the bridge
        // gets paintWindowFromPixmap with the right pixmap id.
        let bridge = PixmapPaintRecBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let wid: UInt32 = ServerConfig.default.resourceIdBase + 0xB0
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 24, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 64, height: 32, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))

        let pixId: UInt32 = ServerConfig.default.resourceIdBase + 0xB1
        _ = session.feed(CreatePixmap(depth: 24, pid: pixId, drawable: ServerConfig.default.rootWindowId,
                                       width: 64, height: 32).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: wid, valueMask: CW.backPixmap,
            valueList: valueList([(CW.backPixmap, pixId)])
        )).encode(byteOrder: .lsbFirst))

        XCTAssertTrue(bridge.pixmapCalls.isEmpty, "no paint until MapWindow")
        _ = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.pixmapCalls.count, 1, "MapWindow must trigger one paintWindowFromPixmap")
        let call = bridge.pixmapCalls[0]
        XCTAssertEqual(call.topLevel, wid)
        XCTAssertEqual(call.sourcePixmapId, pixId)
        XCTAssertEqual(call.originDeviceX, 0, "top-level origin is (0,0) in its own device coords")
        XCTAssertEqual(call.originDeviceY, 0)
        XCTAssertGreaterThan(call.rectCount, 0, "must paint at least one rect over the visible region")
    }
}
