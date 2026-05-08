import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore
@testable import SwiftXCaptureCore

// Verifies that the session calls the bridge in the right order with the
// right arguments when xclock's lifecycle requests come in. This is the M2
// done condition expressed as a unit test — we don't need a Cocoa runloop
// to verify the protocol-level shape of the map sequence.
final class WindowBridgeTests: XCTestCase {

    func testTopLevelCreateRegistersWithBridge() {
        let (session, bridge) = makeSessionWithBridge()

        completeSetup(session)
        sendCreateWindow(
            session: session,
            wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
            x: 10, y: 20, width: 200, height: 100, eventMask: 0
        )

        XCTAssertEqual(bridge.registered.count, 1)
        XCTAssertEqual(bridge.registered[0].id, 0xA0001)
        XCTAssertEqual(bridge.registered[0].geometry.width, 200)
        XCTAssertEqual(bridge.registered[0].geometry.height, 100)
        XCTAssertEqual(bridge.registered[0].geometry.x, 10)
    }

    func testNonRootCreateDoesNotRegisterWithBridge() {
        let (session, bridge) = makeSessionWithBridge()
        completeSetup(session)

        // Register a top-level so a child can have a non-root parent.
        sendCreateWindow(
            session: session,
            wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, eventMask: 0
        )
        sendCreateWindow(
            session: session,
            wid: 0xA0002, parent: 0xA0001,
            x: 0, y: 0, width: 100, height: 100, eventMask: 0
        )

        XCTAssertEqual(bridge.registered.count, 1)
        XCTAssertEqual(bridge.registered[0].id, 0xA0001)
    }

    func testMapTopLevelEmitsReparentConfigureMapExpose() throws {
        let (session, bridge) = makeSessionWithBridge()
        completeSetup(session)
        sendCreateWindow(
            session: session,
            wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 164, height: 164,
            eventMask: MockWindowBridge.exposureMask
        )

        // feed() drains outbound on each call, so we capture the map-window
        // call's return directly.
        let bytes = session.feed(MapWindow(window: 0xA0001).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bridge.mapped, [0xA0001])

        let byteOrder = try XCTUnwrap(session.byteOrder)
        var offset = 0
        let reparent = try ServerMessage.decodeOne(from: Array(bytes[offset...]), byteOrder: byteOrder)
        guard case .event(let reparentEv) = reparent else { XCTFail("expected event"); return }
        XCTAssertEqual(reparentEv.code, 21, "first event should be ReparentNotify (code 21)")
        offset += reparentEv.bytes.count

        let configure = try ServerMessage.decodeOne(from: Array(bytes[offset...]), byteOrder: byteOrder)
        guard case .event(let cfgEv) = configure else { XCTFail("expected event"); return }
        XCTAssertEqual(cfgEv.code, 22, "second event should be ConfigureNotify (code 22)")
        offset += cfgEv.bytes.count

        let mapped = try ServerMessage.decodeOne(from: Array(bytes[offset...]), byteOrder: byteOrder)
        guard case .event(let mapEv) = mapped else { XCTFail("expected event"); return }
        XCTAssertEqual(mapEv.code, 19, "third event should be MapNotify (code 19)")
        offset += mapEv.bytes.count

        let expose = try ServerMessage.decodeOne(from: Array(bytes[offset...]), byteOrder: byteOrder)
        guard case .event(let exposeEv) = expose else { XCTFail("expected event"); return }
        XCTAssertEqual(exposeEv.code, 12, "fourth event should be Expose (code 12)")
        offset += exposeEv.bytes.count

        XCTAssertEqual(offset, bytes.count, "no leftover bytes")
    }

    func testWMNamePropertyTriggersBridgeTitle() {
        let (session, bridge) = makeSessionWithBridge()
        completeSetup(session)
        sendCreateWindow(
            session: session,
            wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, eventMask: 0
        )
        let title = "xclock"
        let req = ChangeProperty(
            mode: .replace, window: 0xA0001,
            property: 39, // WM_NAME
            type: 31,     // STRING
            format: .format8,
            data: Array(title.utf8)
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bridge.titles[0xA0001], title)
    }

    func testXclockReplayDrivesBridgeFully() throws {
        let (session, bridge) = makeSessionWithBridge()

        let path = capturePath(named: "xclock.xtap")
        let frames = try CaptureReader.read(from: path)
        let c2s = frames
            .filter { $0.direction == .clientToServer }
            .flatMap { $0.bytes }

        _ = session.feed(c2s)

        // xclock creates one top-level (0x440000A) and one descendant (0x440000B).
        XCTAssertEqual(bridge.registered.count, 1)
        XCTAssertEqual(bridge.registered[0].id, 0x440000A)
        XCTAssertEqual(bridge.mapped, [0x440000A])
        XCTAssertEqual(bridge.descendantsMapped.contains(0x440000B), true)
        // After WM_CLASS lands, ServerSession prepends `[<wmInstance>] ` to
        // any subsequent WM_NAME so the user can tell which X client owns
        // the NSWindow at a glance. xclock's WM_NAME is just "xclock".
        XCTAssertEqual(bridge.titles[0x440000A], "[xclock] xclock")
    }

    // MARK: - Helpers

    private func makeSessionWithBridge() -> (ServerSession, MockWindowBridge) {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        return (session, bridge)
    }

    private func completeSetup(_ session: ServerSession) {
        let setupBytes = SetupRequest(byteOrder: .lsbFirst).encode()
        _ = session.feed(setupBytes)
    }

    private func sendCreateWindow(
        session: ServerSession,
        wid: UInt32, parent: UInt32,
        x: Int16, y: Int16, width: UInt16, height: UInt16,
        eventMask: UInt32
    ) {
        let valueMask: UInt32 = eventMask == 0 ? 0 : CW.eventMask
        let valueList: [UInt8] = eventMask == 0 ? [] : encodeUInt32(eventMask, byteOrder: .lsbFirst)
        let req = CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: width, height: height, borderWidth: 0,
            windowClass: .inputOutput,
            visual: 0, valueMask: valueMask, valueList: valueList
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }

    private func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }

    private func sendMapWindow(session: ServerSession, window: UInt32) {
        let req = MapWindow(window: window)
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }

    private func capturePath(named filename: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
            .appendingPathComponent(filename)
            .path
    }
}
