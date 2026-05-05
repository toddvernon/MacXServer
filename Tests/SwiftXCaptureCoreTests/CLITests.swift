import XCTest
@testable import SwiftXCaptureCore

final class CLITests: XCTestCase {

    func testParsesAllRequiredFlags() throws {
        let args = try CLI.parseCapture([
            "--listen", "0.0.0.0:6000",
            "--forward", "sun-b.lan:6000",
            "--output", "/tmp/session.xtap",
        ])
        XCTAssertEqual(args.listenHost, "0.0.0.0")
        XCTAssertEqual(args.listenPort, 6000)
        XCTAssertEqual(args.forwardHost, "sun-b.lan")
        XCTAssertEqual(args.forwardPort, 6000)
        XCTAssertEqual(args.outputPath, "/tmp/session.xtap")
    }

    func testColonOnlyListenUsesDefaultHost() throws {
        let args = try CLI.parseCapture([
            "--listen", ":6000",
            "--forward", "host:6000",
            "--output", "/tmp/x.xtap",
        ])
        XCTAssertEqual(args.listenHost, "0.0.0.0")
        XCTAssertEqual(args.listenPort, 6000)
    }

    func testForwardWithExplicitHost() throws {
        let args = try CLI.parseCapture([
            "--listen", ":6000",
            "--forward", "192.168.1.50:6000",
            "--output", "/tmp/x.xtap",
        ])
        XCTAssertEqual(args.forwardHost, "192.168.1.50")
        XCTAssertEqual(args.forwardPort, 6000)
    }

    func testRejectsMissingFlag() {
        XCTAssertThrowsError(try CLI.parseCapture([
            "--listen", ":6000",
            "--forward", "host:6000",
        ])) { err in
            XCTAssertEqual(err as? CLIError, .missingFlag("--output"))
        }
    }

    func testRejectsMissingValue() {
        XCTAssertThrowsError(try CLI.parseCapture(["--listen"])) { err in
            XCTAssertEqual(err as? CLIError, .missingValue(flag: "--listen"))
        }
    }

    func testRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLI.parseCapture([
            "--listen", ":6000",
            "--bogus", "x",
            "--forward", "h:1",
            "--output", "/tmp/x",
        ])) { err in
            XCTAssertEqual(err as? CLIError, .unknownFlag("--bogus"))
        }
    }

    func testRejectsInvalidHostPort() {
        XCTAssertThrowsError(try CLI.parseCapture([
            "--listen", "garbage",
            "--forward", "host:6000",
            "--output", "/tmp/x",
        ])) { err in
            XCTAssertEqual(err as? CLIError, .invalidHostPort("garbage"))
        }
    }

    func testRejectsForwardWithoutHost() {
        XCTAssertThrowsError(try CLI.parseCapture([
            "--listen", ":6000",
            "--forward", ":6000",
            "--output", "/tmp/x",
        ])) { err in
            XCTAssertEqual(err as? CLIError, .invalidHostPort(":6000"))
        }
    }
}
