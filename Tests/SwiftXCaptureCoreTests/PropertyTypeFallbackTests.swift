import XCTest
@testable import SwiftXCaptureCore
import Framer

// Type-driven property decode fallback: when the property name isn't in
// the WM_* / _MOTIF_* set, the dispatcher dispatches on the type atom
// instead. Covers CARDINAL / INTEGER lists, STRING / UTF8_STRING /
// COMPOUND_TEXT bodies, and resource-id lists (WINDOW, PIXMAP, etc.).

final class PropertyTypeFallbackTests: XCTestCase {

    private func u16(_ v: UInt16, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8(v >> 8)]
        case .msbFirst: return [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
    }
    private func u32(_ v: UInt32, _ bo: ByteOrder) -> [UInt8] {
        switch bo {
        case .lsbFirst: return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .msbFirst: return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }
    private func dispatch(name: String = "_NET_FAKE", type: String,
                          format: UInt8, data: [UInt8],
                          byteOrder: ByteOrder = .msbFirst,
                          ctx: ChronoContext = ChronoContext()) -> String? {
        decodeKnownWMProperty(propertyName: name, type: type, format: format,
                              data: data, byteOrder: byteOrder, ctx: ctx)
    }

    // MARK: - CARDINAL

    func testCARDINALFormat32SingleValue() {
        let bo: ByteOrder = .msbFirst
        XCTAssertEqual(dispatch(type: "CARDINAL", format: 32, data: u32(12345, bo), byteOrder: bo),
                       "cardinals=[12345]")
    }

    func testCARDINALFormat32MultipleValues() {
        let bo: ByteOrder = .lsbFirst
        let data = u32(1, bo) + u32(2, bo) + u32(42, bo)
        XCTAssertEqual(dispatch(type: "CARDINAL", format: 32, data: data, byteOrder: bo),
                       "cardinals=[1,2,42]")
    }

    func testCARDINALFormat16() {
        let bo: ByteOrder = .msbFirst
        let data = u16(7, bo) + u16(65535, bo)
        XCTAssertEqual(dispatch(type: "CARDINAL", format: 16, data: data, byteOrder: bo),
                       "cardinals=[7,65535]")
    }

    func testCARDINALListTruncates() {
        let bo: ByteOrder = .msbFirst
        var data: [UInt8] = []
        for i in 0..<12 { data += u32(UInt32(i), bo) }
        let s = dispatch(type: "CARDINAL", format: 32, data: data, byteOrder: bo)!
        XCTAssertTrue(s.contains("cardinals=[0,1,2,3,4,5,6,7,…(+4)]"), s)
    }

    // MARK: - INTEGER

    func testINTEGERSignedRendering() {
        let bo: ByteOrder = .msbFirst
        let neg = UInt32(bitPattern: -42)
        XCTAssertEqual(dispatch(type: "INTEGER", format: 32, data: u32(neg, bo), byteOrder: bo),
                       "ints=[-42]")
    }

    // MARK: - STRING / UTF8_STRING

    func testSTRINGShortRendersInline() {
        let data = Array("hello world".utf8)
        XCTAssertEqual(dispatch(type: "STRING", format: 8, data: data),
                       "value=\"hello world\"")
    }

    func testSTRINGNewlineEscaped() {
        let data = Array("line1\nline2".utf8)
        XCTAssertEqual(dispatch(type: "STRING", format: 8, data: data),
                       "value=\"line1\\nline2\"")
    }

    func testSTRINGControlCharsBecomeQuestionMark() {
        let data: [UInt8] = [0x01, 0x02, UInt8(ascii: "h"), UInt8(ascii: "i"), 0x03]
        XCTAssertEqual(dispatch(type: "STRING", format: 8, data: data),
                       "value=\"??hi?\"")
    }

    func testSTRINGLongTruncated() {
        let payload = String(repeating: "x", count: 250).utf8
        let data = Array(payload)
        let s = dispatch(type: "STRING", format: 8, data: data)!
        XCTAssertTrue(s.hasSuffix("(250 bytes)"), s)
        XCTAssertTrue(s.contains("…\""), s)
    }

    func testUTF8StringTreatedAsUTF8() {
        // Same shape as STRING but should decode multi-byte UTF-8 codepoints
        // (whereas STRING uses Latin-1 fallback).
        let data = Array("café".utf8)
        XCTAssertEqual(dispatch(type: "UTF8_STRING", format: 8, data: data),
                       "value=\"café\"")
    }

    // MARK: - Resource-id lists

    func testWINDOWList() {
        let bo: ByteOrder = .msbFirst
        let data = u32(0x100, bo) + u32(0x200, bo) + u32(0, bo)
        XCTAssertEqual(dispatch(type: "WINDOW", format: 32, data: data, byteOrder: bo),
                       "windows=[0x100,0x200,None]")
    }

    func testPIXMAPSingleResource() {
        let bo: ByteOrder = .lsbFirst
        XCTAssertEqual(dispatch(type: "PIXMAP", format: 32, data: u32(0x4400055, bo), byteOrder: bo),
                       "pixmaps=[0x4400055]")
    }

    // MARK: - Dispatcher behavior

    func testNamedPropertyWinsOverTypeFallback() {
        // WM_NORMAL_HINTS is a named decode; type STRING shouldn't reach it
        // because the name-driven case handles 32-bit body and rejects
        // format=8 explicitly. Result: nil so caller falls back to
        // previewBytes.
        XCTAssertNil(dispatch(name: "WM_NORMAL_HINTS", type: "STRING",
                              format: 8, data: Array("won't decode".utf8)))
    }

    func testUnknownTypeReturnsNil() {
        XCTAssertNil(dispatch(type: "VENDOR_PRIVATE_BLOB", format: 32,
                              data: [0, 0, 0, 0]))
    }

    func testEmptyDataSkipsTypeFallback() {
        XCTAssertNil(dispatch(type: "CARDINAL", format: 32, data: []))
    }
}
