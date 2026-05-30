import XCTest
import Framer
@testable import SwiftXCaptureCore

// Phase 3 batch A (2026-05-30) dumper tests.
// Verifies BIG-REQUESTS and MIT-SHM are registered + their formatters
// produce sensible lines for the wire bytes the framer writes.

final class Phase3DumperTests: XCTestCase {

    func testRegistryHasNewExtensions() {
        let names = ExtensionDumperRegistry.allRegisteredNames
        XCTAssertTrue(names.contains("BIG-REQUESTS"))
        XCTAssertTrue(names.contains("MIT-SHM"))
        XCTAssertTrue(names.contains("SHAPE"))
    }

    // MARK: - BIG-REQUESTS

    func testBigRequestsDumpEnable() {
        let req = BigReqEnable()
        let bytes = req.encode(majorOpcode: 132, byteOrder: .msbFirst)
        let line = BigRequestsDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst)
        XCTAssertEqual(line, "BigReqEnable")
    }

    func testBigRequestsRejectsUnknownMinor() {
        // Major 132, minor 99 — not a BIG-REQUESTS op.
        let bytes: [UInt8] = [132, 99, 0, 1]
        XCTAssertNil(BigRequestsDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst))
    }

    // MARK: - MIT-SHM

    func testShmDumpAttach() {
        let req = ShmAttach(shmseg: 0xDEADBEEF, shmid: 42, readOnly: true)
        let bytes = req.encode(majorOpcode: 133, byteOrder: .msbFirst)
        let line = ShmDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("ShmAttach"))
        XCTAssertTrue(line!.contains("shmid=0x2a"))
        XCTAssertTrue(line!.contains("readOnly=true"))
    }

    func testShmDumpPutImage() {
        let req = ShmPutImage(
            drawable: 0x10000005, gc: 0x10000020,
            totalWidth: 640, totalHeight: 480,
            srcX: 0, srcY: 0, srcWidth: 320, srcHeight: 240,
            dstX: 100, dstY: 50,
            depth: 24, format: 2, sendEvent: true,
            shmseg: 0xDEADBEEF, offset: 0x1000)
        let bytes = req.encode(majorOpcode: 133, byteOrder: .msbFirst)
        let line = ShmDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("ShmPutImage"))
        XCTAssertTrue(line!.contains("dst=(100,50)"))
    }

    func testShmDumpCompletionEvent() {
        // Pretend MIT-SHM got event base 81; build a completion event.
        let ev = ShmCompletionEvent(
            type: 81, sequenceNumber: 7, drawable: 0x10000005,
            minorEvent: 3, majorEvent: 133,
            shmseg: 0xDEADBEEF, offset: 0)
        let bytes = ev.encode(byteOrder: .msbFirst)
        let line = ShmDumper.formatEvent(bytes: bytes, firstEvent: 81, byteOrder: .msbFirst)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("ShmCompletion"))
        XCTAssertTrue(line!.contains("majorEvent=133"))
    }

    func testShmRejectsUnknownMinor() {
        let bytes: [UInt8] = [133, 99, 0, 1]
        XCTAssertNil(ShmDumper.formatRequest(bytes: bytes, byteOrder: .msbFirst))
    }

    // MARK: - Integration through ChronoContext

    func testContextRoutesShmEventByFirstEvent() {
        var ctx = ChronoContext()
        ctx.extensionFirstEventToName[81] = "MIT-SHM"

        // Code 81 belongs to MIT-SHM (firstEvent + offset 0 = ShmCompletion).
        let binding = ctx.extensionForEvent(code: 81)
        XCTAssertEqual(binding?.name, "MIT-SHM")
        XCTAssertEqual(binding?.firstEvent, 81)

        // Code 82 is one past MIT-SHM's range (eventCount=1) — no binding.
        XCTAssertNil(ctx.extensionForEvent(code: 82))
    }
}
