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

    func testPolyFillRectangleWithUnknownDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0xBADDEC0D
        let pfr = Request.polyFillRectangle(PolyFillRectangle(
            drawable: bogus, gc: 0x4400000,
            rectangles: [Rectangle(x: 0, y: 0, width: 5, height: 5)]
        ))
        let bytes = session.feed(pfr.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, PolyFillRectangle.opcode)
    }

    func testValidateDrawTargetSilentlyDropsForPixmapAndRoot() throws {
        // Pixmaps and the root are isKnownDrawable=true but topLevelAndOffset
        // returns nil. Per the documented lie in SHORTCUTS, this case logs and
        // returns nil rather than emitting BadImplementation — dt-apps draw
        // into pixmaps as backing buffers and the existing silent-drop is
        // load-bearing for them.
        let session = runningSession(byteOrder: .lsbFirst)
        let rootId = ServerConfig.default.rootWindowId

        let result = session.validateDrawTarget(rootId, majorOpcode: PolyFillRectangle.opcode)
        XCTAssertNil(result, "root should not resolve to a render target")
        XCTAssertTrue(session.outbound.drain().isEmpty, "must not emit XError for known-but-unrenderable drawable")
    }

    func testGetGeometryOnUnknownDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0xFEEDFACE
        let bytes = session.feed(
            Request.getGeometry(GetGeometry(drawable: bogus)).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, GetGeometry.opcode)
    }

    func testGetGeometryOnRootReturnsScreenDimensions() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(
            Request.getGeometry(GetGeometry(drawable: ServerConfig.default.rootWindowId))
                .encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply(let reply) = msg else {
            XCTFail("expected reply, got \(msg)")
            return
        }
        let parsed = try GetGeometryReply.decode(from: reply.bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(parsed.root, ServerConfig.default.rootWindowId)
        XCTAssertEqual(parsed.width, ServerConfig.default.widthInPixels)
        XCTAssertEqual(parsed.height, ServerConfig.default.heightInPixels)
        XCTAssertEqual(parsed.x, 0)
        XCTAssertEqual(parsed.y, 0)
    }

    func testQueryBestSizeOnUnknownDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x99999999
        let bytes = session.feed(
            Request.queryBestSize(QueryBestSize(
                sizeClass: .cursor, drawable: bogus, width: 16, height: 16
            )).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, QueryBestSize.opcode)
    }

    func testClearAreaOnUnknownWindowEmitsBadWindow() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0xAAAA1234
        let bytes = session.feed(
            Request.clearArea(ClearArea(
                exposures: false, window: bogus, x: 0, y: 0, width: 10, height: 10
            )).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue, "must be BadWindow")
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, ClearArea.opcode)
    }

    func testDestroyWindowOnUnknownWindowEmitsBadWindow() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x77777777
        let bytes = session.feed(
            Request.destroyWindow(DestroyWindow(window: bogus)).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, DestroyWindow.opcode)
    }

    func testMapWindowOnUnknownWindowEmitsBadWindow() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x88888888
        let bytes = session.feed(
            Request.mapWindow(MapWindow(window: bogus)).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.majorOpcode, MapWindow.opcode)
    }

    func testGetPropertyOnRootSucceedsViaValidateWindowOrRoot() throws {
        // validateWindowOrRoot must accept the screen root even though it's
        // not in the windows table. GetProperty(root, ...) is the canonical
        // "client probes RESOURCE_MANAGER at init" call and must not fail.
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(
            Request.getProperty(GetProperty(
                delete: false, window: ServerConfig.default.rootWindowId,
                property: 1, type: 0, longOffset: 0, longLength: 100
            )).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply = msg else {
            XCTFail("expected GetProperty reply, got \(msg)")
            return
        }
    }

    func testGetPropertyOnUnknownWindowEmitsBadWindow() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x55555555
        let bytes = session.feed(
            Request.getProperty(GetProperty(
                delete: false, window: bogus, property: 1, type: 0,
                longOffset: 0, longLength: 100
            )).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, GetProperty.opcode)
    }

    func testPolyFillRectangleWithUnknownGCEmitsBadGC() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        // Create a real top-level window first so the drawable check passes
        // (root silently drops via the "known but unrenderable" branch,
        // never reaching GC validation).
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        let create = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        _ = session.feed(create.encode(byteOrder: .lsbFirst))

        let bogusGC: UInt32 = 0xBADBADBA
        let pfr = Request.polyFillRectangle(PolyFillRectangle(
            drawable: wid, gc: bogusGC,
            rectangles: [Rectangle(x: 0, y: 0, width: 5, height: 5)]
        ))
        let bytes = session.feed(pfr.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.gc.rawValue, "must be BadGC")
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusGC)
        XCTAssertEqual(err.majorOpcode, PolyFillRectangle.opcode)
    }

    func testFreeGCOnUnknownGCEmitsBadGC() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusGC: UInt32 = 0x12121212
        let bytes = session.feed(
            Request.freeGC(FreeGC(gc: bogusGC)).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.gc.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusGC)
        XCTAssertEqual(err.majorOpcode, FreeGC.opcode)
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
