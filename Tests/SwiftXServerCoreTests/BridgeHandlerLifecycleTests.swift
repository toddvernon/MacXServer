import XCTest
@testable import SwiftXServerCore
import Framer

#if canImport(AppKit)
import AppKit

// Bridge handler-list lifecycle. Each ServerSession registers 11 handlers
// on the bridge at init time. Without cleanup, the lists grew unboundedly
// across accept/disconnect cycles and dead-session closures (weak-self
// no-ops) kept firing on every AppKit event. cleanupOnDisconnect must
// call `bridge.removeHandlers(token:)` to prune this session's entries.

final class BridgeHandlerLifecycleTests: XCTestCase {

    func testSessionInitRegistersElevenHandlers() {
        let bridge = CocoaWindowBridge(scaleFactor: 1, log: nil)
        XCTAssertEqual(bridge.totalHandlerCount, 0, "fresh bridge has no handlers")

        let session = ServerSession(bridge: bridge)
        // Suppress unused warning; the session's init is what registers.
        _ = session.bridgeHandlerToken
        XCTAssertEqual(bridge.totalHandlerCount, 11,
                       "ServerSession init registers exactly 11 handlers on the bridge")
    }

    func testCleanupOnDisconnectRemovesThisSessionsHandlers() {
        let bridge = CocoaWindowBridge(scaleFactor: 1, log: nil)
        let s1 = ServerSession(bridge: bridge)
        let s2 = ServerSession(bridge: bridge)
        XCTAssertEqual(bridge.totalHandlerCount, 22, "two sessions = 22 handlers")
        XCTAssertNotEqual(s1.bridgeHandlerToken, s2.bridgeHandlerToken,
                          "every session gets a unique bridge handler token")

        s1.cleanupOnDisconnect()
        XCTAssertEqual(bridge.totalHandlerCount, 11,
                       "s1's 11 handlers removed; s2's still present")

        s2.cleanupOnDisconnect()
        XCTAssertEqual(bridge.totalHandlerCount, 0,
                       "both sessions cleaned up")
    }

    func testDisconnectReconnectDoesNotLeakHandlers() {
        // Simulates the routine CDE use case: dt-apps connect and
        // disconnect repeatedly. The handler list must stay bounded.
        let bridge = CocoaWindowBridge(scaleFactor: 1, log: nil)
        for _ in 0..<50 {
            let session = ServerSession(bridge: bridge)
            session.cleanupOnDisconnect()
        }
        XCTAssertEqual(bridge.totalHandlerCount, 0,
                       "50 connect/disconnect cycles must not accumulate handlers")
    }

    func testRemoveHandlersIsIdempotent() {
        let bridge = CocoaWindowBridge(scaleFactor: 1, log: nil)
        let s = ServerSession(bridge: bridge)
        s.cleanupOnDisconnect()
        s.cleanupOnDisconnect()
        XCTAssertEqual(bridge.totalHandlerCount, 0,
                       "second cleanup must be a no-op, not an error")
    }
}

#endif
