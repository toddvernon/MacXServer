import XCTest
@testable import Framer

// Phase 3 batch A (2026-05-30) — wire round-trip tests for the
// BIG-REQUESTS and MIT-SHM extension types. Each test encodes a
// representative value, decodes the bytes, and verifies field equality
// + byte-identical re-encode in both byte orders. Major opcodes are
// dynamic at runtime (assigned by QueryExtension); the tests pick
// arbitrary values from the typical extension range.

final class BigRequestsAndShmRoundTripTests: XCTestCase {

    private func roundTrip<T: Equatable>(
        _ original: T,
        encode: (T, ByteOrder) -> [UInt8],
        decode: ([UInt8], ByteOrder) throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for order in [ByteOrder.lsbFirst, .msbFirst] {
            let bytes = encode(original, order)
            XCTAssertEqual(bytes.count % 4, 0, "\(T.self) bytes must be 4-byte aligned", file: file, line: line)
            let decoded = try decode(bytes, order)
            XCTAssertEqual(original, decoded, "\(T.self) field equality fails in \(order)", file: file, line: line)
            XCTAssertEqual(bytes, encode(decoded, order), "\(T.self) byte-identical round-trip fails in \(order)", file: file, line: line)
        }
    }

    // MARK: - BIG-REQUESTS

    func testBigReqEnable() throws {
        try roundTrip(BigReqEnable(),
            encode: { $0.encode(majorOpcode: 132, byteOrder: $1) },
            decode: { try BigReqEnable.decode(from: $0, byteOrder: $1) })
    }

    func testBigReqEnableReply() throws {
        try roundTrip(BigReqEnableReply(sequenceNumber: 3, maxRequestSize: 0x40_0000),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try BigReqEnableReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - MIT-SHM requests

    func testShmQueryVersion() throws {
        try roundTrip(ShmQueryVersion(),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmQueryVersion.decode(from: $0, byteOrder: $1) })
    }

    func testShmAttach() throws {
        try roundTrip(ShmAttach(shmseg: 0xDEADBEEF, shmid: 0x12345678, readOnly: true),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmAttach.decode(from: $0, byteOrder: $1) })
        try roundTrip(ShmAttach(shmseg: 0xDEADBEEF, shmid: 0x12345678, readOnly: false),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmAttach.decode(from: $0, byteOrder: $1) })
    }

    func testShmDetach() throws {
        try roundTrip(ShmDetach(shmseg: 0xDEADBEEF),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmDetach.decode(from: $0, byteOrder: $1) })
    }

    func testShmPutImage() throws {
        try roundTrip(ShmPutImage(
            drawable: 0x10000005, gc: 0x10000020,
            totalWidth: 640, totalHeight: 480,
            srcX: 0, srcY: 0, srcWidth: 320, srcHeight: 240,
            dstX: -10, dstY: 5,
            depth: 24, format: 2, sendEvent: true,
            shmseg: 0xDEADBEEF, offset: 0x1000),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmPutImage.decode(from: $0, byteOrder: $1) })
    }

    func testShmGetImage() throws {
        try roundTrip(ShmGetImage(
            drawable: 0x10000005, x: -5, y: 7,
            width: 100, height: 200,
            planeMask: 0xFFFFFFFF, format: 2,
            shmseg: 0xDEADBEEF, offset: 0),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmGetImage.decode(from: $0, byteOrder: $1) })
    }

    func testShmCreatePixmap() throws {
        try roundTrip(ShmCreatePixmap(
            pid: 0x10000050, drawable: 0x10000005,
            width: 320, height: 240,
            depth: 24, shmseg: 0xDEADBEEF, offset: 0x2000),
            encode: { $0.encode(majorOpcode: 133, byteOrder: $1) },
            decode: { try ShmCreatePixmap.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - MIT-SHM replies

    func testShmQueryVersionReply() throws {
        try roundTrip(ShmQueryVersionReply(
            sequenceNumber: 5, sharedPixmaps: true,
            majorVersion: 1, minorVersion: 1,
            uid: 1000, gid: 1000, pixmapFormat: 2),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShmQueryVersionReply.decode(from: $0, byteOrder: $1) })
    }

    func testShmGetImageReply() throws {
        try roundTrip(ShmGetImageReply(
            sequenceNumber: 11, depth: 24,
            visual: 0x21, size: 0x40000),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShmGetImageReply.decode(from: $0, byteOrder: $1) })
    }

    // MARK: - MIT-SHM event

    func testShmCompletionEvent() throws {
        try roundTrip(ShmCompletionEvent(
            type: 81, sequenceNumber: 17,
            drawable: 0x10000005,
            minorEvent: 3, majorEvent: 133,
            shmseg: 0xDEADBEEF, offset: 0x1000),
            encode: { $0.encode(byteOrder: $1) },
            decode: { try ShmCompletionEvent.decode(from: $0, byteOrder: $1) })
    }
}
