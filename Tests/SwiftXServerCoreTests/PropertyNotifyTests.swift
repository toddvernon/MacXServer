import XCTest
@testable import SwiftXServerCore
import Framer

// Per X11R6 section 10.10:
//   ChangeProperty → PropertyNotify(state=NewValue) if the window has
//     PropertyChangeMask (1<<22) in its event mask.
//   DeleteProperty → PropertyNotify(state=Deleted) only if the property
//     actually existed before the delete.
//   GetProperty with delete=True → PropertyNotify(state=Deleted) if the
//     property existed and was removed.
//
// Xt's PROPERTY_CHANGE_TIMESTAMP probe (set a property, wait for
// PropertyNotify, capture event.time) depends on this.

final class PropertyNotifyTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    /// Walk outbound and pull the first PropertyNotify event (code 28).
    private func findPropertyNotify(in bytes: [UInt8], byteOrder: ByteOrder) -> PropertyNotifyEvent? {
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder),
                  case .event(let ev) = msg else {
                offset += 32; continue
            }
            if ev.code == 28,
               let pn = try? PropertyNotifyEvent.decode(from: ev.bytes, byteOrder: byteOrder) {
                return pn
            }
            offset += msg.bytes.count
        }
        return nil
    }

    /// Drive a window into existence with PropertyChangeMask in its event
    /// mask (1<<22 per X.h). 1<<11 also turns on PropertyChange in some
    /// X.h variants — we use the canonical 1<<22 = PropertyChangeMask.
    private func createWindowWithPropertyMask(_ session: ServerSession, wid: UInt32, byteOrder: ByteOrder = .lsbFirst) {
        // CWEventMask bit = 1<<11; valueList carries the mask UInt32.
        var valueList: [UInt8] = []
        let propertyChangeMask: UInt32 = 1 << 22
        for shift in [0, 8, 16, 24] {
            valueList.append(UInt8(truncatingIfNeeded: propertyChangeMask >> shift))
        }
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 1 << 11,    // CWEventMask
            valueList: valueList
        ))
        _ = session.feed(create.encode(byteOrder: byteOrder))
        _ = session.outbound.drain()
    }

    func testChangePropertyEmitsPropertyNotifyNewValue() throws {
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        createWindowWithPropertyMask(session, wid: wid)
        let atom = session.atoms.intern("MY_PROP")

        let change = Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: atom, type: 31,
            format: .format8, data: [0x41, 0x42, 0x43]
        ))
        let bytes = session.feed(change.encode(byteOrder: .lsbFirst))

        guard let pn = findPropertyNotify(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("expected PropertyNotify on outbound, got \(bytes.count) bytes")
            return
        }
        XCTAssertEqual(pn.window, wid)
        XCTAssertEqual(pn.atom, atom)
        XCTAssertEqual(pn.state, .newValue)
    }

    func testChangePropertyWithoutMaskEmitsNoPropertyNotify() throws {
        let session = runningSession()
        // Window with NO PropertyChangeMask.
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 2
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(create.encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let atom = session.atoms.intern("OTHER_PROP")
        let change = Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: atom, type: 31,
            format: .format8, data: [0x01]
        ))
        let bytes = session.feed(change.encode(byteOrder: .lsbFirst))

        XCTAssertNil(findPropertyNotify(in: bytes, byteOrder: .lsbFirst),
                     "PropertyNotify must not fire without PropertyChangeMask")
    }

    func testDeletePropertyEmitsDeletedOnlyIfExisted() throws {
        let session = runningSession()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 3
        createWindowWithPropertyMask(session, wid: wid)
        let atom = session.atoms.intern("DEL_PROP")

        // Set the prop first (this will emit PropertyNotify NewValue; drain).
        _ = session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: atom, type: 31,
            format: .format8, data: [0x10]
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Delete: should emit PropertyNotify(state=Deleted).
        let del = Request.deleteProperty(DeleteProperty(window: wid, property: atom))
        let bytes = session.feed(del.encode(byteOrder: .lsbFirst))
        guard let pn = findPropertyNotify(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("expected PropertyNotify(Deleted) after delete of existing prop")
            return
        }
        XCTAssertEqual(pn.state, .deleted)
        XCTAssertEqual(pn.atom, atom)

        // Second delete (now nonexistent): NO PropertyNotify.
        let bytes2 = session.feed(del.encode(byteOrder: .lsbFirst))
        XCTAssertNil(findPropertyNotify(in: bytes2, byteOrder: .lsbFirst),
                     "delete of nonexistent prop must not emit PropertyNotify")
    }
}
