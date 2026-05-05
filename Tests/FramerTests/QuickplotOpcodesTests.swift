import XCTest
@testable import Framer

final class QuickplotOpcodesTests: XCTestCase {

    private func roundTrip<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0)
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded)
            XCTAssertEqual(bytes, encode(decoded, order))
        }
    }

    func testGetWindowAttributes() throws {
        try roundTrip(GetWindowAttributes(window: 0x10000005),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GetWindowAttributes.decode(from: $0, byteOrder: $1) })
    }

    func testSetClipRectangles() throws {
        try roundTrip(
            SetClipRectangles(
                ordering: .yxBanded, gc: 0x30000001, clipXOrigin: 10, clipYOrigin: 20,
                rectangles: [
                    Rectangle(x: 0, y: 0, width: 100, height: 50),
                    Rectangle(x: 100, y: 50, width: 50, height: 50),
                ]
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetClipRectangles.decode(from: $0, byteOrder: $1) })
    }

    func testSetDashes() throws {
        // 4-byte aligned dashes for byte-identical round-trip.
        try roundTrip(
            SetDashes(gc: 0x30000001, dashOffset: 0, dashes: [4, 2, 4, 2]),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SetDashes.decode(from: $0, byteOrder: $1) })
    }

    func testPolyRectangle() throws {
        try roundTrip(
            PolyRectangle(
                drawable: 0x10000005, gc: 0x30000001,
                rectangles: [
                    Rectangle(x: 10, y: 10, width: 50, height: 50),
                    Rectangle(x: 100, y: 10, width: 50, height: 50),
                ]
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try PolyRectangle.decode(from: $0, byteOrder: $1) })
    }

    func testLookupColor() throws {
        try roundTrip(
            LookupColor(cmap: 0x60000001, name: Array("steel blue".utf8)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try LookupColor.decode(from: $0, byteOrder: $1) })
    }

    func testSendEvent() throws {
        let evt = [UInt8](repeating: 0, count: 32)
        try roundTrip(
            SendEvent(propagate: false, destination: 0x10000005, eventMask: 0x4, event: evt),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try SendEvent.decode(from: $0, byteOrder: $1) })
    }

    func testGrabKey() throws {
        try roundTrip(
            GrabKey(
                ownerEvents: false, grabWindow: 0x10000005,
                modifiers: 0x4, key: 37,
                pointerMode: .asynchronous, keyboardMode: .asynchronous
            ),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try GrabKey.decode(from: $0, byteOrder: $1) })
    }

    func testListFonts() throws {
        try roundTrip(
            ListFonts(maxNames: 100, pattern: Array("*-fixed-*".utf8)),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ListFonts.decode(from: $0, byteOrder: $1) })
    }

    func testQueryBestSize() throws {
        try roundTrip(
            QueryBestSize(sizeClass: .cursor, drawable: 0x10000005, width: 16, height: 16),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try QueryBestSize.decode(from: $0, byteOrder: $1) })
    }

    func testRequestDispatchCoversNew() throws {
        let cases: [Request] = [
            .getWindowAttributes(GetWindowAttributes(window: 1)),
            .setClipRectangles(SetClipRectangles(ordering: .unsorted, gc: 1, clipXOrigin: 0, clipYOrigin: 0, rectangles: [])),
            .setDashes(SetDashes(gc: 1, dashOffset: 0, dashes: [4, 2, 4, 2])),
            .polyRectangle(PolyRectangle(drawable: 1, gc: 2, rectangles: [])),
            .lookupColor(LookupColor(cmap: 1, name: Array("red".utf8))),
            .sendEvent(SendEvent(propagate: false, destination: 1, eventMask: 0, event: [UInt8](repeating: 0, count: 32))),
            .grabKey(GrabKey(ownerEvents: false, grabWindow: 1, modifiers: 0, key: 0, pointerMode: .asynchronous, keyboardMode: .asynchronous)),
            .listFonts(ListFonts(maxNames: 10, pattern: Array("*".utf8))),
            .queryBestSize(QueryBestSize(sizeClass: .cursor, drawable: 1, width: 16, height: 16)),
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
