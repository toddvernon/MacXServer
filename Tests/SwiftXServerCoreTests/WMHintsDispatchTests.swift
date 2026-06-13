import XCTest
@testable import SwiftXServerCore
import Framer

// Integration tests: ChangeProperty(WM_NORMAL_HINTS / _MOTIF_WM_HINTS) on
// a top-level X window reaches the bridge with decoded hint values.
// handleCloseRequest gates on WM_PROTOCOLS for the polite ICCCM
// WM_DELETE_WINDOW message.
final class WMHintsDispatchTests: XCTestCase {

    /// Bridge that records every applySizeHints / applyMotifDecorations /
    /// destroyTopLevel call. All other methods no-op.
    private final class RecordingBridge: WindowBridge, @unchecked Sendable {
        var sizeHints: [(id: UInt32, hints: WMSizeHints?)] = []
        var motifHints: [(id: UInt32, hints: MotifWMHints?)] = []
        var destroyCalls: [UInt32] = []
        func applySizeHints(id: UInt32, hints: WMSizeHints?) {
            sizeHints.append((id, hints))
        }
        func applyMotifDecorations(id: UInt32, hints: MotifWMHints?) {
            motifHints.append((id, hints))
        }
        func destroyTopLevel(id: UInt32, byteOrder: ByteOrder,
                             sequence: UInt16, outbound: OutboundQueue) {
            destroyCalls.append(id)
        }
        // No-ops for everything else.
        func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
        func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func setTopLevelTitle(id: UInt32, title: String) {}
    }

    private func runningSession(bridge: WindowBridge) -> ServerSession {
        let s = ServerSession(bridge: bridge)
        _ = s.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = s.outbound.drain()
        return s
    }

    private func createTopLevel(_ session: ServerSession) -> UInt32 {
        let wid: UInt32 = ServerConfig.default.resourceIdBase + UInt32.random(in: 0x100...0xFFF)
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return wid
    }

    /// Encode 18 little-endian CARD32s, only the slots the caller cares
    /// about populated, everything else zero. Matches ICCCM WM_SIZE_HINTS
    /// layout.
    private func wmSizeHintsBytes(flags: WMSizeHints.Flags,
                                  minW: Int32 = 0, minH: Int32 = 0,
                                  maxW: Int32 = 0, maxH: Int32 = 0) -> [UInt8] {
        var v: [UInt32] = Array(repeating: 0, count: 18)
        v[0] = flags.rawValue
        v[5] = UInt32(bitPattern: minW); v[6] = UInt32(bitPattern: minH)
        v[7] = UInt32(bitPattern: maxW); v[8] = UInt32(bitPattern: maxH)
        var bytes: [UInt8] = []
        for x in v {
            bytes.append(UInt8(x & 0xFF))
            bytes.append(UInt8((x >> 8) & 0xFF))
            bytes.append(UInt8((x >> 16) & 0xFF))
            bytes.append(UInt8((x >> 24) & 0xFF))
        }
        return bytes
    }

    func testChangePropertyWMNormalHintsReachesBridge() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let wid = createTopLevel(s)
        let bytes = wmSizeHintsBytes(flags: [.pMinSize, .pMaxSize],
                                     minW: 200, minH: 100,
                                     maxW: 800, maxH: 600)
        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid,
            property: 40,           // WM_NORMAL_HINTS (predefined)
            type: 41,               // WM_SIZE_HINTS (predefined)
            format: .format32,
            data: bytes
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.sizeHints.count, 1, "exactly one applySizeHints fired")
        let call = bridge.sizeHints[0]
        XCTAssertEqual(call.id, wid)
        XCTAssertEqual(call.hints?.minWidth, 200)
        XCTAssertEqual(call.hints?.minHeight, 100)
        XCTAssertEqual(call.hints?.maxWidth, 800)
        XCTAssertEqual(call.hints?.maxHeight, 600)
    }

    func testChangePropertyMotifWMHintsReachesBridge() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let wid = createTopLevel(s)

        // _MOTIF_WM_HINTS isn't predefined; intern it.
        let internBytes = s.feed(Request.internAtom(InternAtom(
            onlyIfExists: false, name: Array("_MOTIF_WM_HINTS".utf8)
        )).encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: internBytes, byteOrder: .lsbFirst)
        guard case .reply(let r) = msg else {
            XCTFail("expected InternAtom reply"); return
        }
        let atom = try InternAtomReply.decode(from: r.bytes, byteOrder: .lsbFirst).atom

        // flags=DECORATIONS, decorations=BORDER|TITLE
        var v: [UInt32] = [
            MotifWMHints.Flags.decorations.rawValue,
            0,
            MotifWMHints.Decorations([.border, .title]).rawValue,
            0, 0
        ]
        var bytes: [UInt8] = []
        for x in v {
            bytes.append(UInt8(x & 0xFF))
            bytes.append(UInt8((x >> 8) & 0xFF))
            bytes.append(UInt8((x >> 16) & 0xFF))
            bytes.append(UInt8((x >> 24) & 0xFF))
        }
        _ = v   // silence unused-write warning

        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid,
            property: atom, type: atom, format: .format32, data: bytes
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.motifHints.count, 1)
        let h = bridge.motifHints[0].hints!
        XCTAssertTrue(h.decorations.contains(.border))
        XCTAssertTrue(h.decorations.contains(.title))
        XCTAssertTrue(h.hasExplicitDecorations)
    }

    // MARK: - WM_DELETE_WINDOW gating

    /// Helper: set WM_PROTOCOLS = [WM_DELETE_WINDOW] on a window.
    private func claimDeleteWindow(_ s: ServerSession, wid: UInt32) throws {
        func internAtom(_ name: String) throws -> UInt32 {
            let resp = s.feed(Request.internAtom(InternAtom(
                onlyIfExists: false, name: Array(name.utf8)
            )).encode(byteOrder: .lsbFirst))
            let msg = try ServerMessage.decodeOne(from: resp, byteOrder: .lsbFirst)
            guard case .reply(let r) = msg else { throw NSError(domain: "i", code: 0) }
            return try InternAtomReply.decode(from: r.bytes, byteOrder: .lsbFirst).atom
        }
        let wmProtocols = try internAtom("WM_PROTOCOLS")
        let wmDelete = try internAtom("WM_DELETE_WINDOW")
        var bytes: [UInt8] = []
        for shift in [0, 8, 16, 24] { bytes.append(UInt8((wmDelete >> shift) & 0xFF)) }
        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: wmProtocols, type: 4 /* ATOM */,
            format: .format32, data: bytes
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
    }

    func testCloseRequestPoliteWhenClientClaimsWMDeleteWindow() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let wid = createTopLevel(s)
        try claimDeleteWindow(s, wid: wid)

        s.handleCloseRequest(topLevel: wid)
        let out = s.outbound.drain()

        // Polite path: a ClientMessage event on the wire, no destroy call.
        XCTAssertFalse(out.isEmpty, "polite close must emit a ClientMessage")
        let msg = try ServerMessage.decodeOne(from: out, byteOrder: .lsbFirst)
        guard case .event(let e) = msg, e.code == 33 /* ClientMessage */ else {
            XCTFail("expected ClientMessage event (code 33), got \(msg)"); return
        }
        XCTAssertTrue(bridge.destroyCalls.isEmpty,
                      "polite path must NOT call destroyTopLevel")
    }

    func testCloseRequestForceWhenClientDoesNotClaimWMDeleteWindow() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let wid = createTopLevel(s)
        // No WM_PROTOCOLS at all — definitely doesn't claim WM_DELETE_WINDOW.

        s.handleCloseRequest(topLevel: wid)
        let out = s.outbound.drain()

        // Force path: no ClientMessage, destroyTopLevel called.
        let hasClientMessage: Bool
        if !out.isEmpty {
            let msg = try? ServerMessage.decodeOne(from: out, byteOrder: .lsbFirst)
            if case .event(let e) = msg, e.code == 33 {
                hasClientMessage = true
            } else {
                hasClientMessage = false
            }
        } else {
            hasClientMessage = false
        }
        XCTAssertFalse(hasClientMessage, "force path must NOT emit ClientMessage")
        XCTAssertEqual(bridge.destroyCalls, [wid],
                       "force path must call destroyTopLevel on the doomed window")
    }

    func testCloseRequestForceWhenWMProtocolsExistsButLacksDeleteWindow() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let wid = createTopLevel(s)

        // Set WM_PROTOCOLS but populate it with some OTHER atom (WM_TAKE_FOCUS).
        let wmProtocolsResp = s.feed(Request.internAtom(InternAtom(
            onlyIfExists: false, name: Array("WM_PROTOCOLS".utf8)
        )).encode(byteOrder: .lsbFirst))
        let wmTakeFocusResp = s.feed(Request.internAtom(InternAtom(
            onlyIfExists: false, name: Array("WM_TAKE_FOCUS".utf8)
        )).encode(byteOrder: .lsbFirst))
        guard case .reply(let r1) = try ServerMessage.decodeOne(from: wmProtocolsResp, byteOrder: .lsbFirst),
              case .reply(let r2) = try ServerMessage.decodeOne(from: wmTakeFocusResp, byteOrder: .lsbFirst)
        else { XCTFail("intern reply expected"); return }
        let wmProtocols = try InternAtomReply.decode(from: r1.bytes, byteOrder: .lsbFirst).atom
        let wmTakeFocus = try InternAtomReply.decode(from: r2.bytes, byteOrder: .lsbFirst).atom

        var bytes: [UInt8] = []
        for shift in [0, 8, 16, 24] { bytes.append(UInt8((wmTakeFocus >> shift) & 0xFF)) }
        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: wmProtocols, type: 4,
            format: .format32, data: bytes
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()

        s.handleCloseRequest(topLevel: wid)
        XCTAssertEqual(bridge.destroyCalls, [wid],
                       "WM_PROTOCOLS without WM_DELETE_WINDOW = still force-close")
    }
}
