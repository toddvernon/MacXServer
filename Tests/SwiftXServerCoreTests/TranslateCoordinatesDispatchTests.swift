import XCTest
import Framer
@testable import SwiftXServerCore

/// Regression for the "Motif second-tier cascade menu pops up at the
/// wrong screen position" bug. handleTranslateCoordinates used to treat
/// every top-level as sitting at (0,0) in root coords — fine when we
/// didn't honor client placement, broken once top-levels have meaningful
/// root positions (especially override-redirect popups, which the client
/// positions exactly). First-tier menus weren't affected because Motif
/// caches widget root coords at realization; second-tier menus re-query
/// via XTranslateCoordinates(cascade, root, ...) which routes here.
final class TranslateCoordinatesDispatchTests: XCTestCase {

    private func encode(_ r: TranslateCoordinates) -> [UInt8] {
        r.encode(byteOrder: .lsbFirst)
    }

    /// Top-level placed at root (200, 150) → src=top, dst=root → reply
    /// must echo the top-level's root coords. Pre-fix this returned (0, 0).
    func testTranslateTopLevelToRootReturnsRootCoords() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let topId: UInt32 = 0x4400001
        // CreateWindow at root coords (200, 150). The default placeTopLevel
        // path honors any non-zero client-set coords.
        _ = session.feed(CreateWindow(
            depth: 0, wid: topId,
            parent: ServerConfig.default.rootWindowId,
            x: 200, y: 150, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: topId).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(encode(TranslateCoordinates(
            srcWindow: topId, dstWindow: ServerConfig.default.rootWindowId,
            srcX: 0, srcY: 0
        )))
        let reply = try TranslateCoordinatesReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.dstX, 200)
        XCTAssertEqual(reply.dstY, 150)
        XCTAssertTrue(reply.sameScreen)
    }

    /// Descendant of a placed top-level → src=descendant, dst=root → must
    /// fold in the descendant's offset AND the top-level's root coords.
    /// This is the path Motif walks for second-tier cascade placement.
    func testTranslateDescendantToRootIncludesTopLevelOrigin() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let topId: UInt32 = 0x4400002
        let childId: UInt32 = 0x4400003
        _ = session.feed(CreateWindow(
            depth: 0, wid: topId,
            parent: ServerConfig.default.rootWindowId,
            x: 300, y: 250, width: 400, height: 300, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: childId,
            parent: topId,
            x: 25, y: 40, width: 80, height: 20, borderWidth: 0,
            windowClass: .inputOutput, visual: 0,
            valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: topId).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // Translate child's (5, 8) to root coords.
        // Expected: top.x + child.x + 5 = 300 + 25 + 5 = 330
        //           top.y + child.y + 8 = 250 + 40 + 8 = 298
        let bytes = session.feed(encode(TranslateCoordinates(
            srcWindow: childId, dstWindow: ServerConfig.default.rootWindowId,
            srcX: 5, srcY: 8
        )))
        let reply = try TranslateCoordinatesReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.dstX, 330)
        XCTAssertEqual(reply.dstY, 298)
    }

    /// Cross-top-level translation: src in one top-level at root (100, 100),
    /// dst in another at root (500, 200). The fold-in of each top-level's
    /// own root position must cancel correctly.
    /// Expected: src_root - dst_root_origin = (105, 105) - (500, 200) = (-395, -95)
    func testTranslateBetweenTwoTopLevels() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        let aId: UInt32 = 0x4400004
        let bId: UInt32 = 0x4400005
        _ = session.feed(CreateWindow(
            depth: 0, wid: aId, parent: ServerConfig.default.rootWindowId,
            x: 100, y: 100, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(CreateWindow(
            depth: 0, wid: bId, parent: ServerConfig.default.rootWindowId,
            x: 500, y: 200, width: 100, height: 100, borderWidth: 0,
            windowClass: .inputOutput, visual: 0, valueMask: 0, valueList: []
        ).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: aId).encode(byteOrder: .lsbFirst))
        _ = session.feed(MapWindow(window: bId).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        let bytes = session.feed(encode(TranslateCoordinates(
            srcWindow: aId, dstWindow: bId,
            srcX: 5, srcY: 5
        )))
        let reply = try TranslateCoordinatesReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.dstX, -395)
        XCTAssertEqual(reply.dstY, -95)
    }
}
