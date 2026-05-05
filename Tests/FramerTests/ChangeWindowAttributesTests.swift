import XCTest
@testable import Framer

final class ChangeWindowAttributesTests: XCTestCase {

    // ChangeWindowAttributes setting just event-mask (bit 11 = 0x800).
    // value-mask=0x800, popcount=1, so valueList=4 bytes. lenIn4 = 3 + 1 = 4 → 16 bytes total.
    private let cwaEventMaskLSB: [UInt8] = [
        0x02, 0x00, 0x04, 0x00,             // opcode=2, unused, lenIn4=4
        0x05, 0x00, 0x00, 0x10,             // window=0x10000005
        0x00, 0x08, 0x00, 0x00,             // valueMask = 0x00000800
        0x05, 0x00, 0x00, 0x00,             // event-mask CARD32 = KeyPress|ButtonPress (just example bits)
    ]

    func testEncodeNoValuesRoundTrip() throws {
        let original = ChangeWindowAttributes(window: 0x10000005, valueMask: 0)
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ChangeWindowAttributes.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
            XCTAssertEqual(bytes.count, 12)
        }
    }

    func testEncodeWithEventMask() {
        let req = ChangeWindowAttributes(
            window: 0x10000005,
            valueMask: 0x800,
            valueList: [0x05, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(req.encode(byteOrder: .lsbFirst), cwaEventMaskLSB)
    }

    func testDecodeWithEventMask() throws {
        let req = try ChangeWindowAttributes.decode(from: cwaEventMaskLSB, byteOrder: .lsbFirst)
        XCTAssertEqual(req.window, 0x10000005)
        XCTAssertEqual(req.valueMask, 0x800)
        XCTAssertEqual(req.valueList, [0x05, 0x00, 0x00, 0x00])
    }

    func testRequestDispatch() throws {
        let req = try Request.decode(from: cwaEventMaskLSB, byteOrder: .lsbFirst)
        guard case .changeWindowAttributes(let cwa) = req else {
            XCTFail("expected changeWindowAttributes")
            return
        }
        XCTAssertEqual(cwa.window, 0x10000005)
    }

    func testMultipleValuesRoundTrip() throws {
        // bits 0, 1, 4 set = 0x13, popcount=3, valueList=12 bytes
        let valueList: [UInt8] = [
            0x00, 0x00, 0x00, 0x10,         // background-pixmap
            0x00, 0xFF, 0xFF, 0xFF,         // background-pixel
            0x00, 0x00, 0x00, 0x01,         // bit-gravity
        ]
        let original = ChangeWindowAttributes(
            window: 0xDEADBEEF,
            valueMask: 0x13,
            valueList: valueList
        )
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = original.encode(byteOrder: order)
            let decoded = try ChangeWindowAttributes.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, decoded.encode(byteOrder: order))
        }
    }
}
