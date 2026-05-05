import XCTest
@testable import Framer

final class QueryFontReplyTests: XCTestCase {

    private func makeBareReply() -> QueryFontReply {
        QueryFontReply(
            sequenceNumber: 7,
            minBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8, characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            maxBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8, characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            minCharOrByte2: 32, maxCharOrByte2: 126, defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: true,
            fontAscent: 12, fontDescent: 3,
            properties: [],
            charInfos: []
        )
    }

    func testEmptyRoundTrip() throws {
        let original = makeBareReply()
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            XCTAssertEqual(bytes.count, 60)         // 7 4-byte units after the 8-byte std header = 28 + 8 + 24 fixed body = 60
            let decoded = try QueryFontReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testRoundTripWithProperties() throws {
        let original = QueryFontReply(
            sequenceNumber: 7,
            minBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8, characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            maxBounds: CharInfo(leftSideBearing: 0, rightSideBearing: 8, characterWidth: 8, ascent: 12, descent: 3, attributes: 0),
            minCharOrByte2: 32, maxCharOrByte2: 126, defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: true,
            fontAscent: 12, fontDescent: 3,
            properties: [
                FontProp(name: 63, value: 0xABCD),    // FONT_NAME → atom value
                FontProp(name: 64, value: 0xDEF0),    // FAMILY_NAME
            ],
            charInfos: []
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            XCTAssertEqual(bytes.count, 60 + 16)
            let decoded = try QueryFontReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testRoundTripWithCharInfos() throws {
        let glyphs = (0..<96).map { i in
            CharInfo(
                leftSideBearing: 0, rightSideBearing: 8,
                characterWidth: 8, ascent: 12, descent: 3,
                attributes: UInt16(i)
            )
        }
        let original = QueryFontReply(
            sequenceNumber: 7,
            minBounds: glyphs[0], maxBounds: glyphs.last!,
            minCharOrByte2: 32, maxCharOrByte2: 127, defaultChar: 32,
            drawDirection: .leftToRight,
            minByte1: 0, maxByte1: 0, allCharsExist: true,
            fontAscent: 12, fontDescent: 3,
            properties: [],
            charInfos: glyphs
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            XCTAssertEqual(bytes.count, 60 + 12 * 96)
            let decoded = try QueryFontReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }

    func testPredefinedAtomNames() {
        XCTAssertEqual(predefinedAtomName(1), "PRIMARY")
        XCTAssertEqual(predefinedAtomName(18), "FONT")
        XCTAssertEqual(predefinedAtomName(39), "WM_NAME")
        XCTAssertEqual(predefinedAtomName(63), "FONT_NAME")
        XCTAssertEqual(predefinedAtomName(67), "WM_CLASS")
        XCTAssertEqual(predefinedAtomName(68), "WM_TRANSIENT_FOR")
        XCTAssertNil(predefinedAtomName(0))
        XCTAssertNil(predefinedAtomName(69))
        XCTAssertNil(predefinedAtomName(0x130))
    }
}
