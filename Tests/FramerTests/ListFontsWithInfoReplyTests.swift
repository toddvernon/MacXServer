import XCTest
@testable import Framer

final class ListFontsWithInfoReplyTests: XCTestCase {

    private func makeBareReply(name: [UInt8] = Array("fixed".utf8)) -> ListFontsWithInfoReply {
        ListFontsWithInfoReply(
            sequenceNumber: 7,
            name: name,
            minBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8,
                                characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            maxBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8,
                                characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            minCharOrByte2: 32, maxCharOrByte2: 126, defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: true,
            fontAscent: 12, fontDescent: 3,
            repliesHint: 0,
            properties: []
        )
    }

    // MARK: - Encode invariants

    func testNameLengthAtByte1() {
        let r = makeBareReply(name: Array("xterm".utf8))
        let bytes = r.encode(byteOrder: .lsbFirst)
        XCTAssertEqual(bytes[0], 1)              // reply marker
        XCTAssertEqual(bytes[1], 5)              // "xterm".count
    }

    func testTerminatorHasNameLengthZero() {
        let term = ListFontsWithInfoReply.terminator(sequenceNumber: 42)
        let bytes = term.encode(byteOrder: .lsbFirst)
        XCTAssertEqual(bytes[0], 1)
        XCTAssertEqual(bytes[1], 0)              // name-length = 0 = terminator
        XCTAssertEqual(bytes.count, 60)          // fixed body, no name/props/padding
    }

    func testEncodeSizeWithoutPropertiesOrPadding() {
        // 5-byte name → no padding (5 + 3 = pad to 4 = 3 bytes pad → wait,
        // pad(5) is 3 since 5+3=8 is a multiple of 4). Encode size:
        // 60 fixed + 0 props + 5 name + 3 pad = 68.
        let r = makeBareReply(name: Array("fixed".utf8))     // 5 bytes
        let bytes = r.encode(byteOrder: .lsbFirst)
        XCTAssertEqual(bytes.count, 60 + 5 + 3)
    }

    func testEncodeSizeWithPaddedName() {
        // 4-byte name → pad(4) = 0. 60 + 4 = 64.
        let r = makeBareReply(name: Array("9x15".utf8))
        let bytes = r.encode(byteOrder: .lsbFirst)
        XCTAssertEqual(bytes.count, 60 + 4)
    }

    // MARK: - Round trip

    func testEmptyPropsRoundTrip() throws {
        let original = makeBareReply()
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ListFontsWithInfoReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testRoundTripWithProperties() throws {
        let original = ListFontsWithInfoReply(
            sequenceNumber: 11,
            name: Array("-adobe-helvetica-medium-r-normal--12-*-*-*-*-*-iso8859-1".utf8),
            minBounds: CharInfo(leftSideBearing: -2, rightSideBearing: 7,
                                characterWidth: 3, ascent: 9, descent: 2, attributes: 0),
            maxBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 13,
                                characterWidth: 14, ascent: 12, descent: 3, attributes: 0),
            minCharOrByte2: 32, maxCharOrByte2: 255, defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: false,
            fontAscent: 12, fontDescent: 3,
            repliesHint: 4,
            properties: [
                FontProp(name: 63, value: 12),
                FontProp(name: 64, value: 3),
                FontProp(name: 65, value: 65),
            ]
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ListFontsWithInfoReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testRoundTripPreservesRepliesHint() throws {
        let original = makeBareReply()
        var withHint = original
        withHint.repliesHint = 42
        let bytes = withHint.encode(byteOrder: .lsbFirst)
        let decoded = try ListFontsWithInfoReply.decode(from: bytes, byteOrder: .lsbFirst)
        XCTAssertEqual(decoded.repliesHint, 42)
    }

    func testTerminatorRoundTrip() throws {
        let term = ListFontsWithInfoReply.terminator(sequenceNumber: 99)
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = term.encode(byteOrder: order)
            let decoded = try ListFontsWithInfoReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(term, decoded)
            XCTAssertTrue(decoded.name.isEmpty)
        }
    }

    // MARK: - Request decode

    func testRequestRoundTrip() throws {
        let original = ListFontsWithInfo(maxNames: 50, pattern: Array("*helvetica*".utf8))
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            XCTAssertEqual(bytes[0], 50)         // opcode
            let decoded = try ListFontsWithInfo.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
        }
    }
}
