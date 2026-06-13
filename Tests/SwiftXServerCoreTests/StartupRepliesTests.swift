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

    func testListFontsEchoesXLFDPatternWithConcreteCharset() throws {
        // Echo-fallback path (added 2026-05-17): when the synth list has
        // no match AND the pattern is XLFD-shaped with a concrete
        // CHARSET_REGISTRY-CHARSET_ENCODING suffix, ListFonts returns the
        // pattern itself as a single match. Required by Motif's
        // XCreateFontSet — its check_charset (omGeneric.c:91-114) does
        // suffix-compare against the returned name, so an iso8859-1
        // probe needs at least one returned name ending in iso8859-1.
        // Pattern below has a -dt-interface family we don't synthesize.
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        let pattern = "-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-iso8859-1"
        let req = ListFonts(maxNames: 1, pattern: Array(pattern.utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let reply = try ListFontsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.names.count, 1, "echo-fallback must return one match")
        XCTAssertEqual(String(decoding: reply.names[0], as: UTF8.self), pattern,
                       "echoed name must equal the requested pattern")
    }

    func testListFontsDoesNotEchoWildcardCharsetPattern() throws {
        // Echo is gated by "concrete charset suffix" — wildcard charset
        // (the typical xfontsel-style enumeration probe) returns nothing
        // for an unknown family pattern, NOT the pattern itself. This
        // keeps the synth list the source of truth for honest enumerators.
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()

        // -dt-interface family we don't synthesize + wildcard charset.
        let pattern = "-dt-interface system-medium-r-normal-s*-*-*-*-*-*-*-*-*"
        let req = ListFonts(maxNames: 10, pattern: Array(pattern.utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))
        let reply = try ListFontsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.names.count, 0,
                       "wildcard-charset pattern must not echo — preserves enumerator honesty")
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
        // Allocate two colors. Under TrueColor (since 2026-06-13) AllocColor
        // packs RGB into a 24-bit pixel directly; the "allocation" is
        // degenerate. red 0xFFFF → pixel 0x00FF0000; green 0xAAAA → pixel
        // 0x0000AA00.
        _ = session.feed(AllocColor(cmap: 0x21, red: 0xFFFF, green: 0, blue: 0)
            .encode(byteOrder: .lsbFirst))
        _ = session.feed(AllocColor(cmap: 0x21, red: 0, green: 0xAAAA, blue: 0)
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // QueryColors with the packed pixel values, plus a third arbitrary
        // pixel (0x123456) — under TrueColor every 24-bit pixel value is
        // valid and unpacks to RGB. No "unknown pixel → black" fallback.
        let req = QueryColors(cmap: 0x21, pixels: [0x00FF0000, 0x0000AA00, 0x00123456])
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let reply = try QueryColorsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.colors.count, 3)
        // Red allocation: unpack 0xFF<<16 → R=0xFFFF (high byte 0xFF
        // broadcast to 16 bits via *257), G=0, B=0.
        XCTAssertEqual(reply.colors[0].red, 0xFFFF)
        XCTAssertEqual(reply.colors[0].green, 0)
        // Green allocation: 0xAA in green channel → 0xAA*257 = 0xAAAA.
        XCTAssertEqual(reply.colors[1].green, 0xAAAA)
        // Arbitrary pixel 0x123456 unpacks losslessly: R=0x12*257=0x1212,
        // G=0x34*257=0x3434, B=0x56*257=0x5656.
        XCTAssertEqual(reply.colors[2].red,   0x1212)
        XCTAssertEqual(reply.colors[2].green, 0x3434)
        XCTAssertEqual(reply.colors[2].blue,  0x5656)
    }
}
