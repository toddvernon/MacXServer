import XCTest
import Foundation
import Framer
@testable import SwiftXCaptureCore

// Walks every C2S byte in every .xtap under captures/ and asserts that the
// framer's decoder understands it. The check is decode → encode → decode and
// equality of the two decoded values, not byte-identity: X11 explicitly allows
// senders to leave unused padding bytes uninitialized, and real Xlib does so
// liberally (uninitialized stack content trailing ImageText8 strings, etc.).
// A byte-identical comparison would fire on padding noise, not on real bugs.
//
// Two correctness properties are checked per request:
//   1. The re-encoded byte length equals what the original request's header
//      claimed (catches encoder size bugs).
//   2. The re-encoded bytes decode back to a value equal to the first decode
//      (catches semantic round-trip bugs in either direction).
final class CorpusRoundTripTests: XCTestCase {

    func testEveryCaptureC2SDecodesAndRoundTripsSemantically() throws {
        let captures = try locateCaptures()
        XCTAssertFalse(captures.isEmpty, "no .xtap files found under \(capturesDirectory().path)")

        for capture in captures {
            try checkRoundTrip(capturePath: capture.path)
        }
    }

    private func checkRoundTrip(capturePath: String) throws {
        let frames = try CaptureReader.read(from: capturePath)
        let c2s = frames.filter { $0.direction == .clientToServer }.flatMap { $0.bytes }
        guard !c2s.isEmpty else { return }

        let name = (capturePath as NSString).lastPathComponent

        let setupReq = try SetupRequest.decode(from: c2s)
        let setupReencoded = setupReq.encode()
        let setupReq2 = try SetupRequest.decode(from: setupReencoded)
        XCTAssertEqual(setupReq, setupReq2, "[\(name)] SetupRequest semantic round-trip failed")

        let byteOrder = setupReq.byteOrder
        var offset = setupReencoded.count
        var requestIndex = 0
        while offset < c2s.count {
            let remaining = Array(c2s[offset...])
            guard remaining.count >= 4 else {
                XCTFail("[\(name)] truncated request header at offset \(offset)")
                return
            }
            let originalSize = Int(readLengthInBytes(remaining, byteOrder: byteOrder))
            let req: Request
            do {
                req = try Request.decode(from: remaining, byteOrder: byteOrder)
            } catch {
                XCTFail("[\(name)] decode failed at offset \(offset), request #\(requestIndex), opcode \(remaining[0]): \(error)")
                return
            }
            let reencoded = req.encode(byteOrder: byteOrder)
            XCTAssertEqual(
                reencoded.count, originalSize,
                "[\(name)] request #\(requestIndex) opcode \(remaining[0]) at offset \(offset): re-encoded size \(reencoded.count) != original size \(originalSize)"
            )
            do {
                let req2 = try Request.decode(from: reencoded, byteOrder: byteOrder)
                XCTAssertEqual(
                    req, req2,
                    "[\(name)] request #\(requestIndex) opcode \(remaining[0]) at offset \(offset) does not round-trip semantically"
                )
            } catch {
                XCTFail("[\(name)] re-decode of re-encoded request #\(requestIndex) opcode \(remaining[0]) failed: \(error)")
                return
            }
            offset += originalSize
            requestIndex += 1
        }
    }

    private func readLengthInBytes(_ bytes: [UInt8], byteOrder: ByteOrder) -> UInt32 {
        let lenIn4: UInt16
        switch byteOrder {
        case .lsbFirst: lenIn4 = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        case .msbFirst: lenIn4 = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        }
        return UInt32(lenIn4) * 4
    }

    private func capturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("captures")
    }

    private func locateCaptures() throws -> [URL] {
        let dir = capturesDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "xtap" }.sorted { $0.path < $1.path }
    }
}
