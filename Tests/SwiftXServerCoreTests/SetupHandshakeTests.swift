import XCTest
@testable import SwiftXServerCore
import Framer

final class SetupHandshakeTests: XCTestCase {

    func testAcceptsLSBSetupRequestAndRespondsWithSetupAccepted() throws {
        let session = ServerSession()
        let setupBytes = SetupRequest(byteOrder: .lsbFirst).encode()

        let out = session.feed(setupBytes)

        XCTAssertTrue(session.setupAcceptedSent)
        XCTAssertEqual(session.byteOrder, .lsbFirst)
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(out[0], 1, "first byte should be the SetupAccepted status code")

        let reply = try SetupReply.decode(from: out, byteOrder: .lsbFirst)
        guard case .accepted(let accepted) = reply else {
            XCTFail("expected accepted, got \(reply)")
            return
        }
        XCTAssertEqual(accepted.protocolMajor, 11)
        XCTAssertEqual(accepted.resourceIdBase, ServerConfig.default.resourceIdBase)
        XCTAssertEqual(accepted.screens.count, 1)
        XCTAssertEqual(accepted.screens[0].root, ServerConfig.default.rootWindowId)
        XCTAssertEqual(accepted.screens[0].defaultColormap, ServerConfig.default.defaultColormapId)
        XCTAssertEqual(accepted.pixmapFormats.count, 1)
        XCTAssertEqual(accepted.vendor, Array("macXserver".utf8))
    }

    func testAcceptsMSBSetupRequest() throws {
        let session = ServerSession()
        let setupBytes = SetupRequest(byteOrder: .msbFirst).encode()
        let out = session.feed(setupBytes)
        XCTAssertEqual(session.byteOrder, .msbFirst)
        let reply = try SetupReply.decode(from: out, byteOrder: .msbFirst)
        guard case .accepted = reply else {
            XCTFail("expected accepted")
            return
        }
    }

    func testPartialSetupRequestBuffers() throws {
        let session = ServerSession()
        let setupBytes = SetupRequest(byteOrder: .lsbFirst).encode()

        // Feed first 6 bytes — not enough to read auth lengths.
        let outA = session.feed(Array(setupBytes[0..<6]))
        XCTAssertTrue(outA.isEmpty)
        XCTAssertFalse(session.setupAcceptedSent)

        // Now the rest.
        let outB = session.feed(Array(setupBytes[6..<setupBytes.count]))
        XCTAssertFalse(outB.isEmpty)
        XCTAssertTrue(session.setupAcceptedSent)
    }
}
