import XCTest
import Foundation
@testable import SwiftXCaptureCore

final class RecorderParentDirTests: XCTestCase {
    func testCreatesParentDirectoryIfMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-parent-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("deep")
        let outputPath = dir.appendingPathComponent("session.xtap").path

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let recorder = try Recorder(outputPath: outputPath, listen: ":6000", forward: "host:6000")
        recorder.record(direction: .clientToServer, bytes: [0x01, 0x02])
        try recorder.finalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath + ".json"))
    }

    func testWorksWithNoParentDirectory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-flat-\(UUID().uuidString).xtap").path
        let recorder = try Recorder(outputPath: path, listen: ":6000", forward: "host:6000")
        try recorder.finalize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
