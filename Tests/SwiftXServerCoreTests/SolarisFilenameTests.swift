import XCTest
@testable import SwiftXServerCore

final class SolarisFilenameTests: XCTestCase {

    func testAlreadySafeNamesPassThrough() {
        for name in ["report.txt", "a.tar.gz", "my_file-1.c", ".bashrc", "Makefile"] {
            XCTAssertEqual(SolarisFilename.sanitize(name), name, "\(name) is already safe")
        }
    }

    func testSpacesBecomeUnderscores() {
        XCTAssertEqual(SolarisFilename.sanitize("my file.txt"), "my_file.txt")
        XCTAssertEqual(SolarisFilename.sanitize("a   b.txt"), "a_b.txt", "a run collapses to one")
    }

    func testShellMetacharactersAreReplaced() {
        XCTAssertEqual(SolarisFilename.sanitize("report (final).pdf"), "report_final_.pdf")
        XCTAssertEqual(SolarisFilename.sanitize("a&b|c;d.txt"), "a_b_c_d.txt")
        XCTAssertEqual(SolarisFilename.sanitize("$weird'name\".dat"), "_weird_name_.dat")
    }

    func testNonAsciiBecomesUnderscore() {
        XCTAssertEqual(SolarisFilename.sanitize("café.txt"), "caf_.txt")
        XCTAssertEqual(SolarisFilename.sanitize("naïve.doc"), "na_ve.doc")
    }

    func testLeadingDashIsDefused() {
        XCTAssertEqual(SolarisFilename.sanitize("-rf.txt"), "_-rf.txt",
                       "a leading dash would be read as an option")
        XCTAssertEqual(SolarisFilename.sanitize("--force"), "_--force")
    }

    func testNeverEmptyOrDirectoryRef() {
        XCTAssertFalse(SolarisFilename.sanitize("///").contains("/"))
        XCTAssertEqual(SolarisFilename.sanitize("."), "_.")
        XCTAssertEqual(SolarisFilename.sanitize(".."), "_..")
    }

    func testIdempotent() {
        for name in ["my file.txt", "report (final).pdf", "-rf", "café.dat"] {
            let once = SolarisFilename.sanitize(name)
            XCTAssertEqual(SolarisFilename.sanitize(once), once, "\(name) -> \(once) is stable")
        }
    }

    func testLengthCapped() {
        let long = String(repeating: "x", count: 300) + ".txt"
        XCTAssertLessThanOrEqual(SolarisFilename.sanitize(long).count, 255)
    }
}
