import XCTest
import Framer
@testable import SwiftXCaptureCore

// Phase 2 (2026-05-30) registry tests.
//
// Drives the registry through both directions:
//   1) Direct API: does SHAPE register and round-trip?
//   2) Behavior in the dumper: when ChronoDumper sees an extension
//      request whose major opcode was bound by an earlier QueryExtension
//      reply, does it produce a typed line (for SHAPE) or a labeled-
//      undecoded line (for unrecognized extensions)?

final class ExtensionDumperRegistryTests: XCTestCase {

    // MARK: - Registry API

    func testShapeIsRegistered() {
        let decoder = ExtensionDumperRegistry.decoder(forName: "SHAPE")
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder?.extensionName, "SHAPE")
        XCTAssertEqual(decoder?.eventCount, 1)
    }

    func testUnknownExtensionIsNotRegistered() {
        // Use a deliberately-fictitious name so this stays a "no decoder
        // registered" check even as we add real extensions over time.
        XCTAssertNil(ExtensionDumperRegistry.decoder(forName: "MADE-UP-EXTENSION"))
        XCTAssertEqual(ExtensionDumperRegistry.eventCount(forName: "MADE-UP-EXTENSION"), 0)
    }

    func testAllRegisteredNamesIncludesShape() {
        XCTAssertTrue(ExtensionDumperRegistry.allRegisteredNames.contains("SHAPE"))
    }

    // MARK: - ShapeDumper formatters

    func testShapeDumperFormatsKnownRequest() {
        // Pretend SHAPE got assigned major opcode 128; build a ShapeOffset
        // request and feed its wire bytes back through the decoder.
        let req = ShapeOffset(destKind: 0, dest: 0x10_0000_05, xOff: 12, yOff: 34)
        let bytes = req.encode(majorOpcode: 128, byteOrder: .msbFirst)
        let line = ShapeDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("ShapeOffset"))
        XCTAssertTrue(line!.contains("off=(12,34)"))
    }

    func testShapeDumperReturnsNilOnUnknownMinor() {
        // Major opcode 128, minor opcode 99 (not a SHAPE op) — should fall
        // through to nil so the caller can emit a labeled-undecoded line.
        let bytes: [UInt8] = [128, 99, 0, 1]  // length=1
        XCTAssertNil(ShapeDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst))
    }

    func testShapeDumperFormatsNotifyEvent() {
        // Event base 64 + ShapeNotify (offset 0) = code 64.
        let ev = ShapeNotifyEvent(
            type: 64, kind: 0, sequenceNumber: 7,
            window: 0x10_0000_05, x: 1, y: 2, width: 100, height: 200,
            time: 12345, shaped: true
        )
        let bytes = ev.encode(byteOrder: .msbFirst)
        let line = ShapeDumper.formatEvent(bytes: bytes, firstEvent: 64, byteOrder: .msbFirst)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("ShapeNotify"))
        XCTAssertTrue(line!.contains("shaped=true"))
    }

    // MARK: - ChronoContext extension routing

    func testExtensionForEventFindsBinding() {
        var ctx = ChronoContext()
        ctx.extensionFirstEventToName[64] = "SHAPE"
        ctx.extensionFirstEventToName[88] = "MADE-UP-EXTENSION"  // no registered decoder

        // SHAPE owns its single event at code 64.
        let shape = ctx.extensionForEvent(code: 64)
        XCTAssertEqual(shape?.name, "SHAPE")
        XCTAssertEqual(shape?.firstEvent, 64)

        // Unregistered extension: lookup still returns it for code ==
        // firstEvent so the dumper can label-but-not-decode.
        let madeUp = ctx.extensionForEvent(code: 88)
        XCTAssertEqual(madeUp?.name, "MADE-UP-EXTENSION")

        // A code outside any registered range returns nil.
        XCTAssertNil(ctx.extensionForEvent(code: 100))
    }
}
