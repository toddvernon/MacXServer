import XCTest
@testable import SwiftXServerCore
import Framer

// Colormap opcodes 78-90 (minus 84/85/86 which are tested elsewhere).
// All currently emit spec-correct Bad* errors or no-op success — no real
// palette behavior because the backing visual is TrueColor. The wire
// shape and dispatch routing is what these tests lock in; the comparison
// study identified BadAlloc / BadAccess / BadColor as the load-bearing
// codes for Xt's color-converter fallback paths.

final class ColormapOpcodesTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let s = ServerSession()
        _ = s.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = s.outbound.drain()
        return s
    }

    private func decodeFirstError(_ bytes: [UInt8]) throws -> XError {
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            struct NotAnError: Error {}
            throw NotAnError()
        }
        return err
    }

    func testCreateColormapEmitsBadAlloc() throws {
        let s = runningSession()
        let req = Request.createColormap(CreateColormap(
            alloc: 0, mid: 0x4400099,
            window: ServerConfig.default.rootWindowId,
            visual: ServerConfig.default.rootVisualId
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.alloc.rawValue)
        XCTAssertEqual(err.majorOpcode, CreateColormap.opcode)
    }

    func testFreeColormapOnDefaultEmitsBadAccess() throws {
        let s = runningSession()
        let req = Request.freeColormap(FreeColormap(cmap: ServerConfig.default.defaultColormapId))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.access.rawValue,
                       "freeing the screen's default colormap must be BadAccess")
    }

    func testFreeColormapOnUnknownEmitsBadColor() throws {
        let s = runningSession()
        let req = Request.freeColormap(FreeColormap(cmap: 0xDEADBEEF))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.color.rawValue)
    }

    func testCopyColormapAndFreeEmitsBadAlloc() throws {
        let s = runningSession()
        let req = Request.copyColormapAndFree(CopyColormapAndFree(
            mid: 0x4400099, srcCmap: ServerConfig.default.defaultColormapId
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.alloc.rawValue)
    }

    func testInstallColormapDefaultIsSilentSuccess() throws {
        let s = runningSession()
        let req = Request.installColormap(InstallColormap(cmap: ServerConfig.default.defaultColormapId))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty, "InstallColormap on default cmap must not emit anything")
    }

    func testInstallColormapUnknownEmitsBadColor() throws {
        let s = runningSession()
        let req = Request.installColormap(InstallColormap(cmap: 0xDEADBEEF))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.color.rawValue)
    }

    func testListInstalledColormapsReturnsDefault() throws {
        let s = runningSession()
        let req = Request.listInstalledColormaps(ListInstalledColormaps(
            window: ServerConfig.default.rootWindowId
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        XCTAssertEqual(bytes.count, 36, "reply = 32-byte header + 4 bytes for one cmap")
        let reply = try ListInstalledColormapsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.colormaps, [ServerConfig.default.defaultColormapId])
    }

    func testAllocColorPlanesEmitsBadAlloc() throws {
        let s = runningSession()
        let req = Request.allocColorPlanes(AllocColorPlanes(
            contiguous: false, cmap: ServerConfig.default.defaultColormapId,
            colors: 4, red: 1, green: 1, blue: 1
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.alloc.rawValue)
    }

    func testStoreColorsOnDefaultEmitsBadAccess() throws {
        let s = runningSession()
        let req = Request.storeColors(StoreColors(
            cmap: ServerConfig.default.defaultColormapId, rawItems: []
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.access.rawValue,
                       "StoreColors on TrueColor-backed default cmap must be BadAccess")
    }

    func testStoreNamedColorOnDefaultEmitsBadAccess() throws {
        let s = runningSession()
        let req = Request.storeNamedColor(StoreNamedColor(
            flags: 0x07,
            cmap: ServerConfig.default.defaultColormapId,
            pixel: 16,
            name: Array("red".utf8)
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.access.rawValue)
    }

    func testFreeColorsOnDefaultIsSilentSuccess() throws {
        let s = runningSession()
        let req = Request.freeColors(FreeColors(
            cmap: ServerConfig.default.defaultColormapId,
            planeMask: 0, pixels: [16, 17, 18]
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        XCTAssertTrue(bytes.isEmpty)
    }

    func testFreeColorsOnUnknownCmapEmitsBadColor() throws {
        let s = runningSession()
        let req = Request.freeColors(FreeColors(
            cmap: 0xDEADBEEF, planeMask: 0, pixels: []
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let err = try decodeFirstError(bytes)
        XCTAssertEqual(err.errorCode, XErrorCode.color.rawValue)
    }
}
