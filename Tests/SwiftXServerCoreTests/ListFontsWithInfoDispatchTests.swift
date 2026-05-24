import XCTest
import Foundation
import Framer
@testable import SwiftXServerCore

// ListFontsWithInfo dispatch returns one reply per matching font plus
// a terminator reply with name-length = 0. xclock + xfontsel are the
// canonical consumers; before this opcode was implemented the server
// emitted BadRequest and xclock would exit ~41 requests in.

final class ListFontsWithInfoDispatchTests: XCTestCase {

    private func setupSession() -> ServerSession {
        let session = ServerSession()
        _ = session.feed(SetupRequest(byteOrder: .lsbFirst).encode())
        _ = session.outbound.drain()
        return session
    }

    /// Walk a buffer containing N back-to-back replies, advancing by
    /// each reply's own length (lenIn4 * 4 + 32 fixed header). Returns
    /// the per-reply byte slices in order.
    private func splitReplies(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var off = 0
        while off + 8 <= bytes.count {
            // bytes[off+4..off+8] is lenIn4 little-endian (sessions use
            // .lsbFirst in these tests).
            let lenIn4: UInt32 =
                UInt32(bytes[off + 4]) |
                (UInt32(bytes[off + 5]) << 8) |
                (UInt32(bytes[off + 6]) << 16) |
                (UInt32(bytes[off + 7]) << 24)
            let total = 32 + Int(lenIn4) * 4
            if off + total > bytes.count { break }
            out.append(Array(bytes[off..<off + total]))
            off += total
        }
        return out
    }

    // MARK: - Multi-reply emission

    func testEmitsOneReplyPerMatchPlusTerminator() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 100, pattern: Array("-apple-monaco*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        XCTAssertGreaterThan(chunks.count, 1, "expected matches + terminator")

        // All but the last reply must have non-zero name-length.
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThan(chunk[1], 0, "non-terminator reply must have name-length > 0")
        }
        // Last reply is the terminator (name-length == 0).
        XCTAssertEqual(chunks.last?[1], 0, "last reply must be the name-length=0 terminator")
    }

    func testMatchedNamesAppearInOrderAndAllStartWithPrefix() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 100, pattern: Array("-apple-monaco*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        var names: [String] = []
        for chunk in chunks.dropLast() {
            let reply = try ListFontsWithInfoReply.decode(from: chunk, byteOrder: .lsbFirst)
            names.append(String(decoding: reply.name, as: UTF8.self))
        }
        XCTAssertGreaterThan(names.count, 0)
        for name in names {
            XCTAssertTrue(name.hasPrefix("-apple-monaco"), "unexpected name \(name)")
        }
    }

    func testEachReplyCarriesValidFontMetrics() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 10, pattern: Array("fixed".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        XCTAssertEqual(chunks.count, 2, "one match (fixed) plus terminator")

        let match = try ListFontsWithInfoReply.decode(from: chunks[0], byteOrder: .lsbFirst)
        XCTAssertEqual(String(decoding: match.name, as: UTF8.self), "fixed")
        XCTAssertGreaterThan(match.fontAscent, 0)
        XCTAssertGreaterThan(match.fontDescent, 0)
        XCTAssertGreaterThan(match.maxBounds.characterWidth, 0)
        XCTAssertFalse(match.properties.isEmpty, "should carry FONTPROPS like FONT_ASCENT etc.")
    }

    func testRepliesHintCountsDownToZero() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 100, pattern: Array("-apple-monaco*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        let matches = chunks.dropLast()
        let n = matches.count
        XCTAssertGreaterThan(n, 1, "test relies on at least 2 matches")

        // Decode each non-terminator reply; hint should be n-i-1.
        for (i, chunk) in matches.enumerated() {
            let reply = try ListFontsWithInfoReply.decode(from: chunk, byteOrder: .lsbFirst)
            XCTAssertEqual(reply.repliesHint, UInt32(n - i - 1),
                           "reply \(i): expected hint=\(n - i - 1), got \(reply.repliesHint)")
        }
    }

    // MARK: - Empty / single / max

    func testNoMatchesStillEmitsTerminator() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 100,
                                    pattern: Array("definitely-no-such-font-xyzzy*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        XCTAssertEqual(chunks.count, 1, "no matches → just the terminator")
        XCTAssertEqual(chunks[0][1], 0)
    }

    func testMaxNamesIsRespected() throws {
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 3, pattern: Array("*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        XCTAssertEqual(chunks.count, 4, "3 matches + terminator")
        XCTAssertEqual(chunks.last?[1], 0)
    }

    func testReplySequenceNumberIsSameForAllRepliesInBatch() throws {
        // X11 spec: all replies in a single ListFontsWithInfo batch
        // share the request's sequence number.
        let session = setupSession()
        let req = ListFontsWithInfo(maxNames: 5, pattern: Array("-apple-monaco*".utf8))
        let bytes = session.feed(req.encode(byteOrder: .lsbFirst))

        let chunks = splitReplies(bytes)
        var firstSeq: UInt16?
        for chunk in chunks {
            let reply = try ListFontsWithInfoReply.decode(from: chunk, byteOrder: .lsbFirst)
            if firstSeq == nil { firstSeq = reply.sequenceNumber }
            XCTAssertEqual(reply.sequenceNumber, firstSeq)
        }
    }
}
