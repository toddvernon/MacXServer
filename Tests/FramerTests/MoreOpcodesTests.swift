import XCTest
@testable import Framer

final class MoreOpcodesTests: XCTestCase {

    private func roundTrip<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0)
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "field equality fails for \(T.self) in \(order)")
            XCTAssertEqual(bytes, encode(decoded, order))
        }
    }

    func testChangeGC() throws {
        try roundTrip(
            ChangeGC(gc: 0x30000001, valueMask: 0x14, valueList: [
                0x00, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ChangeGC.decode(from: $0, byteOrder: $1) })
    }

    func testPolySegment() throws {
        try roundTrip(
            PolySegment(drawable: 0x10000005, gc: 0x30000001, segments: [
                Segment(x1: 0, y1: 0, x2: 100, y2: 100),
                Segment(x1: 0, y1: 100, x2: 100, y2: 0),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolySegment.decode(from: $0, byteOrder: $1) })
    }

    func testPolyArc() throws {
        try roundTrip(
            PolyArc(drawable: 0x10000005, gc: 0x30000001, arcs: [
                Arc(x: 0, y: 0, width: 100, height: 100, angle1: 0, angle2: 64 * 360),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyArc.decode(from: $0, byteOrder: $1) })
    }

    func testFillPoly() throws {
        try roundTrip(
            FillPoly(
                drawable: 0x10000005, gc: 0x30000001,
                shape: .convex, coordinateMode: .origin,
                points: [Point(x: 0, y: 0), Point(x: 50, y: 100), Point(x: 100, y: 0)]
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try FillPoly.decode(from: $0, byteOrder: $1) })
    }

    func testPolyFillArc() throws {
        try roundTrip(
            PolyFillArc(drawable: 0x10000005, gc: 0x30000001, arcs: [
                Arc(x: 10, y: 10, width: 30, height: 30, angle1: 0, angle2: 360 * 64),
                Arc(x: 50, y: 10, width: 30, height: 30, angle1: 0, angle2: 360 * 64),
            ]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyFillArc.decode(from: $0, byteOrder: $1) })
    }

    func testPolyText8() throws {
        // 4-byte aligned items so round-trip is also field-equal.
        try roundTrip(
            PolyText8(drawable: 1, gc: 2, x: 10, y: 20, items: [0x05, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyText8.decode(from: $0, byteOrder: $1) })
    }

    func testAllocNamedColor() throws {
        try roundTrip(
            AllocNamedColor(cmap: 0x60000001, name: Array("red".utf8)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try AllocNamedColor.decode(from: $0, byteOrder: $1) })
    }

    func testBell() throws {
        try roundTrip(
            Bell(percent: 50),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try Bell.decode(from: $0, byteOrder: $1) })
        try roundTrip(
            Bell(percent: -25),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try Bell.decode(from: $0, byteOrder: $1) })
    }

    func testQueryExtension() throws {
        try roundTrip(
            QueryExtension(name: Array("SHAPE".utf8)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryExtension.decode(from: $0, byteOrder: $1) })
        try roundTrip(
            QueryExtension(name: Array("MIT-SHM".utf8)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryExtension.decode(from: $0, byteOrder: $1) })
    }

    func testQueryExtensionReply() throws {
        try roundTrip(
            QueryExtensionReply(sequenceNumber: 7, present: true, majorOpcode: 129, firstEvent: 64, firstError: 128),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryExtensionReply.decode(from: $0, byteOrder: $1) })
        try roundTrip(
            QueryExtensionReply(sequenceNumber: 8, present: false, majorOpcode: 0, firstEvent: 0, firstError: 0),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryExtensionReply.decode(from: $0, byteOrder: $1) })
    }

    func testNoExposureEvent() throws {
        try roundTrip(
            NoExposureEvent(sequenceNumber: 5, drawable: 0x10000020, minorOpcode: 0, majorOpcode: 62),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try NoExposureEvent.decode(from: $0, byteOrder: $1) })
    }

    func testRequestDispatchCoversNew() throws {
        let cases: [Request] = [
            .changeGC(ChangeGC(gc: 1, valueMask: 0)),
            .polySegment(PolySegment(drawable: 1, gc: 2, segments: [])),
            .polyArc(PolyArc(drawable: 1, gc: 2, arcs: [])),
            .fillPoly(FillPoly(drawable: 1, gc: 2, shape: .convex, coordinateMode: .origin, points: [])),
            .polyFillArc(PolyFillArc(drawable: 1, gc: 2, arcs: [])),
            .polyText8(PolyText8(drawable: 1, gc: 2, x: 0, y: 0, items: [])),
            .allocNamedColor(AllocNamedColor(cmap: 1, name: Array("red".utf8))),
            .queryExtension(QueryExtension(name: Array("SHAPE".utf8))),
            .bell(Bell(percent: 0)),
        ]
        for original in cases {
            for order in [ByteOrder.lsbFirst, .msbFirst] {
                let bytes = original.encode(byteOrder: order)
                let decoded = try Request.decode(from: bytes, byteOrder: order)
                XCTAssertEqual(original, decoded, "dispatch fails for \(original) in \(order)")
            }
        }
    }
}
