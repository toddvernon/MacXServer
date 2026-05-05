import XCTest
@testable import Framer

final class SetupRequestTests: XCTestCase {

    // 12-byte header, no auth.
    private let emptyAuthLSB: [UInt8] = [
        0x6C, 0x00,             // 'l', unused
        0x0B, 0x00,             // protocol-major = 11 (LSB)
        0x00, 0x00,             // protocol-minor = 0
        0x00, 0x00,             // auth name length = 0
        0x00, 0x00,             // auth data length = 0
        0x00, 0x00,             // unused
    ]

    private let emptyAuthMSB: [UInt8] = [
        0x42, 0x00,             // 'B', unused
        0x00, 0x0B,             // protocol-major = 11 (MSB)
        0x00, 0x00,             // protocol-minor = 0
        0x00, 0x00,             // auth name length = 0
        0x00, 0x00,             // auth data length = 0
        0x00, 0x00,             // unused
    ]

    // 12-byte header + "MIT-MAGIC-COOKIE-1" (18 bytes, padded to 20) + 16 bytes cookie.
    private let cookieLSB: [UInt8] = [
        0x6C, 0x00,
        0x0B, 0x00,
        0x00, 0x00,
        0x12, 0x00,             // auth name length = 18
        0x10, 0x00,             // auth data length = 16
        0x00, 0x00,
        // "MIT-MAGIC-COOKIE-1"
        0x4D, 0x49, 0x54, 0x2D, 0x4D, 0x41, 0x47, 0x49,
        0x43, 0x2D, 0x43, 0x4F, 0x4F, 0x4B, 0x49, 0x45,
        0x2D, 0x31,
        0x00, 0x00,             // pad to 4-byte boundary (xPad(18) = 2)
        // 16 bytes of cookie data
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    ]

    func testEncodeEmptyAuthLSB() {
        let req = SetupRequest(byteOrder: .lsbFirst)
        XCTAssertEqual(req.encode(), emptyAuthLSB)
    }

    func testEncodeEmptyAuthMSB() {
        let req = SetupRequest(byteOrder: .msbFirst)
        XCTAssertEqual(req.encode(), emptyAuthMSB)
    }

    func testDecodeEmptyAuthLSB() throws {
        let req = try SetupRequest.decode(from: emptyAuthLSB)
        XCTAssertEqual(req.byteOrder, .lsbFirst)
        XCTAssertEqual(req.protocolMajor, 11)
        XCTAssertEqual(req.protocolMinor, 0)
        XCTAssertEqual(req.authProtocolName, [])
        XCTAssertEqual(req.authProtocolData, [])
    }

    func testDecodeEmptyAuthMSB() throws {
        let req = try SetupRequest.decode(from: emptyAuthMSB)
        XCTAssertEqual(req.byteOrder, .msbFirst)
        XCTAssertEqual(req.protocolMajor, 11)
        XCTAssertEqual(req.protocolMinor, 0)
    }

    func testEncodeWithCookie() {
        let cookie: [UInt8] = (0..<16).map { UInt8($0) }
        let req = SetupRequest(
            byteOrder: .lsbFirst,
            authProtocolName: Array("MIT-MAGIC-COOKIE-1".utf8),
            authProtocolData: cookie
        )
        XCTAssertEqual(req.encode(), cookieLSB)
    }

    func testDecodeWithCookie() throws {
        let req = try SetupRequest.decode(from: cookieLSB)
        XCTAssertEqual(req.byteOrder, .lsbFirst)
        XCTAssertEqual(req.protocolMajor, 11)
        XCTAssertEqual(req.protocolMinor, 0)
        XCTAssertEqual(String(decoding: req.authProtocolName, as: UTF8.self), "MIT-MAGIC-COOKIE-1")
        XCTAssertEqual(req.authProtocolData, (0..<16).map { UInt8($0) })
    }

    func testRoundTripEmptyAuthLSB() throws {
        let original = SetupRequest(byteOrder: .lsbFirst)
        let bytes = original.encode()
        let decoded = try SetupRequest.decode(from: bytes)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(bytes, decoded.encode())
    }

    func testRoundTripEmptyAuthMSB() throws {
        let original = SetupRequest(byteOrder: .msbFirst)
        let bytes = original.encode()
        let decoded = try SetupRequest.decode(from: bytes)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(bytes, decoded.encode())
    }

    func testRoundTripWithCookie() throws {
        let original = SetupRequest(
            byteOrder: .msbFirst,
            authProtocolName: Array("MIT-MAGIC-COOKIE-1".utf8),
            authProtocolData: (0..<16).map { UInt8($0) }
        )
        let bytes = original.encode()
        let decoded = try SetupRequest.decode(from: bytes)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(bytes, decoded.encode())
    }

    func testRoundTripOddLengthAuthName() throws {
        let original = SetupRequest(
            byteOrder: .lsbFirst,
            authProtocolName: Array("ABC".utf8),
            authProtocolData: Array("XY".utf8)
        )
        let bytes = original.encode()
        let decoded = try SetupRequest.decode(from: bytes)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(bytes, decoded.encode())
        XCTAssertEqual(bytes.count % 4, 0)
    }

    func testDecodeRejectsInvalidByteOrder() {
        let bad: [UInt8] = [0x5A, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try SetupRequest.decode(from: bad)) { error in
            XCTAssertEqual(error as? FramerError, .invalidByteOrder(0x5A))
        }
    }

    func testDecodeRejectsTruncated() {
        let short: [UInt8] = [0x6C, 0x00, 0x0B]
        XCTAssertThrowsError(try SetupRequest.decode(from: short))
    }
}
