import XCTest
@testable import SwiftXServerCore
import Framer

// ChangeProperty(WM_TRANSIENT_FOR) on a top-level reaches the bridge with
// the parent window id decoded. Pins both the dispatch path (intercept
// fires, byte-order correct, both lsb and msb tested) and the detach
// case (property value 0 → nil parent).
//
// Sun-mwm uses WM_TRANSIENT_FOR to keep Motif XmDialogShell dialogs
// visually above their parent main window regardless of focus — match
// that on Mac via NSWindow.addChildWindow, plumbed through the bridge
// in CocoaWindowBridge.applyTransientFor.
final class WMTransientForTests: XCTestCase {

    private final class RecordingBridge: WindowBridge, @unchecked Sendable {
        var calls: [(child: UInt32, parent: UInt32?)] = []
        func applyTransientFor(child: UInt32, parent: UInt32?) {
            calls.append((child, parent))
        }
        // No-ops for everything else.
        func registerTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32) {}
        func mapTopLevel(id: UInt32, geometry: TopLevelGeometry, eventMask: UInt32, topLevelExposeRects: [BoxRec], descendants: [DescendantSnapshot], overrideRedirect: Bool, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func mapDescendant(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func unmapTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func destroyTopLevel(id: UInt32, byteOrder: ByteOrder, sequence: UInt16, outbound: OutboundQueue) {}
        func setTopLevelTitle(id: UInt32, title: String) {}
    }

    private func runningSession(bridge: WindowBridge, byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let s = ServerSession(bridge: bridge)
        _ = s.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = s.outbound.drain()
        return s
    }

    private func createTopLevel(_ session: ServerSession, wid: UInt32, byteOrder: ByteOrder = .lsbFirst) {
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: byteOrder))
        _ = session.outbound.drain()
    }

    /// 4-byte parent window id, packed little-endian.
    private func encodeParent(_ parent: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        if byteOrder == .lsbFirst {
            return [
                UInt8(parent & 0xFF),
                UInt8((parent >> 8) & 0xFF),
                UInt8((parent >> 16) & 0xFF),
                UInt8((parent >> 24) & 0xFF)
            ]
        } else {
            return [
                UInt8((parent >> 24) & 0xFF),
                UInt8((parent >> 16) & 0xFF),
                UInt8((parent >> 8) & 0xFF),
                UInt8(parent & 0xFF)
            ]
        }
    }

    func testChangePropertyWMTransientForReachesBridgeLSB() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 0x100
        let child: UInt32  = ServerConfig.default.resourceIdBase + 0x200
        createTopLevel(s, wid: parent)
        createTopLevel(s, wid: child)

        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: child,
            property: 68,           // WM_TRANSIENT_FOR (predefined atom)
            type: 33,               // WINDOW (predefined atom)
            format: .format32,
            data: encodeParent(parent, byteOrder: .lsbFirst)
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.calls.count, 1)
        XCTAssertEqual(bridge.calls[0].child, child)
        XCTAssertEqual(bridge.calls[0].parent, parent)
    }

    func testChangePropertyWMTransientForReachesBridgeMSB() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge, byteOrder: .msbFirst)
        let parent: UInt32 = ServerConfig.default.resourceIdBase + 0x100
        let child: UInt32  = ServerConfig.default.resourceIdBase + 0x200
        createTopLevel(s, wid: parent, byteOrder: .msbFirst)
        createTopLevel(s, wid: child, byteOrder: .msbFirst)

        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: child,
            property: 68, type: 33, format: .format32,
            data: encodeParent(parent, byteOrder: .msbFirst)
        )).encode(byteOrder: .msbFirst))

        XCTAssertEqual(bridge.calls.count, 1)
        XCTAssertEqual(bridge.calls[0].parent, parent,
                       "msbFirst client: parent id must decode correctly with the byte order swap")
    }

    func testParentValueZeroDetaches() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let child: UInt32 = ServerConfig.default.resourceIdBase + 0x200
        createTopLevel(s, wid: child)

        _ = s.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: child,
            property: 68, type: 33, format: .format32,
            data: encodeParent(0, byteOrder: .lsbFirst)
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.calls.count, 1)
        XCTAssertNil(bridge.calls[0].parent,
                     "parent value 0 → nil parent (detach the child relationship)")
    }

    /// Re-setting WM_TRANSIENT_FOR to a different parent must produce a
    /// fresh applyTransientFor call so the bridge can re-attach.
    func testRebindToDifferentParent() throws {
        let bridge = RecordingBridge()
        let s = runningSession(bridge: bridge)
        let parentA: UInt32 = ServerConfig.default.resourceIdBase + 0x100
        let parentB: UInt32 = ServerConfig.default.resourceIdBase + 0x101
        let child:   UInt32 = ServerConfig.default.resourceIdBase + 0x200
        createTopLevel(s, wid: parentA)
        createTopLevel(s, wid: parentB)
        createTopLevel(s, wid: child)

        for parent in [parentA, parentB] {
            _ = s.feed(Request.changeProperty(ChangeProperty(
                mode: .replace, window: child,
                property: 68, type: 33, format: .format32,
                data: encodeParent(parent, byteOrder: .lsbFirst)
            )).encode(byteOrder: .lsbFirst))
        }

        XCTAssertEqual(bridge.calls.count, 2)
        XCTAssertEqual(bridge.calls[0].parent, parentA)
        XCTAssertEqual(bridge.calls[1].parent, parentB)
    }
}
