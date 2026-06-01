import XCTest
@testable import SwiftXServerCore
import Framer

// Opcode 57 (CopyGC) and opcode 103 (GetKeyboardControl) both have
// framer decoders + reply types but were on the unimplemented-opcode
// list until the 2026-05-31 group-4 capture audit surfaced them:
//   - xmpiano BadRequests on GetKeyboardControl at init → app crashes
//   - puzzle BadRequests on CopyGC at startup → app crashes
// Both fail "honestly" via spec-correct BadRequest emission (no silent
// lie) but are real missing implementations clients depend on.

final class CopyGCAndGetKeyboardControlTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = session.outbound.drain()
        return session
    }

    // MARK: - GetKeyboardControl

    /// Stub returns a well-formed reply with X server defaults so xmpiano
    /// can proceed past its init query. The exact default values aren't
    /// load-bearing — they just need to be plausible enough that clients
    /// don't reject the reply.
    func testGetKeyboardControlReturnsStubReply() throws {
        let session = runningSession()
        let bytes = session.feed(Request.getKeyboardControl(GetKeyboardControl())
            .encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply(let r) = msg else {
            XCTFail("expected reply, got \(msg)")
            return
        }
        let parsed = try GetKeyboardControlReply.decode(from: r.bytes, byteOrder: .lsbFirst)
        XCTAssertTrue(parsed.globalAutoRepeat, "default is autorepeat enabled")
        XCTAssertEqual(parsed.ledMask, 0)
        XCTAssertEqual(parsed.keyClickPercent, 50)
        XCTAssertEqual(parsed.bellPercent, 50)
        XCTAssertEqual(parsed.bellPitch, 400)
        XCTAssertEqual(parsed.bellDuration, 100)
        XCTAssertEqual(parsed.autoRepeats.count, 32)
        XCTAssertTrue(parsed.autoRepeats.allSatisfy { $0 == 0xFF },
                       "all keycodes default to repeat-enabled")
    }

    /// Regression: pre-2026-05-31 this hit the unimplemented-opcode path
    /// and emitted BadRequest. Today we return a reply. If a future
    /// refactor accidentally re-routes through reportUnimplementedOpcode,
    /// this test catches it.
    func testGetKeyboardControlNoLongerEmitsBadRequest() throws {
        let session = runningSession()
        let bytes = session.feed(Request.getKeyboardControl(GetKeyboardControl())
            .encode(byteOrder: .lsbFirst))

        // XError = first byte 0; reply = first byte 1; events use other codes.
        XCTAssertEqual(bytes.first, 1, "first byte must be the reply marker, not XError(0)")
    }

    // MARK: - CopyGC

    /// Validates that CopyGC moves the named GC components from src to
    /// dst per the value mask. Sets foreground on src via CreateGC,
    /// CopyGC's the foreground bit to dst, then verifies dst's GCState
    /// materialises with the copied foreground.
    func testCopyGCCopiesForegroundFromSrcToDst() throws {
        let session = runningSession()
        let rootId = ServerConfig.default.rootWindowId
        let srcGC: UInt32 = 0x4400100
        let dstGC: UInt32 = 0x4400101

        // src: foreground = pixel 1 (blackPixel per ColorTable init pins).
        _ = session.feed(CreateGC(
            cid: srcGC, drawable: rootId,
            valueMask: 0x4,    // CWForeground
            valueList: [0x01, 0x00, 0x00, 0x00]
        ).encode(byteOrder: .lsbFirst))
        // dst: foreground = pixel 0 (whitePixel) — different from src, so
        // a successful copy is observable.
        _ = session.feed(CreateGC(
            cid: dstGC, drawable: rootId,
            valueMask: 0x4,    // CWForeground
            valueList: [0x00, 0x00, 0x00, 0x00]
        ).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Copy just the foreground bit.
        _ = session.feed(Request.copyGC(CopyGC(
            srcGC: srcGC, dstGC: dstGC, valueMask: 0x4
        )).encode(byteOrder: .lsbFirst))

        // Verify dst's foreground is now 1 by reading the GCEntry directly.
        // GCState materialisation reads from entry.values[GCBits.foreground].
        guard let dstEntry = session.gcs.get(dstGC) else {
            XCTFail("dst GC not found post-copy")
            return
        }
        XCTAssertEqual(dstEntry.values[GCBits.foreground], 1,
                       "dst foreground must be source's foreground after CopyGC")
    }

    /// Components NOT in the value mask must be left untouched on dst.
    func testCopyGCDoesNotTouchUnmaskedComponents() throws {
        let session = runningSession()
        let rootId = ServerConfig.default.rootWindowId
        let srcGC: UInt32 = 0x4400110
        let dstGC: UInt32 = 0x4400111

        // src: foreground=1, background=2.
        _ = session.feed(CreateGC(
            cid: srcGC, drawable: rootId,
            valueMask: 0x4 | 0x8,   // CWForeground | CWBackground
            valueList: [
                0x01, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
            ]
        ).encode(byteOrder: .lsbFirst))
        // dst: foreground=10, background=20.
        _ = session.feed(CreateGC(
            cid: dstGC, drawable: rootId,
            valueMask: 0x4 | 0x8,
            valueList: [
                0x0A, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x00, 0x00,
            ]
        ).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Copy only foreground (bit 0x4).
        _ = session.feed(Request.copyGC(CopyGC(
            srcGC: srcGC, dstGC: dstGC, valueMask: 0x4
        )).encode(byteOrder: .lsbFirst))

        guard let dstEntry = session.gcs.get(dstGC) else {
            XCTFail("dst GC not found")
            return
        }
        XCTAssertEqual(dstEntry.values[GCBits.foreground], 1,
                       "foreground was in mask, must be copied")
        XCTAssertEqual(dstEntry.values[GCBits.background], 20,
                       "background not in mask, must stay at dst's prior value (20)")
    }

    /// Unknown src or dst GC must emit BadGC, not silently no-op.
    func testCopyGCWithUnknownSrcEmitsBadGC() throws {
        let session = runningSession()
        let rootId = ServerConfig.default.rootWindowId
        let dstGC: UInt32 = 0x4400120
        _ = session.feed(CreateGC(cid: dstGC, drawable: rootId,
                                   valueMask: 0, valueList: [])
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.copyGC(CopyGC(
            srcGC: 0xDEADBEEF, dstGC: dstGC, valueMask: 0x4
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bytes.first, 0, "must emit XError (first byte 0)")
        XCTAssertEqual(bytes[1], XErrorCode.gc.rawValue, "must be BadGC=13")
    }

    func testCopyGCWithUnknownDstEmitsBadGC() throws {
        let session = runningSession()
        let rootId = ServerConfig.default.rootWindowId
        let srcGC: UInt32 = 0x4400130
        _ = session.feed(CreateGC(cid: srcGC, drawable: rootId,
                                   valueMask: 0, valueList: [])
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.copyGC(CopyGC(
            srcGC: srcGC, dstGC: 0xCAFEBABE, valueMask: 0x4
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bytes.first, 0, "must emit XError")
        XCTAssertEqual(bytes[1], XErrorCode.gc.rawValue, "must be BadGC")
    }
}
