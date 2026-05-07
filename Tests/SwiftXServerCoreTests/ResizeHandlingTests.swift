import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Verifies the M3 part-b path: a top-level NSWindow resize (simulated via
// MockWindowBridge.simulateResize) updates the WindowTable and emits
// ConfigureNotify on the top-level. Then when the X client responds with
// ConfigureWindow on a descendant that has ExposureMask, the session emits
// Expose on that descendant.
final class ResizeHandlingTests: XCTestCase {

    func testTopLevelResizeEmitsConfigureNotifyAndUpdatesTable() throws {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        // Top-level with StructureNotifyMask so it's a plausible client.
        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200,
                   eventMask: 0)
        _ = session.outbound.drain()

        bridge.simulateResize(id: 0xA0001, width: 400, height: 300)

        let entry = try XCTUnwrap(session.windows.get(0xA0001))
        XCTAssertEqual(entry.width, 400)
        XCTAssertEqual(entry.height, 300)

        let bytes = session.outbound.drain()
        XCTAssertFalse(bytes.isEmpty)
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .event(let event) = msg else { XCTFail("expected event"); return }
        XCTAssertEqual(event.code, 22, "ConfigureNotify code is 22")
    }

    func testDescendantConfigureWindowResizeEmitsExposeIfExposureMask() throws {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200, eventMask: 0)
        // Inner with ExposureMask
        sendCreate(session, wid: 0xA0002, parent: 0xA0001, x: 0, y: 0, w: 200, h: 200,
                   eventMask: MockWindowBridge.exposureMask)
        _ = session.outbound.drain()

        // ConfigureWindow on inner with new width=400, height=300.
        let widthBytes = encodeUInt32(400, byteOrder: .lsbFirst)
        let heightBytes = encodeUInt32(300, byteOrder: .lsbFirst)
        let req = ConfigureWindow(
            window: 0xA0002,
            valueMask: UInt16(CWindow.width | CWindow.height),
            valueList: widthBytes + heightBytes
        )
        let out = session.feed(req.encode(byteOrder: .lsbFirst))

        // Should have at least one Expose event in the output.
        var offset = 0
        var sawExpose = false
        while offset < out.count {
            let msg = try ServerMessage.decodeOne(from: Array(out[offset...]), byteOrder: .lsbFirst)
            if case .event(let event) = msg, event.code == 12 {
                sawExpose = true
            }
            offset += msg.bytes.count
        }
        XCTAssertTrue(sawExpose, "ConfigureWindow size change with ExposureMask should emit Expose")

        let entry = try XCTUnwrap(session.windows.get(0xA0002))
        XCTAssertEqual(entry.width, 400)
        XCTAssertEqual(entry.height, 300)
    }

    func testDescendantConfigureWindowDoesNotEmitExposeIfNoExposureMask() throws {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let root = ServerConfig.default.rootWindowId

        sendCreate(session, wid: 0xA0001, parent: root, x: 0, y: 0, w: 200, h: 200, eventMask: 0)
        sendCreate(session, wid: 0xA0002, parent: 0xA0001, x: 0, y: 0, w: 200, h: 200, eventMask: 0)
        _ = session.outbound.drain()

        let widthBytes = encodeUInt32(400, byteOrder: .lsbFirst)
        let heightBytes = encodeUInt32(300, byteOrder: .lsbFirst)
        let req = ConfigureWindow(
            window: 0xA0002,
            valueMask: UInt16(CWindow.width | CWindow.height),
            valueList: widthBytes + heightBytes
        )
        let out = session.feed(req.encode(byteOrder: .lsbFirst))

        var offset = 0
        while offset < out.count {
            let msg = try ServerMessage.decodeOne(from: Array(out[offset...]), byteOrder: .lsbFirst)
            if case .event(let event) = msg, event.code == 12 {
                XCTFail("should not emit Expose when window lacks ExposureMask")
            }
            offset += msg.bytes.count
        }
    }

    // MARK: - Helpers

    private func sendCreate(_ session: ServerSession, wid: UInt32, parent: UInt32,
                            x: Int16, y: Int16, w: UInt16, h: UInt16, eventMask: UInt32) {
        let mask: UInt32 = eventMask == 0 ? 0 : CW.eventMask
        let valueList: [UInt8] = eventMask == 0 ? [] : encodeUInt32(eventMask, byteOrder: .lsbFirst)
        let req = CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: mask, valueList: valueList
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }

    private func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }
}
