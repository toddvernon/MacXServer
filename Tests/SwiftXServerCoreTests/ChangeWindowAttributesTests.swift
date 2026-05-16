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
}
