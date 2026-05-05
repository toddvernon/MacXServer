import XCTest
import Foundation
@testable import SwiftXCaptureCore

final class RecorderTests: XCTestCase {

    func testWritesMagicAndVersion() throws {
        let path = makeTempFilePath(prefix: "magic")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        try recorder.finalize()

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(data.prefix(4)), CaptureFile.magic)
        XCTAssertEqual(data[4], CaptureFile.version)
    }

    func testWritesSingleFrame() throws {
        let path = makeTempFilePath(prefix: "single")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0xDE, 0xAD, 0xBE, 0xEF])
        try recorder.finalize()

        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].direction, .clientToServer)
        XCTAssertEqual(frames[0].bytes, [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testWritesMultipleFramesBothDirections() throws {
        let path = makeTempFilePath(prefix: "multi")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0x01, 0x02, 0x03])
        recorder.record(direction: .serverToClient, bytes: [0xAA, 0xBB])
        recorder.record(direction: .clientToServer, bytes: [0x04])
        try recorder.finalize()

        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.map { $0.direction },
                       [.clientToServer, .serverToClient, .clientToServer])
        XCTAssertEqual(frames.map { $0.bytes },
                       [[0x01, 0x02, 0x03], [0xAA, 0xBB], [0x04]])
        XCTAssertLessThanOrEqual(frames[0].timestamp, frames[1].timestamp)
        XCTAssertLessThanOrEqual(frames[1].timestamp, frames[2].timestamp)
    }

    func testFrameTimestampStartsAtZero() throws {
        let path = makeTempFilePath(prefix: "ts")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0x42])
        try recorder.finalize()

        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames[0].timestamp, 0)
    }

    func testSidecarJsonContainsExpectedFields() throws {
        let path = makeTempFilePath(prefix: "sidecar")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "sun-b:6000")
        recorder.record(direction: .clientToServer, bytes: [0x01, 0x02, 0x03, 0x04])
        recorder.record(direction: .serverToClient, bytes: [0xFF, 0xFE])
        try recorder.finalize()

        let json = try Data(contentsOf: URL(fileURLWithPath: path + ".json"))
        let metadata = try JSONDecoder().decode(Metadata.self, from: json)
        XCTAssertEqual(metadata.listen, ":6000")
        XCTAssertEqual(metadata.forward, "sun-b:6000")
        XCTAssertEqual(metadata.totalBytesC2S, 4)
        XCTAssertEqual(metadata.totalBytesS2C, 2)
        XCTAssertFalse(metadata.recordedAt.isEmpty)
        XCTAssertFalse(metadata.toolVersion.isEmpty)
    }

    func testFrameHeaderLayout() throws {
        let path = makeTempFilePath(prefix: "layout")
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .serverToClient, bytes: [0xAB, 0xCD])
        try recorder.finalize()

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // 8-byte file header, then 13-byte frame header, then 2-byte payload.
        XCTAssertEqual(data.count, 8 + 13 + 2)
        // direction byte at offset 8.
        XCTAssertEqual(data[8], Direction.serverToClient.rawValue)
        // length uint32 at offset 8+1+8=17, little-endian = 2.
        XCTAssertEqual(data[17], 0x02)
        XCTAssertEqual(data[18], 0x00)
        XCTAssertEqual(data[19], 0x00)
        XCTAssertEqual(data[20], 0x00)
        // payload at offset 21.
        XCTAssertEqual(data[21], 0xAB)
        XCTAssertEqual(data[22], 0xCD)
    }

    func testCaptureReaderRejectsBadMagic() {
        let bad: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x01, 0, 0, 0]
        XCTAssertThrowsError(try CaptureReader.parse(bad)) { err in
            XCTAssertEqual(err as? CaptureReadError, .badMagic)
        }
    }

    func testCaptureReaderRejectsTruncatedFrame() {
        var buf = CaptureFile.magic
        buf.append(CaptureFile.version)
        buf.append(contentsOf: [0, 0, 0])
        // Frame header claiming 100 bytes payload, but no payload follows.
        buf.append(Direction.clientToServer.rawValue)
        buf.append(contentsOf: [UInt8](repeating: 0, count: 8))     // timestamp
        buf.append(contentsOf: [100, 0, 0, 0])                      // length=100 LE
        XCTAssertThrowsError(try CaptureReader.parse(buf)) { err in
            XCTAssertEqual(err as? CaptureReadError, .truncated)
        }
    }
}
