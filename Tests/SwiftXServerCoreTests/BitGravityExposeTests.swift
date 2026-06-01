import XCTest
import Foundation
import Framer
import SwiftXCaptureCore
@testable import SwiftXServerCore

// Tests for ConfigureWindow Expose emission on the moved window.
//
// Per X11 spec, a geometry change should Expose only the genuinely
// newly-revealed pixels — the region in the new clipList that wasn't
// covered by the old clipList translated by the move delta. Bits in
// the overlap are either preserved (server blits) or treated as
// previously-existing (client repaints from cache). The Expose is
// strictly for "I'm telling you about pixels you've never seen."
//
// Motivating client: xmmap scrolls by repeatedly issuing
// `ConfigureWindow mask=0x3 [x=0, y=-N]` (pure-move) on a 1000×1000
// child window inside a smaller parent viewport. Before this fix the
// server emitted the entire new clipList (~10 rects per scroll) =
// 1183 Exposes for 107 scrolls. After the fix swift-x emits only the
// newly-revealed strip per scroll, matching gold's pattern.

final class BitGravityExposeTests: XCTestCase {

    private let root = ServerConfig.default.rootWindowId
    private let exposureMask = MockWindowBridge.exposureMask

    /// Build a session with a top-level parent and a child window. Both
    /// mapped. The child uses the supplied `bitGravity` (X11 numeric
    /// value: 0=Forget, 1=NorthWest, ...).
    private func makeSessionWithChild(bitGravity: UInt8) -> (ServerSession, UInt32, UInt32) {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let parent: UInt32 = 0xB0001
        let child: UInt32 = 0xB0002
        // Parent: just a plain top-level.
        let pReq = CreateWindow(depth: 0, wid: parent, parent: root,
                                x: 0, y: 0, width: 200, height: 200, borderWidth: 0,
                                windowClass: .inputOutput, visual: 0,
                                valueMask: 0, valueList: [])
        _ = session.feed(pReq.encode(byteOrder: .lsbFirst))
        // Child: bit-gravity + ExposureMask.
        var valueMask: UInt32 = CW.eventMask
        var valueList: [UInt8] = encodeUInt32(exposureMask, byteOrder: .lsbFirst)
        if bitGravity != 0 {
            valueMask |= CW.bitGravity
            // CW value list order is by mask bit position (low to high).
            // bitGravity (1<<1) comes before eventMask (1<<11), so prepend.
            valueList = [bitGravity, 0, 0, 0] + valueList
        }
        let cReq = CreateWindow(depth: 0, wid: child, parent: parent,
                                x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
                                windowClass: .inputOutput, visual: 0,
                                valueMask: valueMask, valueList: valueList)
        _ = session.feed(cReq.encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: parent).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: child).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return (session, parent, child)
    }

    /// Send a ConfigureWindow that moves the child by (dx, dy) without
    /// resizing. Returns the count of Expose events emitted on the
    /// child afterward.
    private func pureMove(_ session: ServerSession, child: UInt32, dx: Int16, dy: Int16) -> Int {
        var valueList: [UInt8] = []
        valueList.append(contentsOf: encodeUInt32(UInt32(bitPattern: Int32(dx)), byteOrder: .lsbFirst))
        valueList.append(contentsOf: encodeUInt32(UInt32(bitPattern: Int32(dy)), byteOrder: .lsbFirst))
        let cwMask: UInt16 = UInt16(CWindow.x | CWindow.y)
        let req: [UInt8] = encodeConfigureWindow(window: child, valueMask: cwMask, valueList: valueList, byteOrder: .lsbFirst)
        let outbound = session.feed(req)
        return countExposes(in: outbound, window: child, byteOrder: .lsbFirst)
    }

    func testPureMoveOnNorthWestGravityChildEmitsNoExpose() throws {
        let (session, _, child) = makeSessionWithChild(bitGravity: 1)  // NorthWestGravity
        // Move the child up by 10 pixels (xmmap-style scroll).
        let exposeCount = pureMove(session, child: child, dx: 0, dy: -10)
        XCTAssertEqual(exposeCount, 0,
                       "NorthWest bit-gravity preserves pixels under pure-move; no Expose required")
    }

    func testPureMoveStaysWithinParentEmitsNoExposeRegardlessOfGravity() throws {
        // Even with Forget gravity, a pure-move that stays inside the
        // parent's visible region does NOT newly-reveal any pixels in
        // the moved window — the new clipList is fully contained in the
        // translated old clipList. Per the post-2026-06-01 region-delta
        // semantics, no Expose fires. (Pre-fix code would have emitted
        // the full clipList here as a defensive over-emit.)
        let (session, _, child) = makeSessionWithChild(bitGravity: 0)  // ForgetGravity
        let exposeCount = pureMove(session, child: child, dx: 0, dy: -10)
        XCTAssertEqual(exposeCount, 0,
                       "Pure-move that doesn't newly-reveal any pixels should emit no Expose")
    }

    func testXmmapStyleRepeatedScrollOnNorthWestEmitsNoExpose() throws {
        // The smoking-gun case: 100 sequential pure-move scrolls on a
        // NorthWest child should emit ZERO Exposes on the child.
        // Pre-fix swift-x emitted ~10 per scroll = ~1000 total.
        let (session, _, child) = makeSessionWithChild(bitGravity: 1)
        var totalExposes = 0
        for i in 1...100 {
            totalExposes += pureMove(session, child: child, dx: 0, dy: Int16(-i))
        }
        XCTAssertEqual(totalExposes, 0,
                       "100 NorthWest pure-move scrolls should produce 0 Exposes on the moved window")
    }

    func testRealXmmapCaptureExposeCountDroppedSubstantially() throws {
        // Replay the actual xmmap swiftx-side C2S stream through a fresh
        // ServerSession and count Exposes emitted. The known baseline
        // pre-fix was 1183 Exposes on the scrolled window (0x6800063).
        // Post-fix we expect close to gold's ~79 — the test asserts <200
        // as a generous safety margin that still catches regressions
        // (the 11x explosion would land at 1000+ even with some
        // variation).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/xmmap-running-on-ss2-display-on-swiftx.xtap")
        let frames = try CaptureReader.read(from: url.path)
        let c2s = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }

        let session = ServerSession()
        let outbound = session.feed(c2s)
        guard let byteOrder = session.byteOrder else {
            XCTFail("session never reached running phase"); return
        }

        // Walk outbound and count Expose events targeted at window 0x6800063.
        let setupReply = try SetupReply.decode(from: outbound, byteOrder: byteOrder)
        guard case .accepted(let accepted) = setupReply else {
            XCTFail("first reply is not SetupAccepted"); return
        }
        var offset = accepted.encode(byteOrder: byteOrder).count
        var exposesOnScrolledWindow = 0
        while offset + 32 <= outbound.count {
            let frame = Array(outbound[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder) else {
                offset += 32; continue
            }
            if case .event(let ev) = msg, ev.code == 12 {
                let win = decodeUInt32(Array(ev.bytes[4..<8]), byteOrder: byteOrder)
                if win == 0x6800063 { exposesOnScrolledWindow += 1 }
            }
            offset += msg.bytes.count
        }
        XCTAssertLessThan(exposesOnScrolledWindow, 200,
                          "xmmap's NorthWest scrolled window should not get the 1183 Expose explosion anymore; got \(exposesOnScrolledWindow)")
    }

    // MARK: - Helpers

    private func encodeConfigureWindow(window: UInt32, valueMask: UInt16,
                                       valueList: [UInt8], byteOrder: ByteOrder) -> [UInt8] {
        // ConfigureWindow opcode = 12. Layout (X11 protocol §10):
        //   opcode (1) + pad (1) + length (2) + window (4) + mask (2) + pad (2) + values (4*n)
        let lenIn4 = UInt16(3 + (valueList.count / 4))
        var bytes: [UInt8] = []
        bytes.append(12)         // opcode
        bytes.append(0)          // pad
        bytes.append(contentsOf: encodeUInt16(lenIn4, byteOrder: byteOrder))
        bytes.append(contentsOf: encodeUInt32(window, byteOrder: byteOrder))
        bytes.append(contentsOf: encodeUInt16(valueMask, byteOrder: byteOrder))
        bytes.append(0); bytes.append(0)
        bytes.append(contentsOf: valueList)
        return bytes
    }

    private func countExposes(in bytes: [UInt8], window: UInt32, byteOrder: ByteOrder) -> Int {
        var count = 0
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: byteOrder),
                  case .event(let ev) = msg else {
                offset += 32; continue
            }
            if ev.code == 12 {  // Expose
                // Expose event: window field at bytes[4..8]
                let win = decodeUInt32(Array(ev.bytes[4..<8]), byteOrder: byteOrder)
                if win == window { count += 1 }
            }
            offset += msg.bytes.count
        }
        return count
    }

    private func encodeUInt16(_ v: UInt16, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        case .msbFirst: return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }

    private func encodeUInt32(_ v: UInt32, byteOrder: ByteOrder) -> [UInt8] {
        switch byteOrder {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }

    private func decodeUInt32(_ b: [UInt8], byteOrder: ByteOrder) -> UInt32 {
        switch byteOrder {
        case .lsbFirst: return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        case .msbFirst: return UInt32(b[3]) | (UInt32(b[2]) << 8) | (UInt32(b[1]) << 16) | (UInt32(b[0]) << 24)
        }
    }
}
