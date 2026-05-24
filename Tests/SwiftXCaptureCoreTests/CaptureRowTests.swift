import XCTest
@testable import SwiftXCaptureCore

// Covers the line-to-row parser the Open window uses to populate
// its scrollable packet list. The input shape is the per-line
// output of ChronoDumper.dump — leading timestamp, optional
// direction arrow in square brackets, then the packet name and
// its formatted body.

final class CaptureRowTests: XCTestCase {

    func testSplitsTimestampAndArrowAwayFromTitle() {
        let line = "       12345 [→]  PolyFillRectangle drawable=0x4400023 gc=0x10 n=1"
        let (title, detail) = CaptureRow.split(line)
        XCTAssertEqual(title, "PolyFillRectangle")
        XCTAssertEqual(detail, "drawable=0x4400023 gc=0x10 n=1")
    }

    func testSplitsLeftDirectionArrow() {
        // Server-to-client arrow points the other way.
        let line = "       54321 [←]  Reply: InternAtom atom=42"
        let (title, detail) = CaptureRow.split(line)
        XCTAssertEqual(title, "Reply:")
        XCTAssertEqual(detail, "InternAtom atom=42")
    }

    func testSplitsWithoutDirectionArrow() {
        // Some chrono lines (e.g. SetupRequest) have no arrow,
        // just timestamp + content.
        let line = "         123 SetupRequest byteOrder=lsb-first"
        let (title, detail) = CaptureRow.split(line)
        XCTAssertEqual(title, "SetupRequest")
        XCTAssertEqual(detail, "byteOrder=lsb-first")
    }

    func testLineWithOnlyTitleHasEmptyDetail() {
        let line = "       1234 [→]  MapWindow"
        let (title, detail) = CaptureRow.split(line)
        XCTAssertEqual(title, "MapWindow")
        XCTAssertEqual(detail, "")
    }

    func testPathologicalAllNumericLineGetsEmptyTitle() {
        // If the line is somehow all digits (unlikely from real
        // ChronoDumper output) we don't want to claim a digit run
        // as a title — return empty title + the raw line as detail
        // so the UI can still render something.
        let line = "       12345"
        let (title, detail) = CaptureRow.split(line)
        XCTAssertEqual(title, "")
        XCTAssertEqual(detail, line)
    }

    func testRowConstructorPopulatesTitleAndDetail() {
        let row = CaptureRow(
            id: 7,
            lineText: "      9999 [→]  QueryFont font=0x4600005"
        )
        XCTAssertEqual(row.id, 7)
        XCTAssertEqual(row.title, "QueryFont")
        XCTAssertEqual(row.detail, "font=0x4600005")
        XCTAssertTrue(row.lineText.contains("QueryFont"))
    }

    func testIdentifiable() {
        // SwiftUI's List(selection:) keys on id. Two rows with the
        // same id but different lineText must still compare distinct
        // by Hashable — title/detail are part of the synthesised
        // equality.
        let a = CaptureRow(id: 1, lineText: "       1 [→]  MapWindow")
        let b = CaptureRow(id: 1, lineText: "       1 [→]  UnmapWindow")
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - End-to-end against ChronoDumper

    func testRowsBuildFromChronoDumperOutput() throws {
        // Mirrors what OpenModel does: ChronoDumper.dump → split by
        // newline → CaptureRow per line. The first line is the
        // "=== path ===" banner the model strips.
        let path = makeTempFilePath(prefix: "row-pipeline")
        let recorder = try Recorder(outputPath: path, listen: ":1", forward: "h:2")

        // Synthesise the minimum a real session writes: a
        // SetupRequest, a SetupReply, and one request.
        let setupReq: [UInt8] = [
            0x6c, 0x00, 0x0B, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        recorder.record(direction: .clientToServer, bytes: setupReq)

        // Minimal valid SetupReply (so ChronoDumper can advance past
        // setup). 40-byte fixed header + vendor + format + screen +
        // depths. The simplest accepted reply with empty vendor and
        // no extra screens is rejected by the framer's stricter
        // decode, so reuse an existing fixture from another test if
        // we have one... actually for this test, just check the C2S
        // side: ChronoDumper handles partial S2C streams by stalling
        // on the s2c side without aborting the c2s walk.
        // CreateWindow request (opcode 1, lenIn4=8 → 32 bytes).
        var createWindow: [UInt8] = [1, 24, 0x08, 0x00]
        createWindow.append(contentsOf: [UInt8](repeating: 0, count: 28))
        recorder.record(direction: .clientToServer, bytes: createWindow)

        try recorder.finalize()

        // Use the exact pipeline OpenModel uses.
        let frames = try CaptureReader.read(from: path)
        XCTAssertEqual(frames.count, 2)

        let text = try ChronoDumper.dump(path: path)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThan(lines.count, 1, "expected banner + at least one data line")

        // Strip the banner the same way the model does.
        let dataLines = lines.first?.hasPrefix("===") == true
            ? lines.dropFirst()
            : lines[...]
        let rows = dataLines.enumerated().map { (i, line) in
            CaptureRow(id: i, lineText: String(line))
        }
        XCTAssertGreaterThanOrEqual(rows.count, 1)

        // Find the CreateWindow row by title.
        XCTAssertTrue(rows.contains { $0.title == "CreateWindow" },
                      "expected a CreateWindow row, got titles: \(rows.map(\.title))")
    }
}
