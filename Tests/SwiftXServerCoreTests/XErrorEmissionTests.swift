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

    func testGetAtomNameOnUnknownAtomEmitsBadAtom() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusAtom: UInt32 = 0x9999_9999
        let bytes = session.feed(
            Request.getAtomName(GetAtomName(atom: bogusAtom)).encode(byteOrder: .lsbFirst)
        )

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.atom.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusAtom)
        XCTAssertEqual(err.majorOpcode, GetAtomName.opcode)
    }

    func testGetAtomNameOnAtomZeroEmitsBadAtom() throws {
        // Atom 0 is the spec sentinel `None`, not a valid atom argument.
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(
            Request.getAtomName(GetAtomName(atom: 0)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.atom.rawValue)
    }

    func testGetAtomNameOnPredefinedAtomSucceeds() throws {
        // Atom 1 = PRIMARY (predefined per X11 spec). Must NOT error.
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(
            Request.getAtomName(GetAtomName(atom: 1)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply = msg else {
            XCTFail("expected GetAtomName reply for PRIMARY, got \(msg)")
            return
        }
    }

    func testQueryFontOnUnknownFontEmitsBadFont() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusFont: UInt32 = 0x4242_4242
        let bytes = session.feed(
            Request.queryFont(QueryFont(font: bogusFont)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.font.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusFont)
        XCTAssertEqual(err.majorOpcode, QueryFont.opcode)
    }

    func testCloseFontOnUnknownFontEmitsBadFont() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusFont: UInt32 = 0x3333_3333
        let bytes = session.feed(
            Request.closeFont(CloseFont(font: bogusFont)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.font.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusFont)
        XCTAssertEqual(err.majorOpcode, CloseFont.opcode)
    }

    func testFreePixmapOnUnknownPixmapEmitsBadPixmap() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x77AA77AA
        let bytes = session.feed(
            Request.freePixmap(FreePixmap(pixmap: bogus)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.pixmap.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogus)
        XCTAssertEqual(err.majorOpcode, FreePixmap.opcode)
    }

    func testFreeCursorOnUnknownCursorEmitsBadCursor() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogus: UInt32 = 0x6666_6666
        let bytes = session.feed(
            Request.freeCursor(FreeCursor(cursor: bogus)).encode(byteOrder: .lsbFirst)
        )
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.cursor.rawValue)
        XCTAssertEqual(err.majorOpcode, FreeCursor.opcode)
    }

    func testCreateGlyphCursorOnUnknownFontEmitsBadFont() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusFont: UInt32 = 0xAB_AB_AB_AB
        let cgc = Request.createGlyphCursor(CreateGlyphCursor(
            cid: 0x4400000 + 1, sourceFont: bogusFont, maskFont: 0,
            sourceChar: 0, maskChar: 0,
            foreRed: 0, foreGreen: 0, foreBlue: 0,
            backRed: 0xFFFF, backGreen: 0xFFFF, backBlue: 0xFFFF
        ))
        let bytes = session.feed(cgc.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.font.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusFont)
        XCTAssertEqual(err.majorOpcode, CreateGlyphCursor.opcode)
    }

    func testChangePropertyWithUnknownAtomEmitsBadAtom() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        // Window must exist for the property handler to reach the atom check.
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 10, height: 10, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))

        let bogusAtom: UInt32 = 0xFFFF_FF00
        let change = Request.changeProperty(ChangeProperty(
            mode: .replace, window: wid, property: bogusAtom,
            type: 31, format: .format8, data: [0x01]
        ))
        let bytes = session.feed(change.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.atom.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusAtom)
        XCTAssertEqual(err.majorOpcode, ChangeProperty.opcode)
    }

    func testGetPropertyWithUnknownAtomEmitsBadAtom() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusAtom: UInt32 = 0xFEED_F00D
        let req = Request.getProperty(GetProperty(
            delete: false, window: ServerConfig.default.rootWindowId,
            property: bogusAtom, type: 0, longOffset: 0, longLength: 100
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.atom.rawValue)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), bogusAtom)
        XCTAssertEqual(err.majorOpcode, GetProperty.opcode)
    }

    func testGetPropertyWithPredefinedAtomSucceeds() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        // Atom 23 = WM_HINTS per X11 spec; predefined in our AtomTable.
        let req = Request.getProperty(GetProperty(
            delete: false, window: ServerConfig.default.rootWindowId,
            property: 23, type: 0, longOffset: 0, longLength: 100
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .reply = msg else {
            XCTFail("expected GetProperty reply for predefined atom, got \(msg)")
            return
        }
    }

    func testCreateWindowOnRootEmitsSubstructureNotifyWhenMaskSet() throws {
        // A WM-style client sets SubstructureNotifyMask on root, then a new
        // top-level appears. Root should receive CreateNotify(event=root).
        // This path is dormant for the captured app suite (no WM client)
        // but locks in the root-substructure-notify plumbing.
        let session = runningSession(byteOrder: .lsbFirst)

        let substructureNotifyMask: UInt32 = 1 << 19
        var maskValueList: [UInt8] = []
        for shift in [0, 8, 16, 24] {
            maskValueList.append(UInt8(truncatingIfNeeded: substructureNotifyMask >> shift))
        }
        _ = session.feed(Request.changeWindowAttributes(ChangeWindowAttributes(
            window: ServerConfig.default.rootWindowId,
            valueMask: 1 << 11,   // CWEventMask
            valueList: maskValueList
        )).encode(byteOrder: .lsbFirst))

        let topWid: UInt32 = ServerConfig.default.resourceIdBase + 1
        let bytes = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: topWid, parent: ServerConfig.default.rootWindowId,
            x: 10, y: 20, width: 100, height: 50, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))

        // Walk for CreateNotify (code 16) with event=root, window=topWid.
        var found = false
        var offset = 0
        while offset + 32 <= bytes.count {
            let frame = Array(bytes[offset..<offset+32])
            guard let msg = try? ServerMessage.decodeOne(from: frame, byteOrder: .lsbFirst),
                  case .event(let ev) = msg else { offset += 32; continue }
            if ev.code == 16,
               let cn = try? CreateNotifyEvent.decode(from: ev.bytes, byteOrder: .lsbFirst),
               cn.parent == ServerConfig.default.rootWindowId, cn.window == topWid {
                found = true
                break
            }
            offset += msg.bytes.count
        }
        XCTAssertTrue(found, "expected CreateNotify(event=root, window=topWid) on outbound")
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

    // MARK: - Opcodes added 2026-05-14 (post-comparison-study sweep)

    func testNoOperationEmitsNothing() throws {
        // Xt scatters XNoOp as wire flushes. Pre-decoder-add this returned
        // BadRequest every time. Must now be silent — no reply, no error.
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(Request.noOperation(NoOperation()).encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty,
                      "NoOperation must produce no outbound bytes; got \(bytes.count)")
    }

    func testAllocColorCellsEmitsBadAllocNotBadRequest() throws {
        // Spec lets us emit BadAlloc when read-write cell allocation can't
        // succeed. Critical that we emit .alloc not .request: Xt's color
        // converter catches BadAlloc to fall back to read-only AllocColor;
        // BadRequest gets logged as "server is broken" and the client
        // doesn't degrade gracefully.
        let session = runningSession(byteOrder: .lsbFirst)
        let req = Request.allocColorCells(AllocColorCells(
            contiguous: false, cmap: 0x21, colors: 4, planes: 0
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.alloc.rawValue,
                       "AllocColorCells must emit BadAlloc, not BadRequest")
        XCTAssertEqual(err.majorOpcode, AllocColorCells.opcode)
    }

    func testKillClientAcceptedSilently() throws {
        // No multi-client lifecycle yet — KillClient is accepted but does
        // nothing on the wire. Must NOT emit BadRequest.
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(Request.killClient(KillClient(resource: 0xDEADBEEF))
            .encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty)
    }

    func testSetCloseDownModeAcceptedSilently() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bytes = session.feed(Request.setCloseDownMode(SetCloseDownMode(mode: 1))
            .encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty)
    }

    func testGetMotionEventsRepliesWithEmptyEventList() throws {
        // No motion-event ring yet. Spec-correct empty reply: 32-byte
        // header, nEvents=0, length=0.
        let session = runningSession(byteOrder: .lsbFirst)
        let req = Request.getMotionEvents(GetMotionEvents(
            window: ServerConfig.default.rootWindowId, start: 0, stop: 0
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bytes.count, 32, "GetMotionEvents reply is 32 bytes when nEvents=0")
        // Byte 0 must be 1 (reply marker), bytes 8..12 must be 0 (nEvents).
        XCTAssertEqual(bytes[0], 1, "first byte must be reply marker (1)")
        let nEvents = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8)
                    | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24)
        XCTAssertEqual(nEvents, 0)
    }

    func testBogusRequestLengthEmitsBadLengthAndSignalsClose() throws {
        // Length field of 0 makes the request stream unparseable — we
        // can't compute "how many bytes to skip" so we have to tear down.
        // Pre-2026-05-14 we just logged and looped forever on the wedge
        // bytes. Now: emit BadLength + set shouldClose so the listener
        // cancels the read source.
        let session = runningSession(byteOrder: .lsbFirst)
        XCTAssertFalse(session.shouldClose, "precondition")

        // 4-byte request with opcode=42 (any value) and length=0.
        let wedge: [UInt8] = [42, 0, 0, 0]
        let bytes = session.feed(wedge)

        XCTAssertTrue(session.shouldClose, "must signal close on length=0")
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadLength on the wire, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.length.rawValue, "must be BadLength")
        XCTAssertEqual(err.majorOpcode, 42)
    }

    // MARK: - Per-handler validation sweep (Create* handlers, 2026-05-15)

    /// Build a session with a MockWindowBridge and a single top-level
    /// window mapped. Returns (session, topLevelId). CopyArea needs a
    /// bridge AND a window resolvable via topLevelAndOffset, since the
    /// handler early-returns without emitting events when bridge is nil
    /// or the drawable isn't in a known top-level subtree.
    private func sessionWithMappedTopLevel() -> (ServerSession, UInt32) {
        let bridge = MockWindowBridge()
        let session = ServerSession(bridge: bridge)
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 0x600
        _ = session.feed(Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        _ = session.feed(Request.mapWindow(MapWindow(window: wid))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        return (session, wid)
    }

    func testCopyArea_GraphicsExposuresFalse_SuppressesNoExposeEvent() throws {
        // Pre-2026-05-15: NoExposure was emitted unconditionally after every
        // CopyArea, regardless of the GC's graphics-exposures bit. Per spec,
        // when GC has graphics-exposures=False the server MUST emit neither
        // GraphicsExpose nor NoExposure. Athena ScrollBar's internal GC sets
        // this; we used to queue a NoExpose the client explicitly didn't
        // want.
        let (session, wid) = sessionWithMappedTopLevel()

        // CreateGC with graphics-exposures explicitly set to 0 (False).
        // CWGraphicsExposures = 1 << 16; value 0 = False.
        let cid: UInt32 = ServerConfig.default.resourceIdBase + 0x700
        var valueList: [UInt8] = []
        for shift in [0, 8, 16, 24] {
            valueList.append(UInt8(truncatingIfNeeded: UInt32(0) >> shift))
        }
        _ = session.feed(Request.createGC(CreateGC(
            cid: cid, drawable: wid,
            valueMask: 1 << 16,    // CWGraphicsExposures
            valueList: valueList
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Same-window CopyArea on the top-level. Must produce no events.
        let bytes = session.feed(Request.copyArea(CopyArea(
            srcDrawable: wid, dstDrawable: wid,
            gc: cid,
            srcX: 0, srcY: 0, dstX: 10, dstY: 10,
            width: 20, height: 20
        )).encode(byteOrder: .lsbFirst))

        XCTAssertTrue(bytes.isEmpty,
                      "CopyArea with graphics-exposures=False must emit no events; got \(bytes.count) bytes")
    }

    func testCopyArea_GraphicsExposuresDefault_EmitsNoExposeEvent() throws {
        // Default GC has graphics-exposures=True; we still emit NoExpose
        // (since our same-window backing-store copies have no obscured
        // source). xterm's CopyWait BLOCKS waiting for this — load-bearing.
        let (session, wid) = sessionWithMappedTopLevel()

        // Default-CW GC: graphics-exposures defaults to True.
        let cid: UInt32 = ServerConfig.default.resourceIdBase + 0x701
        _ = session.feed(Request.createGC(CreateGC(
            cid: cid, drawable: wid, valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(Request.copyArea(CopyArea(
            srcDrawable: wid, dstDrawable: wid,
            gc: cid,
            srcX: 0, srcY: 0, dstX: 10, dstY: 10,
            width: 20, height: 20
        )).encode(byteOrder: .lsbFirst))

        // Should contain a NoExposureEvent (code 14). May also contain
        // other events from the CopyArea path, so check for presence
        // rather than exact byte count.
        var sawNoExpose = false
        var offset = 0
        while offset + 32 <= bytes.count {
            if bytes[offset] & 0x7F == 14 { sawNoExpose = true; break }
            offset += 32
        }
        XCTAssertTrue(sawNoExpose,
                      "default-GC CopyArea (graphics-exposures=True) must emit NoExposure")
    }

    func testChangeProperty_AppendWithMismatchedFormatEmitsBadMatch() throws {
        // Spec 10.10: BadMatch on Prepend/Append when request's format ≠
        // existing entry's format. Pre-2026-05-15 we silently kept the
        // existing format and concatenated bytes — corrupting the stored
        // property since the count-of-units interpretation no longer
        // matched the byte count.
        let session = runningSession(byteOrder: .lsbFirst)
        let root = ServerConfig.default.rootWindowId
        // Use a custom atom for the property. WM_NAME=39 has its own
        // bridge side-effect (title), so use something inert.
        let propAtom: UInt32 = session.atoms.intern("SWIFT_X_TEST_PROP")
        let typeAtom: UInt32 = 31    // STRING

        // Store as format=8.
        _ = session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace,
            window: root, property: propAtom, type: typeAtom,
            format: .format8, data: [0x41, 0x42]
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Append with format=32. Must emit BadMatch.
        let bytes = session.feed(Request.changeProperty(ChangeProperty(
            mode: .append,
            window: root, property: propAtom, type: typeAtom,
            format: .format32, data: [0xDE, 0xAD, 0xBE, 0xEF]
        )).encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadMatch on format-mismatched Append, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.match.rawValue)
        XCTAssertEqual(err.majorOpcode, ChangeProperty.opcode)
    }

    func testChangeProperty_AppendWithMismatchedTypeEmitsBadMatch() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let root = ServerConfig.default.rootWindowId
        let propAtom: UInt32 = session.atoms.intern("SWIFT_X_TEST_PROP2")
        let stringType: UInt32 = 31
        let atomType: UInt32 = 4

        _ = session.feed(Request.changeProperty(ChangeProperty(
            mode: .replace,
            window: root, property: propAtom, type: stringType,
            format: .format8, data: [0x41]
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Append with same format=8 but different TYPE atom.
        let bytes = session.feed(Request.changeProperty(ChangeProperty(
            mode: .append,
            window: root, property: propAtom, type: atomType,
            format: .format8, data: [0x42]
        )).encode(byteOrder: .lsbFirst))

        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadMatch on type-mismatched Append, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.match.rawValue)
    }

    func testChangeProperty_AppendOnNonExistentPropertySucceeds() throws {
        // Per spec: Prepend/Append on a property that doesn't exist yet
        // is equivalent to Replace — no existing type/format to mismatch
        // against, so the request creates the property.
        let session = runningSession(byteOrder: .lsbFirst)
        let root = ServerConfig.default.rootWindowId
        let propAtom: UInt32 = session.atoms.intern("SWIFT_X_TEST_PROP3")

        let bytes = session.feed(Request.changeProperty(ChangeProperty(
            mode: .append,
            window: root, property: propAtom, type: 31,
            format: .format8, data: [0x41]
        )).encode(byteOrder: .lsbFirst))
        // Should NOT be an XError. May emit PropertyNotify but not an error.
        if !bytes.isEmpty,
           let msg = try? ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst),
           case .xError(let err) = msg {
            XCTFail("Append on nonexistent property must succeed; got error code \(err.errorCode)")
        }
    }

    func testCreateWindowOnUnknownParentEmitsBadWindow() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let bogusParent: UInt32 = 0xDEADBEEF
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        let req = Request.createWindow(CreateWindow(
            depth: 8, wid: wid, parent: bogusParent,
            x: 0, y: 0, width: 10, height: 10, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadWindow on bad parent, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.majorOpcode, CreateWindow.opcode)
    }

    func testCreateWindowWithDuplicateIDEmitsBadIDChoice() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let wid: UInt32 = ServerConfig.default.resourceIdBase + 1
        let root = ServerConfig.default.rootWindowId
        let create = { (id: UInt32) -> Request in
            Request.createWindow(CreateWindow(
                depth: 8, wid: id, parent: root,
                x: 0, y: 0, width: 10, height: 10, borderWidth: 0,
                windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
                valueMask: 0, valueList: []
            ))
        }
        _ = session.feed(create(wid).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()
        let bytes = session.feed(create(wid).encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadIDChoice on duplicate wid, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.idChoice.rawValue)
        XCTAssertEqual(err.majorOpcode, CreateWindow.opcode)
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), wid)
    }

    func testCreatePixmapWithDepthZeroEmitsBadValue() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let pid: UInt32 = ServerConfig.default.resourceIdBase + 2
        let req = Request.createPixmap(CreatePixmap(
            depth: 0, pid: pid, drawable: ServerConfig.default.rootWindowId,
            width: 10, height: 10
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadValue on depth=0, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.value.rawValue)
        XCTAssertEqual(err.majorOpcode, CreatePixmap.opcode)
    }

    func testCreatePixmapOnUnknownDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let pid: UInt32 = ServerConfig.default.resourceIdBase + 2
        let req = Request.createPixmap(CreatePixmap(
            depth: 8, pid: pid, drawable: 0xDEADBEEF,
            width: 10, height: 10
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadDrawable, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue)
        XCTAssertEqual(err.majorOpcode, CreatePixmap.opcode)
    }

    func testCreateGCOnUnknownDrawableEmitsBadDrawable() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let cid: UInt32 = ServerConfig.default.resourceIdBase + 3
        let req = Request.createGC(CreateGC(
            cid: cid, drawable: 0xDEADBEEF,
            valueMask: 0, valueList: []
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadDrawable on CreateGC, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.drawable.rawValue)
        XCTAssertEqual(err.majorOpcode, CreateGC.opcode)
    }

    func testAllocColorOnUnknownColormapEmitsBadColor() throws {
        let session = runningSession(byteOrder: .lsbFirst)
        let req = Request.allocColor(AllocColor(
            cmap: 0xDEADBEEF, red: 0, green: 0, blue: 0
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadColor, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.color.rawValue)
        XCTAssertEqual(err.majorOpcode, AllocColor.opcode)
    }

    func testCreateWindowCollidingWithRootEmitsBadIDChoice() throws {
        // Picking wid = root is the textbook BadIDChoice case (root is
        // a server-allocated sentinel, not in any client's range).
        let session = runningSession(byteOrder: .lsbFirst)
        let req = Request.createWindow(CreateWindow(
            depth: 8, wid: ServerConfig.default.rootWindowId,
            parent: ServerConfig.default.rootWindowId,
            x: 0, y: 0, width: 10, height: 10, borderWidth: 0,
            windowClass: .inputOutput, visual: ServerConfig.default.rootVisualId,
            valueMask: 0, valueList: []
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadIDChoice on wid==root, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.idChoice.rawValue)
    }

    func testUngrabButtonOnUnknownWindowEmitsBadWindow() throws {
        // UngrabButton routes through validateWindowOrRoot like the other
        // grab opcodes. Unknown grabWindow → BadWindow (the validator
        // emits it). Spec is fine with this.
        let session = runningSession(byteOrder: .lsbFirst)
        let req = Request.ungrabButton(UngrabButton(
            button: 1, grabWindow: 0xDEADBEEF, modifiers: 0
        ))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadWindow on unknown grabWindow")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.window.rawValue)
        XCTAssertEqual(err.majorOpcode, UngrabButton.opcode)
    }
}
