import XCTest
@testable import SwiftXServerCore
import Framer

// SelectionClear emission and selection auto-revoke. Lock in the spec
// behavior (X11 protocol 4.2.1, ICCCM section 2.1) for transfer-of-
// ownership notification and the R6 dispatch.c invariants for
// destroyed-window / disconnected-client cleanup.

final class SelectionClearTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst,
                                 coordinator: ServerCoordinator = ServerCoordinator()) -> ServerSession {
        let session = ServerSession(coordinator: coordinator)
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    /// Create a top-level window via CreateWindow. Returns the chosen id.
    private func createTopLevel(_ session: ServerSession, id: UInt32) {
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: id, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 50, height: 50, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(create.encode(byteOrder: .lsbFirst))
    }

    /// Find a SelectionClear (event code 29) in raw outbound bytes.
    private func findSelectionClear(in bytes: [UInt8], byteOrder: ByteOrder) -> SelectionClearEvent? {
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            if let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder),
               case .event(let ev) = msg, ev.code == 29,
               let sc = try? SelectionClearEvent.decode(from: ev.bytes, byteOrder: byteOrder) {
                return sc
            }
            offset += 32
        }
        return nil
    }

    func testTransferOfOwnershipEmitsSelectionClearToPriorOwner() throws {
        // Same-session transfer. Window A takes PRIMARY, then window B
        // takes it. A must receive SelectionClear referencing A as owner
        // and PRIMARY as the selection.
        let session = runningSession()
        let windowA: UInt32 = ServerConfig.default.resourceIdBase + 0x10
        let windowB: UInt32 = ServerConfig.default.resourceIdBase + 0x20
        createTopLevel(session, id: windowA)
        createTopLevel(session, id: windowB)

        let primaryAtom: UInt32 = 1
        _ = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: primaryAtom, time: 100
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowB, selection: primaryAtom, time: 200
        )).encode(byteOrder: .lsbFirst))

        guard let sc = findSelectionClear(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("expected SelectionClear on ownership transfer")
            return
        }
        XCTAssertEqual(sc.owner, windowA, "SelectionClear must reference prior owner")
        XCTAssertEqual(sc.selection, primaryAtom)
        XCTAssertEqual(sc.time, 200, "SelectionClear carries the new SetSelectionOwner time")
    }

    func testReclaimingSameWindowDoesNotEmitSelectionClear() throws {
        // Window A takes PRIMARY, then "takes" it again (same window).
        // Spec: no SelectionClear when owner is unchanged.
        let session = runningSession()
        let windowA: UInt32 = ServerConfig.default.resourceIdBase + 0x10
        createTopLevel(session, id: windowA)

        let primaryAtom: UInt32 = 1
        _ = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: primaryAtom, time: 100
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: primaryAtom, time: 200
        )).encode(byteOrder: .lsbFirst))

        XCTAssertNil(findSelectionClear(in: bytes, byteOrder: .lsbFirst),
                     "re-claiming the same selection by the same window must not emit SelectionClear")
    }

    func testClearByOwnerEmitsNoSelectionClear() throws {
        // SetSelectionOwner with owner=0 means "I'm releasing." Spec
        // doesn't require a SelectionClear because the releasing client
        // is the one driving the change and already knows.
        let session = runningSession()
        let windowA: UInt32 = ServerConfig.default.resourceIdBase + 0x10
        createTopLevel(session, id: windowA)

        let primaryAtom: UInt32 = 1
        _ = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: primaryAtom, time: 100
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: 0, selection: primaryAtom, time: 200
        )).encode(byteOrder: .lsbFirst))

        XCTAssertNil(findSelectionClear(in: bytes, byteOrder: .lsbFirst),
                     "owner=0 release path must not emit SelectionClear")
    }

    func testDestroyWindowRevokesItsSelections() throws {
        // Window A owns PRIMARY. DestroyWindow A → coordinator must no
        // longer report A as owner. R6 dispatch.c:DeleteWindowFromAnySelections.
        let session = runningSession()
        let windowA: UInt32 = ServerConfig.default.resourceIdBase + 0x10
        createTopLevel(session, id: windowA)

        let primaryAtom: UInt32 = 1
        _ = session.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: primaryAtom, time: 100
        )).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(session.coordinator.selectionOwner(primaryAtom)?.window, windowA,
                       "precondition: A owns PRIMARY")

        _ = session.feed(Request.destroyWindow(DestroyWindow(window: windowA))
            .encode(byteOrder: .lsbFirst))

        XCTAssertNil(session.coordinator.selectionOwner(primaryAtom),
                     "destroyed owner must no longer hold the selection")
    }

    func testCleanupOnDisconnectRevokesSessionSelections() throws {
        // Window owned by session A holds CLIPBOARD. After session A
        // calls cleanupOnDisconnect, CLIPBOARD must be unowned. R6's
        // dispatch.c:DeleteClientFromAnySelections is the model.
        let coord = ServerCoordinator()
        let sessionA = runningSession(coordinator: coord)
        let windowA: UInt32 = ServerConfig.default.resourceIdBase + 0x30
        createTopLevel(sessionA, id: windowA)

        // CLIPBOARD isn't predefined; intern it on the shared coordinator.
        let clipboardAtom = coord.atoms.intern("CLIPBOARD")
        _ = sessionA.feed(Request.setSelectionOwner(SetSelectionOwner(
            owner: windowA, selection: clipboardAtom, time: 100
        )).encode(byteOrder: .lsbFirst))
        XCTAssertEqual(coord.selectionOwner(clipboardAtom)?.window, windowA)

        sessionA.cleanupOnDisconnect()

        XCTAssertNil(coord.selectionOwner(clipboardAtom),
                     "session disconnect must revoke all its selection ownerships")
    }
}
