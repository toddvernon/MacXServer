import XCTest
@testable import Framer

/// Regression tests for CODE_AUDIT_2026-07 §0: a malformed value-list request
/// (length word disagreeing with the value-mask popcount, or a zero
/// per-keycode count) used to reach an initializer `precondition` and TRAP the
/// whole server process. Every value-list decoder must now THROW
/// `FramerError.malformedRequest` on that mismatch so the request-loop can emit
/// BadLength/BadValue and stay synchronized.
///
/// These tests hand-build byte buffers with a deliberately-wrong length word.
/// Before the fix they crashed the test process rather than failing — the
/// crash was the proof of the bug. They also confirm well-formed buffers still
/// decode, so the guard didn't over-reject.
final class MalformedValueListTests: XCTestCase {

    // A CreateGC with valueMask popcount = 1 but a length word claiming 0
    // value-list slots (lenIn4 = 4). Mask says one datum should follow; the
    // frame says none. Mismatch → throw, not trap.
    func testCreateGCMaskLengthMismatchThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(55)            // opcode
            w.writeUInt8(0)
            w.writeUInt16(4)            // lenIn4 = 4 → 0 value bytes
            w.writeUInt32(0x1234)       // cid
            w.writeUInt32(0x20)         // drawable
            w.writeUInt32(0x1)          // valueMask, popcount 1 (expects 1 slot)
            assertMalformed(w.bytes, order) { try CreateGC.decode(from: $0, byteOrder: $1) }
        }
    }

    // A ChangeGC with a length word SHORTER than the header (lenIn4 = 1),
    // which yields a negative value-list byte count. Must throw, not trap in
    // readBytes' range operator.
    func testChangeGCShortLengthThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(56)
            w.writeUInt8(0)
            w.writeUInt16(1)            // lenIn4 = 1 → (1-3)*4 = -8 bytes
            w.writeUInt32(0x1234)
            w.writeUInt32(0x0)
            assertMalformed(w.bytes, order) { try ChangeGC.decode(from: $0, byteOrder: $1) }
        }
    }

    func testCreateWindowMaskLengthMismatchThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(1)             // opcode
            w.writeUInt8(0)            // depth
            w.writeUInt16(8)           // lenIn4 = 8 → 0 value bytes
            w.writeUInt32(0x20)        // wid
            w.writeUInt32(0x10)        // parent
            w.writeUInt16(0); w.writeUInt16(0)      // x, y
            w.writeUInt16(100); w.writeUInt16(100)  // w, h
            w.writeUInt16(0)           // border
            w.writeUInt16(1)           // class = InputOutput
            w.writeUInt32(0)           // visual
            w.writeUInt32(0x3)         // valueMask popcount 2, but 0 slots framed
            assertMalformed(w.bytes, order) { try CreateWindow.decode(from: $0, byteOrder: $1) }
        }
    }

    func testChangeWindowAttributesMismatchThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(2)
            w.writeUInt8(0)
            w.writeUInt16(3)           // 0 value bytes
            w.writeUInt32(0x20)        // window
            w.writeUInt32(0x7)         // popcount 3, 0 framed
            assertMalformed(w.bytes, order) { try ChangeWindowAttributes.decode(from: $0, byteOrder: $1) }
        }
    }

    func testConfigureWindowMismatchThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(12)
            w.writeUInt8(0)
            w.writeUInt16(3)           // 0 value bytes
            w.writeUInt32(0x20)        // window
            w.writeUInt16(0x3)         // valueMask popcount 2, 0 framed
            w.writeUInt16(0)
            assertMalformed(w.bytes, order) { try ConfigureWindow.decode(from: $0, byteOrder: $1) }
        }
    }

    func testChangeKeyboardControlMismatchThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(102)
            w.writeUInt8(0)
            w.writeUInt16(2)           // 0 value bytes
            w.writeUInt32(0x1)         // popcount 1, 0 framed
            assertMalformed(w.bytes, order) { try ChangeKeyboardControl.decode(from: $0, byteOrder: $1) }
        }
    }

    // keysymsPerKeycode = 0 used to trap both the `> 0` precondition and the
    // modulo-by-zero in the count precondition.
    func testChangeKeyboardMappingZeroPerKeycodeThrows() {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            var w = ByteWriter(byteOrder: order)
            w.writeUInt8(100)
            w.writeUInt8(1)            // n = 1 keycode
            w.writeUInt16(2)
            w.writeUInt8(8)           // firstKeyCode
            w.writeUInt8(0)           // keysymsPerKeycode = 0  ← malformed
            w.writeUInt16(0)
            assertMalformed(w.bytes, order) { try ChangeKeyboardMapping.decode(from: $0, byteOrder: $1) }
        }
    }

    // Guard against over-rejection: a well-formed CreateGC (mask popcount 1,
    // one value slot framed) must still decode cleanly.
    func testWellFormedValueListStillDecodes() throws {
        let good = CreateGC(cid: 0x1234, drawable: 0x20, valueMask: 0x4,
                            valueList: [0, 0, 0, 2])
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = good.encode(byteOrder: order)
            let decoded = try CreateGC.decode(from: bytes, byteOrder: order)
            XCTAssertEqual(good, decoded)
        }
    }

    private func assertMalformed(_ bytes: [UInt8], _ order: ByteOrder,
                                 _ decode: ([UInt8], ByteOrder) throws -> Any,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(bytes, order), file: file, line: line) { err in
            guard case FramerError.malformedRequest = err else {
                XCTFail("expected .malformedRequest, got \(err)", file: file, line: line)
                return
            }
        }
    }
}
