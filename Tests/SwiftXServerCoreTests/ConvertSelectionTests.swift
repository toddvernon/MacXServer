import XCTest
@testable import SwiftXServerCore
import Framer

// Lock in the three ConvertSelection routing branches:
//   1. Owner is a real client window → forward as SelectionRequest event.
//   2. Owner is a server-internal stub (id ≥ 0xFFFE_0000) → short-circuit
//      with SelectionNotify(property=r.property) and write empty bytes to
//      the requestor's property. The 2026-05-10 CDE customization daemon
//      impersonation depends on this path.
//   3. No owner → SelectionNotify(property=None) per X11 spec.
//
// The `time` field of the SelectionNotify MUST round-trip the original
// ConvertSelection's `time` verbatim — Xt's MATCH_SELECT macro silently
// drops the event when times don't match. Verified by the .selectionNotify
// time assertions.

final class ConvertSelectionTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    // Pull SelectionNotify (event code 31) or SelectionRequest (30) from
    // the outbound byte stream. Returns the first event of either type.
    private enum SelEvent { case notify(DecodedEvent), request(DecodedEvent) }
    private func findSelectionEvent(in bytes: [UInt8], byteOrder: ByteOrder) -> SelEvent? {
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder) else {
                offset += 32; continue
            }
            if case .event(let ev) = msg {
                if ev.code == 30, let decoded = try? DecodedEvent.decode(from: ev, byteOrder: byteOrder) {
                    return .request(decoded)
                }
                if ev.code == 31, let decoded = try? DecodedEvent.decode(from: ev, byteOrder: byteOrder) {
                    return .notify(decoded)
                }
            }
            offset += msg.bytes.count
        }
        return nil
    }

    func testConvertSelectionWithRealClientOwnerForwardsSelectionRequest() throws {
        let session = runningSession()
        let primaryAtom: UInt32 = 1   // PRIMARY (predefined)
        let ownerWindow: UInt32 = 0x4400099
        session.coordinator.setSelectionOwner(primaryAtom, window: ownerWindow, time: 42)

        let req = Request.convertSelection(ConvertSelection(
            requestor: 0x4400_0AAA, selection: primaryAtom,
            target: 31, property: 32, time: 999
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        guard let result = findSelectionEvent(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("no SelectionRequest/Notify on outbound")
            return
        }
        guard case .request(let decoded) = result,
              case .selectionRequest(let sr) = decoded else {
            XCTFail("expected SelectionRequest, got \(result)")
            return
        }
        XCTAssertEqual(sr.owner, ownerWindow)
        XCTAssertEqual(sr.requestor, 0x4400_0AAA)
        XCTAssertEqual(sr.selection, primaryAtom)
        XCTAssertEqual(sr.target, 31)
        XCTAssertEqual(sr.property, 32)
        XCTAssertEqual(sr.time, 999, "time must round-trip verbatim")
    }

    func testConvertSelectionWithStubOwnerShortCircuitsToSelectionNotify() throws {
        let session = runningSession()
        let customizeAtom = session.atoms.intern("Customize Data:0")
        let stubWindow: UInt32 = 0xFFFE_0003   // CDE daemon stub
        session.coordinator.setSelectionOwner(customizeAtom, window: stubWindow, time: 0)

        let req = Request.convertSelection(ConvertSelection(
            requestor: 0x4400_0BBB, selection: customizeAtom,
            target: 31, property: 33, time: 1234
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        guard case .notify(let decoded) = findSelectionEvent(in: bytes, byteOrder: .lsbFirst),
              case .selectionNotify(let sn) = decoded else {
            XCTFail("expected SelectionNotify for stub-daemon path")
            return
        }
        XCTAssertEqual(sn.property, 33, "stub path writes empty bytes and reports success")
        XCTAssertEqual(sn.time, 1234, "time MUST round-trip verbatim (Xt MATCH_SELECT)")
        XCTAssertEqual(sn.requestor, 0x4400_0BBB)
        XCTAssertEqual(sn.selection, customizeAtom)
        XCTAssertEqual(sn.target, 31)
    }

    func testSelectionMediatorDispatchesCorrectly() {
        // White-box: poke the mediator directly to verify the three-way
        // dispatch (stub / real client / no owner). The ServerSession
        // ConvertSelection case is a thin shell over this; the routing
        // policy lives here now.
        let session = runningSession()
        let primary: UInt32 = 1
        let customize = session.atoms.intern("Customize Data:0")
        // Pre-installed by the mediator at init time → stub owner.
        let stubResult = session.selectionMediator.convertSelection(ConvertSelection(
            requestor: 0xABC, selection: customize, target: 31, property: 5, time: 1
        ))
        if case .stubOwnerReplyEmpty(let win) = stubResult {
            XCTAssertEqual(win, 0xFFFE_0003, "CDE customization daemon stub")
        } else {
            XCTFail("expected stubOwnerReplyEmpty, got \(stubResult)")
        }

        // Register a real-client owner and check forwarding path.
        session.coordinator.setSelectionOwner(primary, window: 0x4400_0010, time: 7)
        let fwdResult = session.selectionMediator.convertSelection(ConvertSelection(
            requestor: 0xABC, selection: primary, target: 31, property: 5, time: 7
        ))
        if case .forwardToRealOwner(let win) = fwdResult {
            XCTAssertEqual(win, 0x4400_0010)
        } else {
            XCTFail("expected forwardToRealOwner, got \(fwdResult)")
        }

        // Unowned selection.
        let unowned = session.atoms.intern("UNOWNED_SEL_TEST")
        let noOwnerResult = session.selectionMediator.convertSelection(ConvertSelection(
            requestor: 0xABC, selection: unowned, target: 31, property: 5, time: 7
        ))
        if case .replyNoOwner = noOwnerResult {} else {
            XCTFail("expected replyNoOwner, got \(noOwnerResult)")
        }
    }

    func testConvertSelectionWithNoOwnerEmitsPropertyNone() throws {
        let session = runningSession()
        let unownedAtom = session.atoms.intern("UNOWNED_FOR_TEST")

        let req = Request.convertSelection(ConvertSelection(
            requestor: 0x4400_0CCC, selection: unownedAtom,
            target: 31, property: 34, time: 5678
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        guard case .notify(let decoded) = findSelectionEvent(in: bytes, byteOrder: .lsbFirst),
              case .selectionNotify(let sn) = decoded else {
            XCTFail("expected SelectionNotify(property=None) for unowned selection")
            return
        }
        XCTAssertEqual(sn.property, 0, "unowned selection → property=None per spec")
        XCTAssertEqual(sn.time, 5678, "time MUST round-trip verbatim")
    }
}
