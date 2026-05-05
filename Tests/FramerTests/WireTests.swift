import XCTest
@testable import Framer

final class WireTests: XCTestCase {
    func testPadding() {
        XCTAssertEqual(xPad(0), 0)
        XCTAssertEqual(xPad(1), 3)
        XCTAssertEqual(xPad(2), 2)
        XCTAssertEqual(xPad(3), 1)
        XCTAssertEqual(xPad(4), 0)
        XCTAssertEqual(xPad(5), 3)
        XCTAssertEqual(xPad(11), 1)
        XCTAssertEqual(xPad(16), 0)
    }

    func testReadUInt16LSB() throws {
        var r = ByteReader(bytes: [0x34, 0x12], byteOrder: .lsbFirst)
        XCTAssertEqual(try r.readUInt16(), 0x1234)
    }

    func testReadUInt16MSB() throws {
        var r = ByteReader(bytes: [0x12, 0x34], byteOrder: .msbFirst)
        XCTAssertEqual(try r.readUInt16(), 0x1234)
    }

    func testReadUInt32LSB() throws {
        var r = ByteReader(bytes: [0x78, 0x56, 0x34, 0x12], byteOrder: .lsbFirst)
        XCTAssertEqual(try r.readUInt32(), 0x12345678)
    }

    func testReadUInt32MSB() throws {
        var r = ByteReader(bytes: [0x12, 0x34, 0x56, 0x78], byteOrder: .msbFirst)
        XCTAssertEqual(try r.readUInt32(), 0x12345678)
    }

    func testReadBytesAdvancesOffset() throws {
        var r = ByteReader(bytes: [0x01, 0x02, 0x03, 0x04], byteOrder: .lsbFirst)
        XCTAssertEqual(try r.readBytes(2), [0x01, 0x02])
        XCTAssertEqual(r.offset, 2)
        XCTAssertEqual(r.remaining, 2)
    }

    func testReadTruncated() {
        var r = ByteReader(bytes: [0x01], byteOrder: .lsbFirst)
        XCTAssertThrowsError(try r.readUInt16()) { error in
            XCTAssertEqual(error as? FramerError, .truncated(needed: 2, available: 1))
        }
    }

    func testWriteUInt16LSB() {
        var w = ByteWriter(byteOrder: .lsbFirst)
        w.writeUInt16(0x1234)
        XCTAssertEqual(w.bytes, [0x34, 0x12])
    }

    func testWriteUInt16MSB() {
        var w = ByteWriter(byteOrder: .msbFirst)
        w.writeUInt16(0x1234)
        XCTAssertEqual(w.bytes, [0x12, 0x34])
    }

    func testWriteUInt32LSB() {
        var w = ByteWriter(byteOrder: .lsbFirst)
        w.writeUInt32(0x12345678)
        XCTAssertEqual(w.bytes, [0x78, 0x56, 0x34, 0x12])
    }

    func testWriteUInt32MSB() {
        var w = ByteWriter(byteOrder: .msbFirst)
        w.writeUInt32(0x12345678)
        XCTAssertEqual(w.bytes, [0x12, 0x34, 0x56, 0x78])
    }

    func testWritePadding() {
        var w = ByteWriter(byteOrder: .lsbFirst)
        w.writeUInt8(0xAB)
        w.writePadding(3)
        XCTAssertEqual(w.bytes, [0xAB, 0x00, 0x00, 0x00])
    }

    func testReadWriteRoundtripUInt16() throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            for value: UInt16 in [0, 1, 0xFF, 0x100, 0xABCD, 0xFFFF] {
                var w = ByteWriter(byteOrder: order)
                w.writeUInt16(value)
                var r = ByteReader(bytes: w.bytes, byteOrder: order)
                XCTAssertEqual(try r.readUInt16(), value, "order=\(order) value=\(value)")
            }
        }
    }

    func testReadWriteRoundtripUInt32() throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            for value: UInt32 in [0, 1, 0xFFFF, 0x10000, 0xDEADBEEF, 0xFFFFFFFF] {
                var w = ByteWriter(byteOrder: order)
                w.writeUInt32(value)
                var r = ByteReader(bytes: w.bytes, byteOrder: order)
                XCTAssertEqual(try r.readUInt32(), value, "order=\(order) value=\(value)")
            }
        }
    }
}
