import XCTest
@testable import Framer

// Round-trip + fixed-size coverage for the SHAPE extension wire types.
// SHAPE requests carry a dynamically-assigned major opcode, so encode takes
// it as a parameter (we use 128 here, the value the server hands out).

final class ShapeWireTests: XCTestCase {

    private let major: UInt8 = 128

    private func roundTripRequest<T: Equatable>(
        _ original: T,
        expectedSize: Int? = nil,
        encode: (T, UInt8, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, major, order)
            XCTAssertEqual(bytes.count % 4, 0, "request bytes must be 4-byte aligned (\(T.self))")
            if let n = expectedSize { XCTAssertEqual(bytes.count, n, "wrong wire size for \(T.self)") }
            XCTAssertEqual(bytes[0], major, "byte 0 should be the major opcode")
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "field equality fails for \(T.self) in \(order)")
            XCTAssertEqual(bytes, encode(decoded, major, order), "byte round-trip fails for \(T.self) in \(order)")
        }
    }

    private func roundTripReply<T: Equatable>(
        _ original: T,
        expectedSize: Int? = nil,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0, "reply bytes must be 4-byte aligned (\(T.self))")
            if let n = expectedSize { XCTAssertEqual(bytes.count, n, "wrong wire size for \(T.self)") }
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "field equality fails for \(T.self) in \(order)")
            XCTAssertEqual(bytes, encode(decoded, order), "byte round-trip fails for \(T.self) in \(order)")
        }
    }

    // MARK: - Requests

    func testQueryVersion() throws {
        try roundTripRequest(ShapeQueryVersion(), expectedSize: 4,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeQueryVersion.decode(from: $0, byteOrder: $1) })
    }

    func testRectanglesEmpty() throws {
        try roundTripRequest(
            ShapeRectangles(op: ShapeOp.set, destKind: ShapeKind.bounding, ordering: 0,
                            dest: 0x12345678, xOff: -3, yOff: 9, rectangles: []),
            expectedSize: 16,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeRectangles.decode(from: $0, byteOrder: $1) })
    }

    func testRectanglesWithRects() throws {
        let rects = [
            Rectangle(x: 0, y: 0, width: 10, height: 10),
            Rectangle(x: -5, y: 7, width: 100, height: 1),
        ]
        try roundTripRequest(
            ShapeRectangles(op: ShapeOp.union, destKind: ShapeKind.clip, ordering: 3,
                            dest: 0xAABBCCDD, xOff: 1, yOff: 2, rectangles: rects),
            expectedSize: 16 + 2 * 8,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeRectangles.decode(from: $0, byteOrder: $1) })
    }

    func testMask() throws {
        try roundTripRequest(
            ShapeMask(op: ShapeOp.set, destKind: ShapeKind.bounding,
                      dest: 0x01020304, xOff: -100, yOff: 50, src: 0x0A0B0C0D),
            expectedSize: 20,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeMask.decode(from: $0, byteOrder: $1) })
    }

    func testMaskNoneSrc() throws {
        try roundTripRequest(
            ShapeMask(op: ShapeOp.set, destKind: ShapeKind.clip,
                      dest: 0x01020304, xOff: 0, yOff: 0, src: 0),   // src == None
            expectedSize: 20,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeMask.decode(from: $0, byteOrder: $1) })
    }

    func testCombine() throws {
        try roundTripRequest(
            ShapeCombine(op: ShapeOp.intersect, destKind: ShapeKind.bounding, srcKind: ShapeKind.clip,
                         dest: 0x11112222, xOff: 4, yOff: -4, src: 0x33334444),
            expectedSize: 20,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeCombine.decode(from: $0, byteOrder: $1) })
    }

    func testOffset() throws {
        try roundTripRequest(
            ShapeOffset(destKind: ShapeKind.clip, dest: 0xDEADBEEF, xOff: -32768, yOff: 32767),
            expectedSize: 16,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeOffset.decode(from: $0, byteOrder: $1) })
    }

    func testQueryExtents() throws {
        try roundTripRequest(ShapeQueryExtents(window: 0x42424242), expectedSize: 8,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeQueryExtents.decode(from: $0, byteOrder: $1) })
    }

    func testSelectInput() throws {
        try roundTripRequest(ShapeSelectInput(window: 0x42424242, enable: 1), expectedSize: 12,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeSelectInput.decode(from: $0, byteOrder: $1) })
    }

    func testInputSelected() throws {
        try roundTripRequest(ShapeInputSelected(window: 0x42424242), expectedSize: 8,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeInputSelected.decode(from: $0, byteOrder: $1) })
    }

    func testGetRectangles() throws {
        try roundTripRequest(ShapeGetRectangles(window: 0x42424242, kind: ShapeKind.bounding),
            expectedSize: 12,
            encode: { $0.encode(majorOpcode: $1, byteOrder: $2) },
            decode: { try ShapeGetRectangles.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Replies

    func testQueryVersionReply() throws {
        try roundTripReply(ShapeQueryVersionReply(sequenceNumber: 7, majorVersion: 1, minorVersion: 0),
            expectedSize: 32,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShapeQueryVersionReply.decode(from: $0, byteOrder: $1) })
    }

    func testQueryExtentsReply() throws {
        try roundTripReply(
            ShapeQueryExtentsReply(sequenceNumber: 9,
                                   boundingShaped: true, clipShaped: false,
                                   xBounding: -2, yBounding: -2, widthBounding: 64, heightBounding: 64,
                                   xClip: 0, yClip: 0, widthClip: 60, heightClip: 60),
            expectedSize: 32,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShapeQueryExtentsReply.decode(from: $0, byteOrder: $1) })
    }

    func testInputSelectedReply() throws {
        for enabled in [true, false] {
            try roundTripReply(ShapeInputSelectedReply(sequenceNumber: 3, enabled: enabled),
                expectedSize: 32,
                encode: { $0.encode(byteOrder: $1) },
                decode: { try ShapeInputSelectedReply.decode(from: $0, byteOrder: $1) })
        }
    }

    func testGetRectanglesReply() throws {
        let rects = [
            Rectangle(x: 0, y: 0, width: 64, height: 1),
            Rectangle(x: 0, y: 1, width: 64, height: 62),
            Rectangle(x: 0, y: 63, width: 64, height: 1),
        ]
        try roundTripReply(ShapeGetRectanglesReply(sequenceNumber: 5, ordering: 3, rectangles: rects),
            expectedSize: 32 + 3 * 8,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShapeGetRectanglesReply.decode(from: $0, byteOrder: $1) })
    }

    func testGetRectanglesReplyEmpty() throws {
        try roundTripReply(ShapeGetRectanglesReply(sequenceNumber: 5, ordering: 0, rectangles: []),
            expectedSize: 32,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShapeGetRectanglesReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - Event

    func testShapeNotifyEvent() throws {
        try roundTripReply(
            ShapeNotifyEvent(type: 64, kind: ShapeKind.bounding, sequenceNumber: 11,
                             window: 0x12345678, x: -2, y: -2, width: 64, height: 64,
                             time: 0xCAFEBABE, shaped: true),
            expectedSize: 32,
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShapeNotifyEvent.decode(from: $0, byteOrder: $1) })
    }
}
