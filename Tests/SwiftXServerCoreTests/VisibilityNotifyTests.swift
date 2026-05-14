import XCTest
@testable import SwiftXServerCore
import Framer

// VisibilityNotify state-transition tracking. Per X11R6 section 10.6:
// VisibilityNotify is emitted when a viewable window's visibility state
// changes between Unobscured / PartiallyObscured / FullyObscured. Only
// fires when the window has VisibilityChangeMask (1<<16) in its event
// mask. Not emitted when the window becomes unmapped (the spec only
// covers transitions while viewable).
//
// State derivation in ServerSession.emitVisibilityChanges:
//   !mapped → nil (no tracked state)
//   mapped + clipList empty → FullyObscured (2)
//   mapped + clipList == window bounds → Unobscured (0)
//   mapped + partial coverage → PartiallyObscured (1)

final class VisibilityNotifyTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    /// First VisibilityNotify event found in `bytes`.
    private func findVisibilityNotify(in bytes: [UInt8], byteOrder: ByteOrder) -> VisibilityNotifyEvent? {
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder),
                  case .event(let ev) = msg else {
                offset += 32; continue
            }
            if ev.code == 15,
               let vn = try? VisibilityNotifyEvent.decode(from: ev.bytes, byteOrder: byteOrder) {
                return vn
            }
            offset += msg.bytes.count
        }
        return nil
    }

    /// Send CreateWindow for a top-level with the given event mask. Returns
    /// the wid; the caller does MapWindow themselves so they can capture
    /// the resulting outbound bytes via feed's return value.
    private func createTopLevel(_ session: ServerSession, eventMask: UInt32, byteOrder: ByteOrder = .lsbFirst) -> UInt32 {
        let wid: UInt32 = ServerConfig.default.resourceIdBase + UInt32.random(in: 1...0xFF_FFFF)
        var valueList: [UInt8] = []
        for shift in [0, 8, 16, 24] {
            valueList.append(UInt8(truncatingIfNeeded: eventMask >> shift))
        }
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 1 << 11,    // CWEventMask
            valueList: valueList
        ))
        _ = session.feed(create.encode(byteOrder: byteOrder))
        return wid
    }

    func testMapWithVisibilityMaskEmitsUnobscured() throws {
        // VisibilityChangeMask = 1<<16. A freshly mapped top-level with no
        // overlapping siblings has its full clipList covered, so the
        // transition (nil → Unobscured) fires VisibilityNotify(state=0).
        let session = runningSession()
        let wid = createTopLevel(session, eventMask: 1 << 16)
        let bytes = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))

        guard let vn = findVisibilityNotify(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("expected VisibilityNotify on map")
            return
        }
        XCTAssertEqual(vn.state, .unobscured)
    }

    func testMapWithoutMaskEmitsNoVisibilityNotify() {
        // Same setup without VisibilityChangeMask — state tracking still
        // updates internally (so future subscriptions see correct prior
        // state), but no event leaves the server.
        let session = runningSession()
        let wid = createTopLevel(session, eventMask: 0)
        let bytes = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))
        XCTAssertNil(findVisibilityNotify(in: bytes, byteOrder: .lsbFirst))
    }

    func testUnmapClearsStateAndDoesNotEmit() throws {
        // Per X11 spec, VisibilityNotify is only sent for transitions
        // while the window is viewable. An UnmapWindow ends viewability;
        // we clear lastVisibilityState but don't emit.
        let session = runningSession()
        let wid = createTopLevel(session, eventMask: 1 << 16)
        _ = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))

        let bytes = session.feed(Request.unmapWindow(UnmapWindow(window: wid)).encode(byteOrder: .lsbFirst))
        XCTAssertNil(findVisibilityNotify(in: bytes, byteOrder: .lsbFirst),
                     "unmap must not emit VisibilityNotify")
    }

    func testRemapAfterUnmapEmitsAgain() throws {
        // After an unmap → state cleared. Next map → nil → Unobscured
        // transition, emit fires again.
        let session = runningSession()
        let wid = createTopLevel(session, eventMask: 1 << 16)
        _ = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.unmapWindow(UnmapWindow(window: wid)).encode(byteOrder: .lsbFirst))

        let bytes = session.feed(Request.mapWindow(MapWindow(window: wid)).encode(byteOrder: .lsbFirst))
        guard let vn = findVisibilityNotify(in: bytes, byteOrder: .lsbFirst) else {
            XCTFail("expected VisibilityNotify on re-map")
            return
        }
        XCTAssertEqual(vn.state, .unobscured)
    }
}
