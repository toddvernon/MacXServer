import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// EnterNotify / LeaveNotify chain emission. The X11 spec prescribes detail
// values (Ancestor / Inferior / Nonlinear / Virtual / NonlinearVirtual)
// based on how the from-window and to-window relate in the tree. These
// tests pin the chain shape for the common cases — siblings, ancestor /
// descendant transitions, view-enter, view-exit.

final class CrossingEventTests: XCTestCase {

    /// Top-level + two non-overlapping sibling descendants. Mask everything
    /// for crossing events so we can observe the emission shape.
    private func makeTreeWithTwoSiblings() -> ServerSession {
        let session = ServerSession(bridge: MockWindowBridge())
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())

        // Top-level 0xA0001 200×200 at root, with crossing masks.
        let topLevelMasks: UInt32 = enterMask | leaveMask
        sendCreateWindow(session, wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
                         x: 0, y: 0, w: 200, h: 200, eventMask: topLevelMasks)
        _ = session.feed(MapWindow(window: 0xA0001).encode(byteOrder: .lsbFirst))

        // Descendants A at (10,10,50×50) and B at (100,10,50×50), siblings.
        sendCreateWindow(session, wid: 0xA0002, parent: 0xA0001,
                         x: 10, y: 10, w: 50, h: 50, eventMask: topLevelMasks)
        _ = session.feed(MapWindow(window: 0xA0002).encode(byteOrder: .lsbFirst))
        sendCreateWindow(session, wid: 0xA0003, parent: 0xA0001,
                         x: 100, y: 10, w: 50, h: 50, eventMask: topLevelMasks)
        _ = session.feed(MapWindow(window: 0xA0003).encode(byteOrder: .lsbFirst))

        _ = session.outbound.drain()  // discard map-sequence chatter
        return session
    }

    func testPointerEnteringFromOutsideEmitsNonlinearChain() throws {
        let session = makeTreeWithTwoSiblings()
        // Pointer enters the NSView at (15,15) — inside descendant A.
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)
        let events = try decodeCrossingEvents(session.outbound.drain())
        // Spec: Enter top-level (NonlinearVirtual), Enter A (Nonlinear).
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].window, 0xA0001)
        XCTAssertEqual(events[0].detail, .nonlinearVirtual)
        XCTAssertEqual(events[0].code, 7)        // EnterNotify
        XCTAssertEqual(events[1].window, 0xA0002)
        XCTAssertEqual(events[1].detail, .nonlinear)
        XCTAssertEqual(events[1].code, 7)
    }

    func testPointerCrossingSiblingsEmitsNonlinearLeaveAndEnter() throws {
        let session = makeTreeWithTwoSiblings()
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)
        _ = session.outbound.drain()

        // Pointer moves from A to B (siblings; LCA = top-level).
        session.handlePointerMoved(topLevel: 0xA0001, x: 110, y: 15)

        let events = try decodeCrossingEvents(session.outbound.drain())
        // Spec: Leave A (Nonlinear), Enter B (Nonlinear). LCA itself
        // (top-level) does NOT get a virtual event in this case.
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].window, 0xA0002)
        XCTAssertEqual(events[0].detail, .nonlinear)
        XCTAssertEqual(events[0].code, 8)        // LeaveNotify
        XCTAssertEqual(events[1].window, 0xA0003)
        XCTAssertEqual(events[1].detail, .nonlinear)
        XCTAssertEqual(events[1].code, 7)
    }

    func testPointerLeavingDescendantToAncestorEmitsAncestorAndInferior() throws {
        let session = makeTreeWithTwoSiblings()
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)
        _ = session.outbound.drain()

        // Pointer moves from A out into top-level area (still inside top-level).
        session.handlePointerMoved(topLevel: 0xA0001, x: 75, y: 75)

        let events = try decodeCrossingEvents(session.outbound.drain())
        // Spec: Leave A (Ancestor — the pointer left A into A's ancestor),
        // Enter top-level (Inferior — the pointer came from an inferior of top-level).
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].window, 0xA0002)
        XCTAssertEqual(events[0].detail, .ancestor)
        XCTAssertEqual(events[0].code, 8)
        XCTAssertEqual(events[1].window, 0xA0001)
        XCTAssertEqual(events[1].detail, .inferior)
        XCTAssertEqual(events[1].code, 7)
    }

    func testPointerEnteringDescendantFromAncestorEmitsInferiorAndAncestor() throws {
        let session = makeTreeWithTwoSiblings()
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 75, y: 75)  // bare top-level
        _ = session.outbound.drain()

        // Pointer descends into A.
        session.handlePointerMoved(topLevel: 0xA0001, x: 15, y: 15)

        let events = try decodeCrossingEvents(session.outbound.drain())
        // Spec: Leave top-level (Inferior — left INTO an inferior),
        // Enter A (Ancestor — came from an ancestor).
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].window, 0xA0001)
        XCTAssertEqual(events[0].detail, .inferior)
        XCTAssertEqual(events[0].code, 8)
        XCTAssertEqual(events[1].window, 0xA0002)
        XCTAssertEqual(events[1].detail, .ancestor)
        XCTAssertEqual(events[1].code, 7)
    }

    func testPointerExitingViewEmitsLeaveChain() throws {
        let session = makeTreeWithTwoSiblings()
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)
        _ = session.outbound.drain()

        session.handlePointerExitedView(topLevel: 0xA0001, x: 15, y: 15)

        let events = try decodeCrossingEvents(session.outbound.drain())
        // Spec: Leave A (Nonlinear), Leave top-level (NonlinearVirtual).
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].window, 0xA0002)
        XCTAssertEqual(events[0].detail, .nonlinear)
        XCTAssertEqual(events[0].code, 8)
        XCTAssertEqual(events[1].window, 0xA0001)
        XCTAssertEqual(events[1].detail, .nonlinearVirtual)
        XCTAssertEqual(events[1].code, 8)
    }

    func testPointerMoveWithinSameWindowEmitsNothing() throws {
        let session = makeTreeWithTwoSiblings()
        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)
        _ = session.outbound.drain()

        // Pointer moves within A.
        session.handlePointerMoved(topLevel: 0xA0001, x: 30, y: 30)

        let events = try decodeCrossingEvents(session.outbound.drain())
        XCTAssertTrue(events.isEmpty, "no crossing event expected when window doesn't change")
    }

    func testWindowWithoutMaskGetsNoEvent() throws {
        // Top-level subscribes; descendant doesn't. Pointer enters descendant.
        // We should see the chain skip the descendant and only emit on the top-level.
        let session = ServerSession(bridge: MockWindowBridge())
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        sendCreateWindow(session, wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
                         x: 0, y: 0, w: 200, h: 200, eventMask: enterMask | leaveMask)
        _ = session.feed(MapWindow(window: 0xA0001).encode(byteOrder: .lsbFirst))
        sendCreateWindow(session, wid: 0xA0002, parent: 0xA0001,
                         x: 10, y: 10, w: 50, h: 50, eventMask: 0)   // no crossing mask
        _ = session.feed(MapWindow(window: 0xA0002).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        session.handlePointerEnteredView(topLevel: 0xA0001, x: 15, y: 15)

        let events = try decodeCrossingEvents(session.outbound.drain())
        // Only top-level (subscribed) — descendant is skipped.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].window, 0xA0001)
        XCTAssertEqual(events[0].detail, .nonlinearVirtual)
    }

    // MARK: - Helpers

    private let enterMask: UInt32 = 1 << 4
    private let leaveMask: UInt32 = 1 << 5

    private struct CrossingObserved {
        let code: UInt8
        let window: UInt32
        let detail: CrossingDetail
    }

    private func decodeCrossingEvents(_ bytes: [UInt8]) throws -> [CrossingObserved] {
        var out: [CrossingObserved] = []
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + 32, bytes.count)])
            guard chunk.count == 32 else { break }
            let code = chunk[0]
            if code == 7 || code == 8 {
                let event = try CrossingEvent.decode(from: chunk, byteOrder: .lsbFirst)
                out.append(CrossingObserved(code: code, window: event.event, detail: event.detail))
            }
            offset += 32
        }
        return out
    }

    private func sendCreateWindow(
        _ session: ServerSession, wid: UInt32, parent: UInt32,
        x: Int16, y: Int16, w: UInt16, h: UInt16, eventMask: UInt32
    ) {
        let valueMask: UInt32 = eventMask == 0 ? 0 : CW.eventMask
        let valueList: [UInt8] = eventMask == 0 ? [] : [
            UInt8(eventMask & 0xFF),
            UInt8((eventMask >> 8) & 0xFF),
            UInt8((eventMask >> 16) & 0xFF),
            UInt8((eventMask >> 24) & 0xFF)
        ]
        let req = CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput,
            visual: 0, valueMask: valueMask, valueList: valueList
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }
}
