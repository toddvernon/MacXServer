import XCTest
@testable import SwiftXServerCore
import Framer

final class XErrorEmissionTests: XCTestCase {

    // Drive a session past handshake into .running so emitError has a byteOrder
    // to use and outbound is hooked up.
    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let session = ServerSession()
        let setupBytes = SetupRequest(byteOrder: byteOrder).encode()
        // Drain the setup reply so subsequent outbound only contains what we emit.
        _ = session.feed(setupBytes)
        _ = session.outbound.drain()
        return session
    }

    func testEmitErrorAppendsValid32ByteXErrorOnOutbound() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let before = session.errorsEmitted

        session.emitError(.window, majorOpcode: 8, badResourceId: 0xDEADBEEF, minorOpcode: 0)
        let bytes = session.outbound.drain()

        XCTAssertEqual(bytes.count, 32, "XError must be a single 32-byte frame")
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError on outbound, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), 0xDEADBEEF)
        XCTAssertEqual(err.majorOpcode, 8)
        XCTAssertEqual(err.minorOpcode(byteOrder: .lsbFirst), 0)

        XCTAssertEqual(session.errorsEmitted, before + 1, "errorsEmitted counter must increment")
    }

    func testEmitErrorUsesMSBWhenSessionIsMSB() throws {
        let session = runningSession(byteOrder: .msbFirst)
        session.emitError(.atom, majorOpcode: 16, badResourceId: 0xCAFEBABE)
        let bytes = session.outbound.drain()

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .msbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError")
            return
        }
        XCTAssertEqual(err.badResourceId(byteOrder: .msbFirst), 0xCAFEBABE)
        // Byte 4 carries the high byte under MSB; under LSB it would be the low byte.
        // Sanity-check the wire byte order by reading byte 4 directly.
        XCTAssertEqual(bytes[4], 0xCA, "MSB encoding puts the high byte at offset 4")
    }

    func testEmitErrorIsNoOpBeforeHandshake() {
        // Brand-new session in .awaitingSetup — emitError should not crash and
        // not append bytes (XErrors before handshake travel via SetupRefused,
        // not the error path).
        let session = ServerSession()
        let before = session.errorsEmitted
        session.emitError(.implementation, majorOpcode: 0)
        XCTAssertTrue(session.outbound.drain().isEmpty)
        XCTAssertEqual(session.errorsEmitted, before)
    }

    func testCopyAreaWithUnknownSrcDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusSrc: UInt32 = 0xDEADBEEF
        let copy = Request.copyArea(CopyArea(
            srcDrawable: bogusSrc, dstDrawable: ServerConfig.default.rootWindowId,
            gc: 0x4400000, srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 10, height: 10
        ))
        let bytes = session.feed(copy.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue, "must be BadDrawable")
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusSrc, "badResourceId must point at the unknown src drawable")
        XCTAssertEqual(err.majorOpcode, CopyArea.opcode)
    }

    func testCopyAreaWithUnknownDstDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusDst: UInt32 = 0xCAFEBABE
        let copy = Request.copyArea(CopyArea(
            srcDrawable: ServerConfig.default.rootWindowId, dstDrawable: bogusDst,
            gc: 0x4400000, srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 10, height: 10
        ))
        let bytes = session.feed(copy.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue, "must be BadDrawable")
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusDst, "badResourceId must point at the unknown dst drawable")
    }

    func testEmittedErrorCarriesCurrentSequenceNumber() throws {
        // After setup the session's sequenceNumber is 0; feed one InternAtom
        // request to advance it, then emit an error and assert the seq field
        // matches the current session counter.
        let session = runningSession(byteOrder: .lsbFirst)
        let intern = Request.internAtom(InternAtom(onlyIfExists: false, name: Array("FOO".utf8)))
        _ = session.feed(intern.encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let seqBeforeEmit = session.sequenceNumber
        session.emitError(.value, majorOpcode: 1, badResourceId: 7)
        let bytes = session.outbound.drain()
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError")
            return
        }
        XCTAssertEqual(err.sequenceNumber(byteOrder: .lsbFirst), seqBeforeEmit,
                       "error must reference the failing request's seq")
    }
}
