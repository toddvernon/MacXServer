import XCTest
@testable import SwiftXServerCore
import Framer

// Doubly-linked sibling-chain mechanics + the six ConfigureWindow
// stack-mode cases. Shipped 2026-05-15 to replace dict-sort-by-id
// stacking. Spec references X11 protocol "ConfigureWindow" section
// and R6 `dix/window.c:WhereDoIGoInTheStack`.

final class SiblingChainTests: XCTestCase {

    private func makeWindow(
        id: UInt32, parent: UInt32,
        x: Int16 = 0, y: Int16 = 0,
        width: UInt16 = 50, height: UInt16 = 50
    ) -> WindowEntry {
        WindowEntry(
            id: id, parent: parent, depth: 8,
            x: x, y: y, width: width, height: height,
            borderWidth: 0, windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: [],
            mapped: true
        )
    }

    /// Insert + linkAtTop, mirroring real CreateWindow dispatch order.
    private func insertChild(_ table: WindowTable, _ entry: WindowEntry) {
        table.insert(entry)
        SiblingChain.linkAtTop(entry.id, parent: entry.parent, in: table)
    }

    // MARK: - Basic chain integrity

    func testLinkAtTopOnEmptyParentSetsBothEnds() {
        let table = WindowTable()
        let parent: UInt32 = 0x100
        let child: UInt32 = 0x101
        table.insert(makeWindow(id: parent, parent: 0x28))
        table.insert(makeWindow(id: child, parent: parent))
        SiblingChain.linkAtTop(child, parent: parent, in: table)

        let p = table.get(parent)!
        XCTAssertEqual(p.firstChild, child)
        XCTAssertEqual(p.lastChild, child)
        let c = table.get(child)!
        XCTAssertNil(c.prevSib)
        XCTAssertNil(c.nextSib)
    }

    func testCreateOrderProducesNewestOnTop() {
        // Insert A then B then C. Per X spec ("newly created window is
        // placed on top of its siblings"), order should be C → B → A
        // walking firstChild → nextSib → ...
        let table = WindowTable()
        let parent: UInt32 = 0x100
        table.insert(makeWindow(id: parent, parent: 0x28))
        insertChild(table, makeWindow(id: 0xA, parent: parent))
        insertChild(table, makeWindow(id: 0xB, parent: parent))
        insertChild(table, makeWindow(id: 0xC, parent: parent))

        let order = SiblingChain.directChildrenTopFirst(of: parent, in: table)
        XCTAssertEqual(order, [0xC, 0xB, 0xA])
        let bottomUp = SiblingChain.directChildrenBottomFirst(of: parent, in: table)
        XCTAssertEqual(bottomUp, [0xA, 0xB, 0xC])
    }

    func testUnlinkFromMiddleSplicesNeighbors() {
        let table = WindowTable()
        let parent: UInt32 = 0x100
        table.insert(makeWindow(id: parent, parent: 0x28))
        insertChild(table, makeWindow(id: 0xA, parent: parent))
        insertChild(table, makeWindow(id: 0xB, parent: parent))
        insertChild(table, makeWindow(id: 0xC, parent: parent))
        // Chain is C → B → A. Remove B from the middle.
        SiblingChain.unlink(0xB, in: table)

        let order = SiblingChain.directChildrenTopFirst(of: parent, in: table)
        XCTAssertEqual(order, [0xC, 0xA])
        XCTAssertEqual(table.get(0xC)!.nextSib, 0xA)
        XCTAssertEqual(table.get(0xA)!.prevSib, 0xC)
        XCTAssertNil(table.get(0xB)!.prevSib)
        XCTAssertNil(table.get(0xB)!.nextSib)
    }

    func testUnlinkOfFirstChildPromotesNext() {
        let table = WindowTable()
        let parent: UInt32 = 0x100
        table.insert(makeWindow(id: parent, parent: 0x28))
        insertChild(table, makeWindow(id: 0xA, parent: parent))
        insertChild(table, makeWindow(id: 0xB, parent: parent))
        // Chain B → A. Remove top.
        SiblingChain.unlink(0xB, in: table)
        XCTAssertEqual(table.get(parent)!.firstChild, 0xA)
        XCTAssertEqual(table.get(parent)!.lastChild, 0xA)
        XCTAssertNil(table.get(0xA)!.prevSib)
    }

    func testLinkAboveSplicesIn() {
        let table = WindowTable()
        let parent: UInt32 = 0x100
        table.insert(makeWindow(id: parent, parent: 0x28))
        insertChild(table, makeWindow(id: 0xA, parent: parent))
        insertChild(table, makeWindow(id: 0xB, parent: parent))
        // Chain B → A. Add C, then unlink + linkAbove(C, sibling=A) to
        // place C between B and A.
        insertChild(table, makeWindow(id: 0xC, parent: parent))
        SiblingChain.unlink(0xC, in: table)
        SiblingChain.linkAbove(0xC, sibling: 0xA, in: table)
        XCTAssertEqual(
            SiblingChain.directChildrenTopFirst(of: parent, in: table),
            [0xB, 0xC, 0xA]
        )
    }

    // MARK: - ConfigureWindow stack-mode dispatch

    /// Build a session with parent + three children A, B, C
    /// (creation order ⇒ chain top-to-bottom: C, B, A).
    private func runningSession() -> (ServerSession, parent: UInt32) {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 0x10
        let cw = Request.createWindow(CreateWindow(
            depth: 8, wid: parent, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(cw.encode(byteOrder: .lsbFirst))
        for id in [parent &+ 0x10, parent &+ 0x20, parent &+ 0x30] {
            let req = Request.createWindow(CreateWindow(
                depth: 8, wid: id, parent: parent,
                x: 0, y: 0, width: 50, height: 50, borderWidth: 0,
                windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
                valueMask: 0, valueList: []
            ))
            _ = session.feed(req.encode(byteOrder: .lsbFirst))
        }
        _ = session.outbound.drain()
        return (session, parent)
    }

    /// Build a CWStackMode/CWSibling ConfigureWindow value list. mask bits
    /// per CWindow enum: x=0, y=1, w=2, h=3, bw=4, sibling=5, stackMode=6.
    private func stackConfigure(_ window: UInt32, sibling: UInt32?, stackMode: UInt8) -> Request {
        var mask: UInt16 = 1 << 6        // CWStackMode
        var values: [UInt8] = []
        if let sib = sibling {
            mask |= 1 << 5               // CWSibling
            // sibling first (lower bit), then stack-mode (higher bit)
            for shift in [0, 8, 16, 24] {
                values.append(UInt8(truncatingIfNeeded: sib >> shift))
            }
        }
        // stack-mode is in the low byte of a 4-byte word
        values.append(stackMode)
        values.append(0); values.append(0); values.append(0)
        return Request.configureWindow(ConfigureWindow(
            window: window, valueMask: mask, valueList: values
        ))
    }

    func testStackModeAboveWithSibling() {
        // C → B → A. Configure A with stackMode=Above sibling=B → expect
        // C → A → B (A goes just above B).
        let (session, parent) = runningSession()
        let a = parent &+ 0x10, b = parent &+ 0x20, _ = parent &+ 0x30
        _ = session.feed(stackConfigure(a, sibling: b, stackMode: 0)
            .encode(byteOrder: .lsbFirst))
        let order = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertEqual(order, [parent &+ 0x30, a, b])
    }

    func testStackModeBelowWithSibling() {
        // C → B → A. Configure C with stackMode=Below sibling=B → expect
        // B → C → A.
        let (session, parent) = runningSession()
        let _ = parent &+ 0x10, b = parent &+ 0x20, c = parent &+ 0x30
        _ = session.feed(stackConfigure(c, sibling: b, stackMode: 1)
            .encode(byteOrder: .lsbFirst))
        let order = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertEqual(order, [b, c, parent &+ 0x10])
    }

    func testStackModeAboveNoSiblingGoesToTop() {
        // C → B → A. Configure A with stackMode=Above (no sibling) →
        // expect A → C → B (A goes to top).
        let (session, parent) = runningSession()
        let a = parent &+ 0x10
        _ = session.feed(stackConfigure(a, sibling: nil, stackMode: 0)
            .encode(byteOrder: .lsbFirst))
        let order = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertEqual(order, [a, parent &+ 0x30, parent &+ 0x20])
    }

    func testStackModeBelowNoSiblingGoesToBottom() {
        // C → B → A. Configure C with stackMode=Below (no sibling) →
        // expect B → A → C.
        let (session, parent) = runningSession()
        let c = parent &+ 0x30
        _ = session.feed(stackConfigure(c, sibling: nil, stackMode: 1)
            .encode(byteOrder: .lsbFirst))
        let order = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertEqual(order, [parent &+ 0x20, parent &+ 0x10, c])
    }

    func testStackModeBadMatchWhenSiblingHasDifferentParent() {
        // Sibling argument must actually be a sibling of the target.
        // Otherwise BadMatch per spec.
        let (session, parent) = runningSession()
        let a = parent &+ 0x10
        let stranger: UInt32 = ServerConfig.default.resourceIdBase + 0xDEAD
        let cw = Request.createWindow(CreateWindow(
            depth: 8, wid: stranger, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 1, height: 1, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(cw.encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(stackConfigure(a, sibling: stranger, stackMode: 0)
            .encode(byteOrder: .lsbFirst))
        let msg = try? ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadMatch, got \(String(describing: msg))")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.match.rawValue)
    }

    func testConfigureNotifyCarriesRealAboveSibling() {
        // C → B → A initially. Stack A above B → A.prevSib = C. The
        // emitted ConfigureNotify should carry aboveSibling=C.
        let (session, parent) = runningSession()
        let a = parent &+ 0x10, b = parent &+ 0x20, c = parent &+ 0x30
        // Enable StructureNotifyMask on A so the ConfigureNotify is
        // delivered to it. CWEventMask bit 11 in CreateWindow / CWAttrs.
        let evMask: UInt32 = 1 << 17 // StructureNotifyMask
        var valueList: [UInt8] = []
        for shift in [0, 8, 16, 24] {
            valueList.append(UInt8(truncatingIfNeeded: evMask >> shift))
        }
        _ = session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: a, valueMask: 1 << 11, valueList: valueList
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(stackConfigure(a, sibling: b, stackMode: 0)
            .encode(byteOrder: .lsbFirst))

        // Walk outbound for ConfigureNotify (code 22) on a.
        var offset = 0
        var seenAbove: UInt32?
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            if let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: .lsbFirst),
               case .event(let ev) = msg, ev.code == 22,
               let cfg = try? ConfigureNotifyEvent.decode(from: ev.bytes, byteOrder: .lsbFirst),
               cfg.window == a {
                seenAbove = cfg.aboveSibling
                break
            }
            offset += 32
        }
        XCTAssertEqual(seenAbove, c,
                       "aboveSibling should be C (the new prevSib of A after stack-above-B)")
    }

    // MARK: - DestroyWindow / ReparentWindow chain hygiene

    func testDestroyWindowUnlinksFromChain() {
        let (session, parent) = runningSession()
        let b = parent &+ 0x20
        _ = session.feed(Request.destroyWindow(DestroyWindow(window: b))
            .encode(byteOrder: .lsbFirst))
        let order = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertEqual(order, [parent &+ 0x30, parent &+ 0x10],
                       "destroyed B must be removed from the chain, C and A splice")
    }

    func testReparentMovesChainToNewParent() {
        let (session, parent) = runningSession()
        let a = parent &+ 0x10
        // Create another top-level to reparent A onto.
        let other: UInt32 = parent &+ 0x100
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: other, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.reparentWindow(ReparentWindow(
            window: a, parent: other, x: 0, y: 0
        )).encode(byteOrder: .lsbFirst))

        // A should be gone from `parent`'s chain and on top of `other`'s.
        let parentChain = SiblingChain.directChildrenTopFirst(of: parent, in: session.windows)
        XCTAssertFalse(parentChain.contains(a))
        let otherChain = SiblingChain.directChildrenTopFirst(of: other, in: session.windows)
        XCTAssertEqual(otherChain.first, a)
    }
}
