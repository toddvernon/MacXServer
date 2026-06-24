import XCTest
@testable import SwiftXServerCore
import Framer

// xterm scrollbar Motif-skin hack.
//
// When the hack is on for an xterm session, the server takes over rendering of
// the xterm scrollbar window: fills (the stippled thumb) and clears (vacated
// thumb) are suppressed, and a Motif slider is painted over the reconstructed
// thumb extent. These tests drive the wire ops and assert the slider rect the
// bridge is asked to paint — exercising the occupancy reconstruction across
// xterm's incremental fill/clear (the subtle bit).

final class XtermScrollbarSkinTests: XCTestCase {

    private static let wmClassAtom: UInt32 = 67
    private let root = ServerConfig.default.rootWindowId
    private let xtermWin: UInt32 = ServerConfig.default.resourceIdBase + 1
    private let sbWin: UInt32    = ServerConfig.default.resourceIdBase + 2
    private let gc: UInt32       = ServerConfig.default.resourceIdBase + 3

    /// Build a running xterm session (WM_CLASS = XTerm) with a left-edge
    /// scrollbar child and the Motif-skin hack enabled. Returns the bridge.
    private func skinnedXtermSession() -> (ServerSession, MockWindowBridge) {
        PointerConfig.install(PointerConfig(xtermScrollbarMotifSkin: true))
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        // xterm top-level (parent = root) and its scrollbar child.
        create(session, wid: xtermWin, parent: root, x: 0, y: 0, w: 300, h: 200)
        _ = session.feed(MapWindow(window: xtermWin).encode(byteOrder: .lsbFirst))
        // Scrollbar selects Button{Press,Release}Mask like the real Athena
        // widget, so mouseTarget resolves clicks to it.
        create(session, wid: sbWin, parent: xtermWin, x: 0, y: 0, w: 14, h: 200,
               eventMask: (1 << 2) | (1 << 3))
        _ = session.feed(MapWindow(window: sbWin).encode(byteOrder: .lsbFirst))

        // Identify the session as xterm.
        let wmClass: [UInt8] = Array("xterm".utf8) + [0] + Array("XTerm".utf8) + [0]
        _ = session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: xtermWin, property: Self.wmClassAtom,
            type: 31, format: .format8, data: wmClass
        )).encode(byteOrder: .lsbFirst))

        // A GC for the fills.
        _ = session.feed(CreateGC(cid: gc, drawable: sbWin,
                                  valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return (session, bridge)
    }

    override func tearDown() {
        PointerConfig.install(.default)
        super.tearDown()
    }

    private func create(_ session: ServerSession, wid: UInt32, parent: UInt32,
                        x: Int16, y: Int16, w: UInt16, h: UInt16, eventMask: UInt32 = 0) {
        let mask: UInt32 = eventMask == 0 ? 0 : CW.eventMask
        let list: [UInt8] = eventMask == 0 ? [] : [
            UInt8(eventMask & 0xFF), UInt8((eventMask >> 8) & 0xFF),
            UInt8((eventMask >> 16) & 0xFF), UInt8((eventMask >> 24) & 0xFF)]
        _ = session.feed(CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: mask, valueList: list
        ).encode(byteOrder: .lsbFirst))
    }

    private func fill(_ session: ServerSession, y: Int16, h: UInt16) {
        _ = session.feed(PolyFillRectangle(
            drawable: sbWin, gc: gc,
            rectangles: [Rectangle(x: 1, y: y, width: 12, height: h)]
        ).encode(byteOrder: .lsbFirst))
    }

    private func clear(_ session: ServerSession, y: Int16, h: UInt16) {
        _ = session.feed(ClearArea(
            exposures: false, window: sbWin, x: 1, y: y, width: 12, height: h
        ).encode(byteOrder: .lsbFirst))
    }

    func testThumbFillReportsFullWindowAndExtent() {
        let (session, bridge) = skinnedXtermSession()
        fill(session, y: 0, h: 100)

        // The renderer gets the whole scrollbar window plus the window-local
        // thumb extent (it owns the arrow/channel/rescale layout).
        XCTAssertEqual(bridge.lastScrollbarWindowRect,
                       Rectangle(x: 0, y: 0, width: 14, height: 200))
        XCTAssertEqual(bridge.lastScrollbarThumbTop, 0)
        XCTAssertEqual(bridge.lastScrollbarThumbHeight, 100)
    }

    func testScrollReconstructsMovedThumbFromFillThenClear() {
        let (session, bridge) = skinnedXtermSession()
        // Initial thumb [0,100).
        fill(session, y: 0, h: 100)
        // Scroll down: xterm fills the new bottom strip then clears the old top.
        fill(session, y: 100, h: 50)   // now [0,150)
        clear(session, y: 0, h: 50)    // now [50,150)

        XCTAssertEqual(bridge.lastScrollbarThumbTop, 50)
        XCTAssertEqual(bridge.lastScrollbarThumbHeight, 100)
    }

    func testClearingEntireThumbLeavesNoSlider() {
        let (session, bridge) = skinnedXtermSession()
        fill(session, y: 20, h: 80)
        clear(session, y: 0, h: 200)   // wipe the whole trough

        XCTAssertEqual(bridge.lastScrollbarThumbHeight, 0)
    }

    // MARK: - Arrow steppers (page-relative 15%)

    func testUpArrowStepsThumbUpByPageFraction() {
        let (session, _) = skinnedXtermSession()
        fill(session, y: 40, h: 40)   // thumbTop=40, thumbHeight=40
        // step = max(1, 40 * 0.15) = 6 → targetTop = 40 - 6 = 34.
        // Click in the top arrow region (localY < arrowSize=14).
        XCTAssertEqual(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 4), 34)
    }

    func testDownArrowStepsThumbDownByPageFraction() {
        let (session, _) = skinnedXtermSession()
        fill(session, y: 40, h: 40)
        // targetTop = 40 + 6 = 46. Click in the bottom arrow region (y >= 186).
        XCTAssertEqual(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 195), 46)
    }

    func testTroughClickIsNotAnArrowStep() {
        let (session, _) = skinnedXtermSession()
        fill(session, y: 40, h: 40)
        // Mid-trough (between the arrows) → nil, keeps the grab-to-position.
        XCTAssertNil(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 100))
    }

    func testUpArrowNearTopSnapsToTerminal() {
        let (session, _) = skinnedXtermSession()
        fill(session, y: 2, h: 40)    // thumbTop=2; step=6 → overshoots top
        // Snaps to the absolute top edge (y=1, inside the trough) so the
        // remainder is traversed instead of stopping short.
        XCTAssertEqual(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 4), 1)
    }

    func testDownArrowNearBottomSnapsToTerminal() {
        let (session, _) = skinnedXtermSession()
        // thumbTop=150, thumbHeight=40 → maxTop=160; step=6 → 156 < 160, full
        // step. Push closer: thumbTop=156 → 156+6=162 >= 160 → snap to bottom.
        fill(session, y: 156, h: 40)
        // Bottom edge click (h-2 = 198) forces xterm fully to the terminal.
        XCTAssertEqual(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 195), 198)
    }

    func testArrowStepNoThumbReturnsNil() {
        let (session, _) = skinnedXtermSession()
        // No fill → no thumb to step from.
        XCTAssertNil(session.motifScrollbarArrowStepTarget(topLevel: xtermWin, x: 5, y: 4))
    }

    func testHackOffLeavesNormalRenderingUntouched() {
        // Same window shape, hack disabled → no Motif scrollbar paint at all.
        PointerConfig.install(.default)
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        create(session, wid: xtermWin, parent: root, x: 0, y: 0, w: 300, h: 200)
        _ = session.feed(MapWindow(window: xtermWin).encode(byteOrder: .lsbFirst))
        create(session, wid: sbWin, parent: xtermWin, x: 0, y: 0, w: 14, h: 200)
        _ = session.feed(MapWindow(window: sbWin).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateGC(cid: gc, drawable: sbWin,
                                  valueMask: 0, valueList: []).encode(byteOrder: .lsbFirst))
        fill(session, y: 0, h: 100)

        XCTAssertNil(bridge.lastScrollbarWindowRect)
        XCTAssertNil(bridge.lastScrollbarThumbHeight)
    }
}
