import XCTest
@testable import Framer

final class ServerMessageTests: XCTestCase {

    // 32-byte event with code 12 (Expose), MSB.
    private let exposeEventMSB: [UInt8] = [
        0x0C, 0x00,                       // code=Expose (12), detail=0
        0x12, 0x34,                       // sequence=0x1234
        0x00, 0x00, 0x00, 0x05,           // window
        0x00, 0x10, 0x00, 0x20,           // x=16, y=32
        0x00, 0x40, 0x00, 0x80,           // width=64, height=128
        0x00, 0x02,                       // count=2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    // 32-byte error: BadWindow, sequence=42, bad-resource=0x10000005
    private let badWindowMSB: [UInt8] = [
        0x00, 0x03,                       // marker=0, error code=BadWindow (3)
        0x00, 0x2A,                       // sequence=42
        0x10, 0x00, 0x00, 0x05,           // bad-resource
        0x00, 0x00,                       // minor opcode
        0x08,                             // major opcode (MapWindow)
        0x00,                             // unused
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]

    // Reply with no additional data (32 bytes), sequence=7, dataByte=0xAB.
    private let bareReplyMSB: [UInt8] = [
        0x01, 0xAB,                       // marker=1 (Reply), dataByte
        0x00, 0x07,                       // sequence=7
        0x00, 0x00, 0x00, 0x00,           // additional length = 0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    // Reply with 8 bytes additional data (40 bytes total), additional length = 2.
    private let replyWithExtraMSB: [UInt8] = [
        0x01, 0x00,
        0x00, 0x09,                       // sequence=9
        0x00, 0x00, 0x00, 0x02,           // additional length = 2 4-byte units
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xDE, 0xAD, 0xBE, 0xEF,
        0xCA, 0xFE, 0xBA, 0xBE,
    ]

    func testDecodeEvent() throws {
        let msg = try ServerMessage.decodeOne(from: exposeEventMSB, byteOrder: .msbFirst)
        guard case .event(let e) = msg else {
            XCTFail("expected event, got \(msg)")
            return
        }
        XCTAssertEqual(e.code, 12)
        XCTAssertFalse(e.sentEvent)
        XCTAssertEqual(e.sequenceNumber(byteOrder: .msbFirst), 0x1234)
        XCTAssertEqual(e.bytes.count, 32)
    }

    func testDecodeEventWithSendEventFlag() throws {
        var bytes = exposeEventMSB
        bytes[0] = 0x8C                   // 12 with high bit set
        let msg = try ServerMessage.decodeOne(from: bytes, byteOrder: .msbFirst)
        guard case .event(let e) = msg else {
            XCTFail("expected event")
            return
        }
        XCTAssertEqual(e.code, 12)
        XCTAssertTrue(e.sentEvent)
    }

    func testDecodeError() throws {
        let msg = try ServerMessage.decodeOne(from: badWindowMSB, byteOrder: .msbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected error, got \(msg)")
            return
        }
        XCTAssertEqual(err.errorCode, 3)
        XCTAssertEqual(err.sequenceNumber(byteOrder: .msbFirst), 42)
        XCTAssertEqual(err.badResourceId(byteOrder: .msbFirst), 0x10000005)
        XCTAssertEqual(err.majorOpcode, 8)
        XCTAssertEqual(err.bytes.count, 32)
    }

    func testDecodeBareReply() throws {
        let msg = try ServerMessage.decodeOne(from: bareReplyMSB, byteOrder: .msbFirst)
        guard case .reply(let r) = msg else {
            XCTFail("expected reply")
            return
        }
        XCTAssertEqual(r.dataByte, 0xAB)
        XCTAssertEqual(r.sequenceNumber(byteOrder: .msbFirst), 7)
        XCTAssertEqual(r.additionalLengthIn4(byteOrder: .msbFirst), 0)
        XCTAssertEqual(r.bytes.count, 32)
    }

    func testDecodeReplyWithAdditionalData() throws {
        let msg = try ServerMessage.decodeOne(from: replyWithExtraMSB, byteOrder: .msbFirst)
        guard case .reply(let r) = msg else {
            XCTFail("expected reply")
            return
        }
        XCTAssertEqual(r.additionalLengthIn4(byteOrder: .msbFirst), 2)
        XCTAssertEqual(r.bytes.count, 40)
        XCTAssertEqual(Array(r.bytes.suffix(8)), [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
    }

    func testDecodeStreamMultipleMessages() throws {
        var stream = bareReplyMSB + exposeEventMSB + badWindowMSB
        var messages: [ServerMessage] = []
        while !stream.isEmpty {
            let msg = try ServerMessage.decodeOne(from: stream, byteOrder: .msbFirst)
            messages.append(msg)
            stream.removeFirst(msg.bytes.count)
        }
        XCTAssertEqual(messages.count, 3)
        if case .reply = messages[0] {} else { XCTFail("expected reply at 0") }
        if case .event = messages[1] {} else { XCTFail("expected event at 1") }
        if case .xError = messages[2] {} else { XCTFail("expected error at 2") }
    }

    func testRejectsTruncated() {
        let short = Array(exposeEventMSB.prefix(20))
        XCTAssertThrowsError(try ServerMessage.decodeOne(from: short, byteOrder: .msbFirst))
    }

    func testEventNames() {
        XCTAssertEqual(eventName(2), "KeyPress")
        XCTAssertEqual(eventName(12), "Expose")
        XCTAssertEqual(eventName(28), "PropertyNotify")
        XCTAssertEqual(eventName(34), "MappingNotify")
        XCTAssertNil(eventName(0))
        XCTAssertNil(eventName(35))
        XCTAssertNil(eventName(100))
    }

    func testErrorNames() {
        XCTAssertEqual(errorName(1), "BadRequest")
        XCTAssertEqual(errorName(3), "BadWindow")
        XCTAssertEqual(errorName(17), "BadImplementation")
        XCTAssertNil(errorName(0))
        XCTAssertNil(errorName(18))
    }

    func testXErrorEncodeMatchesByteLayoutMSB() {
        // Re-derives the existing badWindowMSB literal via the encoder. If this
        // ever drifts, either the encoder is wrong or the spec interpretation
        // shifted; both warrant investigation.
        let encoded = XError.encode(
            code: .window,
            sequenceNumber: 42,
            badResourceId: 0x10000005,
            minorOpcode: 0,
            majorOpcode: 8,
            byteOrder: .msbFirst
        )
        XCTAssertEqual(encoded, badWindowMSB)
    }

    func testXErrorEncodeDecodeRoundTripBothByteOrders() throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            for code in [XErrorCode.request, .value, .window, .pixmap, .atom,
                         .cursor, .font, .match, .drawable, .access, .alloc,
                         .color, .gc, .idChoice, .name, .length, .implementation] {
                let encoded = XError.encode(
                    code: code,
                    sequenceNumber: 0xABCD,
                    badResourceId: 0xDEADBEEF,
                    minorOpcode: 0x1234,
                    majorOpcode: 99,
                    byteOrder: order
                )
                XCTAssertEqual(encoded.count, 32, "XError must be 32 bytes (code=\(code), order=\(order))")
                XCTAssertEqual(encoded[0], 0, "marker byte must be 0 (code=\(code))")

                let msg = try ServerMessage.decodeOne(from: encoded, byteOrder: order)
                guard case .xError(let err) = msg else {
                    XCTFail("expected xError after decode for code=\(code), order=\(order)")
                    continue
                }
                XCTAssertEqual(err.errorCode, code.rawValue)
                XCTAssertEqual(err.sequenceNumber(byteOrder: order), 0xABCD)
                XCTAssertEqual(err.badResourceId(byteOrder: order), 0xDEADBEEF)
                XCTAssertEqual(err.minorOpcode(byteOrder: order), 0x1234)
                XCTAssertEqual(err.majorOpcode, 99)
            }
        }
    }

    func testXErrorEncodeDefaultsToZeroForOptionalFields() throws {
        let encoded = XError.encode(
            code: .alloc,
            sequenceNumber: 1,
            majorOpcode: 1,
            byteOrder: .lsbFirst
        )
        let msg = try ServerMessage.decodeOne(from: encoded, byteOrder: .lsbFirst)
        guard case .xError(let err) = msg else {
            XCTFail("expected xError")
            return
        }
        XCTAssertEqual(err.badResourceId(byteOrder: .lsbFirst), 0)
        XCTAssertEqual(err.minorOpcode(byteOrder: .lsbFirst), 0)
    }
}
