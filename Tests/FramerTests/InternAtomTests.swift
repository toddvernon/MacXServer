import XCTest
@testable import Framer

final class InternAtomTests: XCTestCase {

    // InternAtom request, MSB, name="WM_PROTOCOLS" (12 bytes), onlyIfExists=false.
    // 4 bytes header + 4 bytes (nameLen + 2 unused) + 12 bytes name + 0 padding = 20 bytes
    private let internWMProtocolsMSB: [UInt8] = [
        0x10, 0x00, 0x00, 0x05,             // opcode=16, onlyIfExists=0, lenIn4=5
        0x00, 0x0C, 0x00, 0x00,             // nameLen=12, unused
        0x57, 0x4D, 0x5F, 0x50,             // "WM_P"
        0x52, 0x4F, 0x54, 0x4F,             // "ROTO"
        0x43, 0x4F, 0x4C, 0x53,             // "COLS"
    ]

    // InternAtomReply, sequence=42, atom=0x47, MSB.
    private let internAtomReplyMSB: [UInt8] = [
        0x01, 0x00,                         // marker=1, unused
        0x00, 0x2A,                         // sequence=42
        0x00, 0x00, 0x00, 0x00,             // additional length = 0
        0x00, 0x00, 0x00, 0x47,             // atom=0x47
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]

    func testInternAtomEncode() {
        let req = InternAtom(onlyIfExists: false, name: Array("WM_PROTOCOLS".utf8))
        XCTAssertEqual(req.encode(byteOrder: .msbFirst), internWMProtocolsMSB)
    }

    func testInternAtomDecode() throws {
        let req = try InternAtom.decode(from: internWMProtocolsMSB, byteOrder: .msbFirst)
        XCTAssertFalse(req.onlyIfExists)
        XCTAssertEqual(String(decoding: req.name, as: UTF8.self), "WM_PROTOCOLS")
    }

    func testInternAtomOnlyIfExistsRoundTrip() throws {
        let original = InternAtom(onlyIfExists: true, name: Array("ABCDE".utf8))
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try InternAtom.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
            XCTAssertEqual(bytes.count % 4, 0)
        }
    }

    func testInternAtomEmptyName() throws {
        let original = InternAtom(onlyIfExists: false, name: [])
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try InternAtom.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
        }
    }

    func testRequestDispatchInternAtom() throws {
        let req = try Request.decode(from: internWMProtocolsMSB, byteOrder: .msbFirst)
        guard case .internAtom(let ia) = req else {
            XCTFail("expected internAtom")
            return
        }
        XCTAssertEqual(String(decoding: ia.name, as: UTF8.self), "WM_PROTOCOLS")
    }

    func testInternAtomReplyEncode() {
        let reply = InternAtomReply(sequenceNumber: 42, atom: 0x47)
        XCTAssertEqual(reply.encode(byteOrder: .msbFirst), internAtomReplyMSB)
    }

    func testInternAtomReplyDecode() throws {
        let reply = try InternAtomReply.decode(from: internAtomReplyMSB, byteOrder: .msbFirst)
        XCTAssertEqual(reply.sequenceNumber, 42)
        XCTAssertEqual(reply.atom, 0x47)
    }

    func testInternAtomReplyNoneRoundTrip() throws {
        // atom=0 means "atom does not exist" (returned when onlyIfExists=true)
        let original = InternAtomReply(sequenceNumber: 100, atom: 0)
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try InternAtomReply.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes.count, 32)
        }
    }
}
