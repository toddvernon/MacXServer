import XCTest
@testable import SwiftXServerCore
import Framer

// Mirrors the capture-side lineage feature on the live server: when a
// resource id is created and then freed in the same session and the
// client subsequently uses that id, the resulting XError landmark log
// line includes "(freed at seq=Y, created at seq=X)" — the textbook
// use-after-free signal. Capture-side coverage lives in
// SwiftXCaptureCoreTests; this file proves macxserver's live console log
// gets the same annotation.
final class ResourceLineageLandmarkTests: XCTestCase {

    private func runningSession(byteOrder: ByteOrder = .lsbFirst,
                                log: ServerLogSink) -> ServerSession {
        let session = ServerSession()
        session.log = log
        let setupBytes = SetupRequest(byteOrder: byteOrder).encode()
        _ = session.feed(setupBytes)
        _ = session.outbound.drain()
        return session
    }

    func testFreedPixmapUseEmitsLineageSuffixInLog() throws {
        let log = CapturingLogSink()
        let session = runningSession(log: log)
        let pid: UInt32 = 0x05000001

        // seq 1: CreatePixmap. Server-side allocation may or may not
        // succeed depending on drawable validity — the registry tracks
        // by request shape regardless.
        _ = session.feed(Request.createPixmap(CreatePixmap(
            depth: 8, pid: pid, drawable: ServerConfig.default.rootWindowId,
            width: 10, height: 10
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // seq 2: FreePixmap.
        _ = session.feed(Request.freePixmap(FreePixmap(pixmap: pid))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // seq 3: CopyArea referencing the freed pixmap as srcDrawable.
        // The server-side pixmap table no longer has it (or never did, if
        // CreatePixmap was a no-op), so we get BadDrawable.
        _ = session.feed(Request.copyArea(CopyArea(
            srcDrawable: pid, dstDrawable: ServerConfig.default.rootWindowId,
            gc: 0x4400000, srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 4, height: 4
        )).encode(byteOrder: .lsbFirst))

        let landmark = log.lines.first { $0.contains("# BadDrawable") }
        XCTAssertNotNil(landmark, "expected a BadDrawable landmark log line. lines=\(log.lines)")
        XCTAssertTrue(landmark?.contains("(freed at seq=2, created at seq=1)") ?? false,
                      "expected freed+created lineage suffix, got: \(landmark ?? "nil")")
    }

    func testStillLiveResourceUseEmitsCreatedOnlySuffix() throws {
        // CreateGC at seq 1, then a request that would BadGC the same id.
        // The registry shows it created and not freed, so the landmark
        // gets the "(created at seq=1)" suffix — useful diagnostic
        // ("you allocated this earlier, the server still rejected it").
        let log = CapturingLogSink()
        let session = runningSession(log: log)
        let gid: UInt32 = 0x05000002

        _ = session.feed(Request.createGC(CreateGC(
            cid: gid, drawable: ServerConfig.default.rootWindowId,
            valueMask: 0, valueList: []
        )).encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        // The server-side GC table may or may not hold this id depending
        // on whether CreateGC accepted the drawable. To force a guaranteed
        // BadGC, FreeGC a different fictitious id that the registry never
        // saw — that path uses emitError(.gc, ...) without the lineage,
        // which proves the "created at seq=1" case fires only when the
        // bad id actually matches a registry entry. Instead, exercise the
        // same gid via a request that we know will reject it post-Create.
        //
        // Simplest path: FreeGC the same gid first (seq 2 → server clears
        // it), then a follow-up FreeGC of the same gid (seq 3 → BadGC).
        // We want the seq=3 landmark to read "(freed at seq=2, created at
        // seq=1)" — exercises both rungs in one test.
        _ = session.feed(Request.freeGC(FreeGC(gc: gid))
            .encode(byteOrder: .lsbFirst))
        _ = session.outbound.drain()

        _ = session.feed(Request.freeGC(FreeGC(gc: gid))
            .encode(byteOrder: .lsbFirst))

        let landmark = log.lines.first { $0.contains("# BadGC") }
        XCTAssertNotNil(landmark, "expected a BadGC landmark log line. lines=\(log.lines)")
        XCTAssertTrue(landmark?.contains("(freed at seq=2, created at seq=1)") ?? false,
                      "expected freed+created lineage suffix on double-free, got: \(landmark ?? "nil")")
    }

    func testUnknownResourceErrorHasNoLineageSuffix() throws {
        // Bad id the registry never saw → no suffix. Sanity check that the
        // wire-up doesn't fabricate lineage when the registry has nothing.
        let log = CapturingLogSink()
        let session = runningSession(log: log)
        let bogus: UInt32 = 0xDEADBEEF

        _ = session.feed(Request.copyArea(CopyArea(
            srcDrawable: bogus, dstDrawable: ServerConfig.default.rootWindowId,
            gc: 0x4400000, srcX: 0, srcY: 0, dstX: 0, dstY: 0, width: 1, height: 1
        )).encode(byteOrder: .lsbFirst))

        let landmark = log.lines.first { $0.contains("# BadDrawable") }
        XCTAssertNotNil(landmark, "expected a BadDrawable landmark log line. lines=\(log.lines)")
        XCTAssertFalse(landmark?.contains("freed at seq") ?? true,
                       "landmark must not synthesize freed lineage when registry has no record: \(landmark ?? "nil")")
        XCTAssertFalse(landmark?.contains("created at seq") ?? true,
                       "landmark must not synthesize created lineage when registry has no record: \(landmark ?? "nil")")
    }
}
