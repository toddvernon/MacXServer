import XCTest
@testable import SwiftXServerCore
import Framer

// The selectionSinkWindow (id 0xFFFE_0001) is the requestor we hand out
// in our outbound SelectionRequest events when the user does Cmd-C in a
// rootless X window. ICCCM-strict selection owners (xterm is the
// canonical case — see xterm capture audit 2026-05-31) reply by:
//
//   1. ChangeWindowAttributes(window=sink, eventMask=PropertyChangeMask)
//      — so they can watch us delete the property after reading it
//   2. ChangeProperty(window=sink, property=SWIFTX_CLIP_FROM_X, ...)
//      — the actual converted data
//   3. SendEvent(dest=sink, ...) SelectionNotify — protocol completion
//
// Pre-fix, the sink had no WindowEntry so validateWindowOrRoot rejected
// every one of those with BadWindow — silently breaking xterm-source
// clipboard copy because the line ~4730 ChangeProperty-on-sink intercept
// never ran. These tests pin the post-fix behavior.
final class SelectionSinkWindowTests: XCTestCase {

    private let selectionSinkWindow: UInt32 = 0xFFFE_0001
    private let selectionSinkPropertyName = "SWIFTX_CLIP_FROM_X"

    private final class RecClipboardBridge: WindowBridge, @unchecked Sendable {
        var writtenText: [String] = []
        func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
        func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func setTopLevelTitle(id: UInt32, title: String) {}
        func writeClipboard(text: String) { writtenText.append(text) }
    }

    private func runningSession(bridge: WindowBridge? = nil) -> ServerSession {
        let session = bridge.map { ServerSession(bridge: $0) } ?? ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()
        return session
    }

    /// Step 1 of the ICCCM reply chain. Pre-fix this emitted BadWindow
    /// because the sink had no WindowEntry.
    func testChangeWindowAttributesOnSelectionSinkSucceeds() throws {
        let session = runningSession()
        let bytes = session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: selectionSinkWindow,
            valueMask: 0x800,    // CWEventMask
            valueList: [0x00, 0x08, 0x00, 0x00]   // PropertyChangeMask (LE)
        )).encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty, "must not emit XError; got bytes=\(bytes.count)")
    }

    /// Step 2. Pre-fix BadWindow → intercept missed → clipboard not pushed.
    /// Post-fix the bridge should see writeClipboard with the property data.
    func testChangePropertyOnSelectionSinkPushesClipboard() throws {
        let bridge = RecClipboardBridge()
        let session = runningSession(bridge: bridge)

        // Prime the atom table — production path interns via
        // requestSelectionConversion at Cmd-C time. Without an existing
        // intern the lookup-on-receive returns 0 and the intercept
        // skips. Real flow: the SelectionRequest event would have
        // already interned it. We replicate by interning explicitly.
        let internBytes = session.feed(Request.internAtom(InternAtom(
            onlyIfExists: false, name: Array(selectionSinkPropertyName.utf8)
        )).encode(byteOrder: .lsbFirst))
        let internReply = try ServerMessage.decodeOne(from: internBytes, byteOrder: .lsbFirst)
        guard case .reply(let r) = internReply else {
            XCTFail("expected InternAtom reply, got \(internReply)")
            return
        }
        let parsed = try InternAtomReply.decode(from: r.bytes, byteOrder: .lsbFirst)
        let propertyAtom = parsed.atom
        _ = session.outbound.drain()

        // The actual selection-conversion data. xterm-style payload:
        // STRING type, format=8, ISO-8859-1 bytes.
        let payload = "hello clipboard".data(using: .isoLatin1)!
        let stringAtom: UInt32 = 31    // X11 predefined STRING
        let bytes = session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: selectionSinkWindow,
            property: propertyAtom, type: stringAtom,
            format: .format8, data: Array(payload)
        )).encode(byteOrder: .lsbFirst))

        // We get some s2c bytes here (PropertyNotify-Deleted fires after
        // the intercept clears the prop). But no XError should appear.
        // First-byte=0 + second-byte=BadWindow(3) would be a BadWindow XError.
        let errBytes = bytes.filter { $0 == 0 }
        // Tighter check: scan for any complete 32-byte XError frame with code=3.
        // Easier: just assert writeClipboard fired with the payload — if
        // BadWindow had hit, the intercept wouldn't have run.
        XCTAssertEqual(bridge.writtenText.count, 1,
                       "ChangeProperty on selection sink must trigger writeClipboard")
        XCTAssertEqual(bridge.writtenText.first, "hello clipboard")
        _ = errBytes // silence unused warning
    }

    /// Step 3. SendEvent to the sink window must dispatch without emitting
    /// BadWindow. Per our current SendEvent impl (see OPCODE_STATUS opcode
    /// 25) the event echoes back to the issuing client — that's a separate
    /// shortcut from real per-client mask routing, but the wire result for
    /// our test is "some non-XError bytes appear." Asserting the absence
    /// of a BadWindow XError is what matters here.
    func testSendEventToSelectionSinkDoesNotEmitBadWindow() throws {
        let session = runningSession()
        var payload = [UInt8](repeating: 0, count: 32)
        payload[0] = 31   // SelectionNotify event code
        let bytes = session.feed(Request.sendEvent(SendEvent(
            propagate: false, destination: selectionSinkWindow,
            eventMask: 0, event: payload
        )).encode(byteOrder: .lsbFirst))
        // X errors are 32-byte frames where byte 0 == 0. Any other shape
        // (including event echo) is acceptable here — we're not asserting
        // routing, just absence of BadWindow.
        if bytes.count == 32 && bytes[0] == 0 {
            XCTFail("SendEvent to registered sink window must not emit XError; got code=\(bytes[1])")
        }
    }

    /// Documentation canary: the sink, like `mwmStubWindow`, IS a real
    /// WindowEntry child of root and DOES surface in QueryTree(root) —
    /// per X spec QueryTree returns all children regardless of map state.
    /// Real Xorg also exposes internal windows here. We accept the leak
    /// because the alternative (filter QueryTree replies) introduces a
    /// new asymmetry between WindowTable.children and the visible-via-
    /// spec contract. Catches an accidental "hide internal windows from
    /// QueryTree" change that would otherwise be invisible.
    func testSelectionSinkIsExposedViaQueryTreeLikeMwmStub() throws {
        let session = runningSession()
        let bytes = session.feed(Request.queryTree(QueryTree(
            window: ServerConfig.default.rootWindowId
        )).encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply(let r) = msg else {
            XCTFail("expected QueryTree reply, got \(msg)")
            return
        }
        let reply = try QueryTreeReply.decode(from: r.bytes, byteOrder: .lsbFirst)
        XCTAssertTrue(reply.children.contains(selectionSinkWindow),
                      "sink registered as root child; surfaces in QueryTree(root) per spec")
        XCTAssertTrue(reply.children.contains(0xFFFE_0002),
                      "mwmStubWindow registered the same way; sanity-check it's also here")
    }
}
