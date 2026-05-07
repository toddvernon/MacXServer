import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// Verifies the Phase-1 startup replies xterm and other Xt clients depend on:
// ListFonts, GetKeyboardMapping, GetModifierMapping, GetPointerMapping,
// QueryColors. Without these, Xlib hangs on XOpenDisplay or font selection.
final class StartupRepliesTests: XCTestCase {

    func testListFontsWithStarPatternReturnsAllSynthesizedNames() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = ListFonts(maxNames: 1000, pattern: Array("*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try ListFontsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertGreaterThan(reply.names.count, 30, "expected ~30+ Phase-1 entries")

        // Must include canonical aliases.
        let strs = reply.names.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(strs.contains("fixed"))
        XCTAssertTrue(strs.contains("9x15"))
        XCTAssertTrue(strs.contains("7x14"))
        XCTAssertTrue(strs.contains("12x24"))
    }

    func testListFontsPatternMatchesXLFDPrefix() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = ListFonts(maxNames: 100, pattern: Array("-apple-monaco*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try ListFontsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertGreaterThan(reply.names.count, 0)
        // Every match should start with -apple-monaco
        for name in reply.names {
            let s = String(decoding: name, as: UTF8.self)
            XCTAssertTrue(s.hasPrefix("-apple-monaco"), "got \(s)")
        }
    }

    func testListFontsMaxNamesIsRespected() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = ListFonts(maxNames: 5, pattern: Array("*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let reply = try ListFontsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.names.count, 5)
    }

    func testGetKeyboardMappingReturnsKeysymsForRequestedRange() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = GetKeyboardMapping(firstKeycode: 8, count: 8)
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try GetKeyboardMappingReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.keysymsPerKeycode, 2)
        XCTAssertEqual(reply.keysyms.count, 8 * 2)
    }

    func testGetModifierMappingReturnsCanonicalShape() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = GetModifierMapping()
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try GetModifierMappingReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.keycodesPerModifier, 2)
        XCTAssertEqual(reply.keycodes.count, 8 * 2)        // 8 modifiers × 2 slots
    }

    func testGetPointerMappingReturnsThreeButtons() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let req = GetPointerMapping()
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try GetPointerMappingReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.map, [1, 2, 3])
    }

    func testQueryColorsLooksUpAllocatedPixels() throws {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        // Allocate two colors so we have something to query.
        _ = session.feed(AllocColor(cmap: 0x21, red: 0xFFFF, green: 0, blue: 0)
            .encode(byteOrder: .lsbFirst))
        _ = session.feed(AllocColor(cmap: 0x21, red: 0, green: 0xAAAA, blue: 0)
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // First allocation gets pixel=16, second gets pixel=17.
        let req = QueryColors(cmap: 0x21, pixels: [16, 17, 9999])
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try QueryColorsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.colors.count, 3)
        XCTAssertEqual(reply.colors[0].red, 0xFFFF)
        XCTAssertEqual(reply.colors[0].green, 0)
        XCTAssertEqual(reply.colors[1].green, 0xAAAA)
        // Unknown pixel (9999) resolves to black.
        XCTAssertEqual(reply.colors[2].red, 0)
        XCTAssertEqual(reply.colors[2].green, 0)
        XCTAssertEqual(reply.colors[2].blue, 0)
    }
}
