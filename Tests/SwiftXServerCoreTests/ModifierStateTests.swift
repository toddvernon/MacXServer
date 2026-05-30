import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Locks in the modifier-state plumbing introduced 2026-05-30 to fix the
// stuck-Ctrl xterm-menu bug. Mouse events used to source their state-mask
// bits from a cache (`currentModifierState`) that only updated on key
// events. If the user pressed Ctrl, hit a letter, then released Ctrl
// without pressing another character key, the cache stayed Ctrl=1 forever
// and every subsequent ButtonPress reported state=0x4 -- xterm reads that
// as a Ctrl+click and pops its menu on plain LMB/RMB.
//
// Repro captured at /private/tmp/swift-x-captures/2026-05-30T15-41-42-xterm.xtap:
//   30752ms  KeyRelease state=0x4   (Ctrl still held)
//   ...user releases Ctrl physically (no event observed)...
//   35265ms  ButtonPress state=0x4  ← stuck. Every click from here on.
//
// The fix:
//   1. Mouse handlers receive the live NSEvent.modifierFlags and compute
//      the state mask from those instead of from the cache.
//   2. A new flagsChanged handler updates the cache when a bare modifier
//      transitions (no character key). Other paths that still read the
//      cache (e.g. crossings under grab) stay accurate.

final class ModifierStateTests: XCTestCase {

    // X state-mask bits we assert against.
    private static let shiftMask:    UInt16 = 1 << 0
    private static let controlMask:  UInt16 = 1 << 2
    private static let button1Mask:  UInt16 = 1 << 8
    private static let button3Mask:  UInt16 = 1 << 10

    // NSEvent.modifierFlags raw bits.
    private static let nsControl: UInt = 1 << 18
    private static let nsShift:   UInt = 1 << 17

    /// Minimal session with one top-level + one descendant that has
    /// ButtonPress / ButtonRelease in its event mask.
    private func makeSession() -> ServerSession {
        let session = ServerSession(bridge: MockWindowBridge())
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let mask: UInt32 = (1 << 2) | (1 << 3)   // ButtonPressMask | ButtonReleaseMask
        sendCreateWindow(session, wid: 0xA0001, parent: ServerConfig.default.rootWindowId,
                         x: 0, y: 0, w: 200, h: 200, eventMask: mask)
        _ = session.feed(MapWindow(window: 0xA0001).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return session
    }

    /// Drive the session through the buggy timeline and assert the regression
    /// stays closed: after a Ctrl-keystroke and a (synthetic) modifier release,
    /// a plain click MUST report state=0 (no ControlMask), even though the
    /// cache was last written with Ctrl=1.
    func testStuckCtrlAfterKeyReleaseClearsByFlagsChanged() throws {
        let session = makeSession()

        // 1. User presses Ctrl + L. KeyPress carries Ctrl in modifierFlags.
        //    macKeyCode 0x25 = "L" on a US layout.
        session.handleKeyEvent(topLevel: 0xA0001, macKeyCode: 0x25,
                               modifierFlags: Self.nsControl, isDown: true)
        // 2. User releases L (still holding Ctrl).
        session.handleKeyEvent(topLevel: 0xA0001, macKeyCode: 0x25,
                               modifierFlags: Self.nsControl, isDown: false)
        _ = session.outbound.drain()   // discard the KeyPress/KeyRelease bytes

        // 3. User releases Ctrl. macOS fires NSEvent.flagsChanged with empty
        //    modifierFlags. Without our new handler, this would never reach
        //    the session and the cache stays Ctrl=1.
        session.handleModifiersChanged(modifierFlags: 0)

        // 4. User clicks. Live event modifiers are 0 (Ctrl is up).
        session.handleMouseEvent(topLevel: 0xA0001, x: 50, y: 50,
                                 button: 1, isDown: true, modifierFlags: 0)

        let press = try lastButtonEvent(session.outbound.drain())
        XCTAssertEqual(press.code, 4, "ButtonPress")
        XCTAssertEqual(press.state, 0,
            "post-flagsChanged click must report clean state; got 0x\(String(press.state, radix: 16))")
    }

    /// Belt-and-suspenders: even if flagsChanged never reaches the session
    /// (some racy path), the mouse handler itself MUST trust the live
    /// modifierFlags it received, not the cache. This is the primary
    /// defense -- without it, any single-event race could re-introduce the
    /// stuck-Ctrl symptom.
    func testMouseEventTrustsLiveModifiersOverCache() throws {
        let session = makeSession()

        // Pollute the cache via a key event with Ctrl held.
        session.handleKeyEvent(topLevel: 0xA0001, macKeyCode: 0x25,
                               modifierFlags: Self.nsControl, isDown: true)
        _ = session.outbound.drain()

        // Click with NO modifiers in the live event -- skip flagsChanged
        // entirely. The fix must still produce state=0.
        session.handleMouseEvent(topLevel: 0xA0001, x: 50, y: 50,
                                 button: 1, isDown: true, modifierFlags: 0)
        let press = try lastButtonEvent(session.outbound.drain())
        XCTAssertEqual(press.state, 0,
            "live mouse-event modifierFlags MUST override stale cache from key path; got 0x\(String(press.state, radix: 16))")
    }

    /// Positive case: a Ctrl-click really is a Ctrl-click. The control bit
    /// must reach the wire when the live modifierFlags carries it.
    func testLiveCtrlModifierReachesButtonPressState() throws {
        let session = makeSession()
        session.handleMouseEvent(topLevel: 0xA0001, x: 50, y: 50,
                                 button: 1, isDown: true,
                                 modifierFlags: Self.nsControl)
        let press = try lastButtonEvent(session.outbound.drain())
        XCTAssertEqual(press.state & Self.controlMask, Self.controlMask,
            "Ctrl+click must report ControlMask in state")
    }

    /// ButtonRelease state preserves the just-released-button bit (X spec
    /// reports modifiers + buttons-held BEFORE the event). Modifier bits
    /// still come from the live event. Locks in that the fix didn't break
    /// the button-bit accounting.
    func testButtonReleasePreservesButtonBitWithLiveModifiers() throws {
        let session = makeSession()
        session.handleMouseEvent(topLevel: 0xA0001, x: 50, y: 50,
                                 button: 1, isDown: true,
                                 modifierFlags: Self.nsShift)
        _ = session.outbound.drain()
        session.handleMouseEvent(topLevel: 0xA0001, x: 50, y: 50,
                                 button: 1, isDown: false,
                                 modifierFlags: Self.nsShift)
        let release = try lastButtonEvent(session.outbound.drain())
        XCTAssertEqual(release.code, 5, "ButtonRelease")
        XCTAssertEqual(release.state, Self.shiftMask | Self.button1Mask,
            "Release state = Shift + Button1; got 0x\(String(release.state, radix: 16))")
    }

    // MARK: - Helpers

    private struct ButtonObserved {
        let code: UInt8         // 4 = ButtonPress, 5 = ButtonRelease
        let state: UInt16
    }

    /// Walk the 32-byte event records produced by ServerSession's outbound
    /// queue and return the last ButtonPress / ButtonRelease seen. We want
    /// the LAST one because some assertions drive multiple events and only
    /// care about the final outcome.
    private func lastButtonEvent(_ bytes: [UInt8]) throws -> ButtonObserved {
        var last: ButtonObserved?
        var offset = 0
        while offset + 32 <= bytes.count {
            let chunk = Array(bytes[offset..<offset + 32])
            let code = chunk[0]
            if code == 4 || code == 5 {
                // X11 input-event state is at bytes 28..29 (little-endian).
                let lo = UInt16(chunk[28])
                let hi = UInt16(chunk[29])
                last = ButtonObserved(code: code, state: (hi << 8) | lo)
            }
            offset += 32
        }
        guard let result = last else {
            throw NSError(domain: "ModifierStateTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no Button event in outbound"])
        }
        return result
    }

    private func sendCreateWindow(
        _ session: ServerSession, wid: UInt32, parent: UInt32,
        x: Int16, y: Int16, w: UInt16, h: UInt16, eventMask: UInt32
    ) {
        let valueMask: UInt32 = eventMask == 0 ? 0 : CW.eventMask
        let valueList: [UInt8] = eventMask == 0 ? [] : [
            UInt8(eventMask & 0xFF),
            UInt8((eventMask >> 8) & 0xFF),
            UInt8((eventMask >> 16) & 0xFF),
            UInt8((eventMask >> 24) & 0xFF)
        ]
        let req = CreateWindow(
            depth: 0, wid: wid, parent: parent,
            x: x, y: y, width: w, height: h, borderWidth: 0,
            windowClass: .inputOutput,
            visual: 0, valueMask: valueMask, valueList: valueList
        )
        _ = session.feed(req.encode(byteOrder: .lsbFirst))
    }
}
