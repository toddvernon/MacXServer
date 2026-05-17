import XCTest
import Foundation
@testable import SwiftXServerCore

// Locks the embedded CDE RESOURCE_MANAGER fixture to the captured-from-u5
// bytes on disk. If anyone re-formats the fixture's raw string and the
// editor strips a trailing space or shifts a tab, this test catches it
// before it ships and silently breaks Motif clients.
final class CDEResourceManagerFixtureTests: XCTestCase {

    func testFixtureMatchesCapturedBytes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("sun_resource_manager.bin")
        let expected = try Data(contentsOf: url)
        let actual = Data(CDEResourceManagerFixture.bytes)
        XCTAssertEqual(actual.count, expected.count,
                       "fixture byte count drifted from captured property")
        XCTAssertEqual(actual, expected,
                       "fixture bytes drifted from captures/fixtures/sun_resource_manager.bin")
    }
}
