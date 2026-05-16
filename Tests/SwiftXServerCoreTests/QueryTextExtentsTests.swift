import XCTest
@testable import SwiftXServerCore
import Framer

// QueryTextExtents handler. Shipped 2026-05-15 to fix the Motif
// CascadeButton "menu titles spaced strangely" bug Todd reported on
// quickplot — Motif uses this to measure menu-title widths during
// XmRowColumn layout, and pre-fix the BadRequest fallback produced
// nonsense widths.

final class QueryTextExtentsTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst) -> ServerSession {
        let s = ServerSession()
        _ = s.feed(SetupRequest(byteOrder: byteOrder).encode())
        _ = s.outbound.drain()
        return s
    }

    /// Open a font and return the fid. Uses the fixed alias which we
    /// always resolve to a Monaco substitute.
    private func openFont(_ s: ServerSession, alias: String = "fixed") -> UInt32 {
        let fid: UInt32 = ServerConfig.default.resourceIdBase + 0x1000
        let nameBytes = Array(alias.utf8)
        _ = s.feed(Request.openFont(OpenFont(
            fid: fid, name: nameBytes
        )).encode(byteOrder: .lsbFirst))
        _ = s.outbound.drain()
        return fid
    }

    /// CHAR2B-encode an ASCII string. Each char becomes (0x00, byte).
    private func char2b(_ ascii: String) -> [UInt8] {
        var out: [UInt8] = []
        for byte in ascii.utf8 {
            out.append(0)        // high byte
            out.append(byte)     // low byte
        }
        return out
    }

    func testUnknownFontEmitsBadFont() throws {
        let s = runningSession()
        let req = Request.queryTextExtents(QueryTextExtents(
            fid: 0xDEADBEEF, stringBytes: char2b("File")
        ))
        let bytes = s.feed(req.encode(byteOrder: .lsbFirst))
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected BadFont, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, XErrorCode.font.rawValue)
        XCTAssertEqual(err.majorOpcode, QueryTextExtents.opcode)
    }

    func testKnownFontASCIIReturnsExpectedWidth() throws {
        // "File" is 4 chars. Width = 4 * cellWidth of the resolved font.
        // The exact cellWidth depends on the font substitution (Monaco
        // at the resolved point size) — verify it's positive and a
        // multiple of the character count, which is the load-bearing
        // property for Motif's layout math.
        let s = runningSession()
        let fid = openFont(s)
        let bytes = s.feed(Request.queryTextExtents(QueryTextExtents(
            fid: fid, stringBytes: char2b("File")
        )).encode(byteOrder: .lsbFirst))

        XCTAssertEqual(bytes.count, 32, "QueryTextExtents reply is 32 bytes")
        let reply = try QueryTextExtentsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertGreaterThan(reply.overallWidth, 0)
        XCTAssertEqual(reply.overallWidth % 4, 0,
                       "overall width must be a multiple of nChars (4)")
        XCTAssertEqual(reply.overallLeft, 0, "monospace left bearing is 0")
        XCTAssertEqual(reply.overallRight, reply.overallWidth,
                       "monospace right bearing equals overallWidth")
        XCTAssertGreaterThan(reply.fontAscent, 0)
        XCTAssertGreaterThan(reply.fontDescent, 0)
        XCTAssertEqual(reply.overallAscent, reply.fontAscent,
                       "no per-glyph ascent variation in monospace")
        XCTAssertEqual(reply.overallDescent, reply.fontDescent)
        XCTAssertEqual(reply.drawDirection, 0, "LeftToRight")
    }

    func testEmptyStringReturnsZeroWidth() throws {
        let s = runningSession()
        let fid = openFont(s)
        let bytes = s.feed(Request.queryTextExtents(QueryTextExtents(
            fid: fid, stringBytes: []
        )).encode(byteOrder: .lsbFirst))

        let reply = try QueryTextExtentsReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(reply.overallWidth, 0)
        XCTAssertEqual(reply.overallLeft, 0)
        XCTAssertEqual(reply.overallRight, 0)
        // Font metrics still populated even for an empty string.
        XCTAssertGreaterThan(reply.fontAscent, 0)
    }

    func testOddLengthStringPadAndDecodeRoundTrip() throws {
        // 3-char string → 6 bytes CHAR2B → needs 2 bytes of trailing
        // padding to reach the 4-byte boundary AND oddLength=1.
        // Encoding should pad; decoding should trim the padding back off.
        let original = QueryTextExtents(fid: 0xABCD, stringBytes: char2b("Foo"))
        XCTAssertEqual(original.stringBytes.count, 6)
        let encoded = original.encode(byteOrder: .lsbFirst)
        // Total bytes: 4 header + 4 fid + 8 body (6 string + 2 pad) = 16.
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(encoded[1], 1, "oddLength flag set in pad byte")
        let decoded = try QueryTextExtents.decode(from: encoded, byteOrder: .lsbFirst)
        XCTAssertEqual(decoded.fid, 0xABCD)
        XCTAssertEqual(decoded.stringBytes.count, 6, "decoder trimmed the 2 pad bytes")
        XCTAssertEqual(decoded.stringBytes, original.stringBytes)
    }

    func testEvenLengthStringRoundTrip() throws {
        // 4-char string → 8 bytes CHAR2B → no trailing pad, oddLength=0.
        let original = QueryTextExtents(fid: 0xABCD, stringBytes: char2b("File"))
        let encoded = original.encode(byteOrder: .lsbFirst)
        XCTAssertEqual(encoded.count, 16, "4 header + 4 fid + 8 string = 16")
        XCTAssertEqual(encoded[1], 0, "oddLength flag clear")
        let decoded = try QueryTextExtents.decode(from: encoded, byteOrder: .lsbFirst)
        XCTAssertEqual(decoded.stringBytes, original.stringBytes)
    }

    func testHelveticaWidthIsProportional() throws {
        // The bug Todd hit: Motif's CascadeButton uses QueryTextExtents
        // to lay out menu titles in a font like
        // "-adobe-helvetica-medium-o-*-*-12-*-*-*-*-*-*-*". For proportional
        // fonts, width('M') > width('i') > width('l'). Pre-fix we returned
        // nChars × cellWidth — "as if every glyph was 'M'" — and Motif
        // allocated too much space, producing strangely-spaced titles.
        // Now we use Core Text actual advances; widths track real glyph
        // dimensions.
        let s = runningSession()
        let helvetica = "-adobe-helvetica-medium-o-*-*-12-*-*-*-*-*-*-*"
        let fid = openFont(s, alias: helvetica)

        func widthFor(_ str: String) throws -> Int32 {
            let bytes = s.feed(Request.queryTextExtents(QueryTextExtents(
                fid: fid, stringBytes: char2b(str)
            )).encode(byteOrder: .lsbFirst))
            return try QueryTextExtentsReply.decode(from: bytes, byteOrder: .lsbFirst).overallWidth
        }
        let widthM = try widthFor("M")
        let widthI = try widthFor("i")
        XCTAssertGreaterThan(widthM, widthI,
                             "Helvetica is proportional: width('M') must exceed width('i')")

        // Spec-honest: width("Mi") should equal width("M") + width("i") to
        // within ±1 (rounding). This is the load-bearing property — Motif
        // sums per-glyph widths to lay out menu titles, and our advance
        // reporting must match what PolyText8 actually draws.
        let widthMi = try widthFor("Mi")
        XCTAssertEqual(Int(widthMi), Int(widthM + widthI), accuracy: 1,
                       "additive width: width('Mi') ≈ width('M') + width('i')")
    }

    func testWidthScalesLinearlyWithStringLength() throws {
        // Crucial for Motif menu-bar layout: a 6-char title must report
        // 6/4 the width of a 4-char title. (Same font, monospace.)
        let s = runningSession()
        let fid = openFont(s)

        func widthFor(_ str: String) throws -> Int32 {
            let bytes = s.feed(Request.queryTextExtents(QueryTextExtents(
                fid: fid, stringBytes: char2b(str)
            )).encode(byteOrder: .lsbFirst))
            return try QueryTextExtentsReply.decode(from: bytes, byteOrder: .lsbFirst).overallWidth
        }
        let w4 = try widthFor("File")
        let w8 = try widthFor("FileEdit")
        XCTAssertEqual(w8, w4 * 2, "8-char width must be exactly 2× 4-char width (monospace)")
    }
}
