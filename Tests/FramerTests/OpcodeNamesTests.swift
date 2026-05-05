import XCTest
@testable import Framer

final class OpcodeNamesTests: XCTestCase {
    func testKnownOpcodes() {
        XCTAssertEqual(opcodeName(1), "CreateWindow")
        XCTAssertEqual(opcodeName(8), "MapWindow")
        XCTAssertEqual(opcodeName(18), "ChangeProperty")
        XCTAssertEqual(opcodeName(20), "GetProperty")
        XCTAssertEqual(opcodeName(45), "OpenFont")
        XCTAssertEqual(opcodeName(55), "CreateGC")
        XCTAssertEqual(opcodeName(70), "PolyFillRectangle")
        XCTAssertEqual(opcodeName(76), "ImageText8")
        XCTAssertEqual(opcodeName(127), "NoOperation")
    }

    func testCoreOpcodeRangeCovered() {
        for op: UInt8 in 1...119 {
            XCTAssertNotNil(opcodeName(op), "core opcode \(op) has no name")
        }
    }

    func testUnassignedOpcodes() {
        for op: UInt8 in [0, 120, 121, 122, 123, 124, 125, 126] {
            XCTAssertNil(opcodeName(op), "opcode \(op) should be nil")
        }
    }

    func testExtensionRangeNotNamed() {
        // 128-255 are dynamically assigned to extensions at QueryExtension time;
        // the static table has no business naming them.
        XCTAssertNil(opcodeName(128))
        XCTAssertNil(opcodeName(200))
        XCTAssertNil(opcodeName(255))
    }
}
