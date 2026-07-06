import XCTest
@testable import SwiftXServerCore

final class GuestOSDetectorTests: XCTestCase {

    /// A minimal fake qcow2: the `QFI\xFB` magic, then enough header zeros to reach
    /// the fields we read, then an appended payload. Not a real image, but the
    /// banner scan only needs the magic + the literal bytes somewhere in the file.
    private func fakeQcow2(headerExtra: [UInt8] = [], payload: String) -> Data {
        var d = Data([0x51, 0x46, 0x49, 0xFB])          // "QFI\xFB"
        d.append(contentsOf: [0, 0, 0, 3])              // version 3
        // Pad out to a 72-byte header (past l1/refcount fields) unless caller
        // supplied explicit header bytes.
        if headerExtra.isEmpty {
            d.append(contentsOf: [UInt8](repeating: 0, count: 72 - d.count))
        } else {
            d.append(contentsOf: headerExtra)
        }
        d.append(contentsOf: Array(payload.utf8))
        return d
    }

    func testDetectsEachKnownBanner() {
        XCTAssertEqual(
            GuestOSDetector.detect(data: fakeQcow2(payload: "…SunOS Release 5.6…")),
            .detected(.solaris26, banner: "SunOS Release 5.6"))
        XCTAssertEqual(
            GuestOSDetector.detect(data: fakeQcow2(payload: "junk SunOS Release 4.1.4 junk")),
            .detected(.sunos414, banner: "SunOS Release 4.1.4"))
        XCTAssertEqual(
            GuestOSDetector.detect(data: fakeQcow2(payload: "boot: NetBSD 9.2 (GENERIC)")),
            .detected(.netbsd, banner: "NetBSD 9.2"))
    }

    func testDetectionConvenienceOSAccessor() {
        XCTAssertEqual(GuestOSDetector.detect(data: fakeQcow2(payload: "SunOS Release 5.6")).os,
                       .solaris26)
        XCTAssertNil(GuestOSDetection.unrecognized.os)
        XCTAssertNil(GuestOSDetection.notQcow2.os)
    }

    func testNotAQcow2() {
        let d = Data("this is not a disk image, just text".utf8)
        XCTAssertEqual(GuestOSDetector.detect(data: d), .notQcow2)
        // Too short to even hold the magic.
        XCTAssertEqual(GuestOSDetector.detect(data: Data([0x51, 0x46])), .notQcow2)
    }

    func testValidQcow2WithNoKnownBannerIsUnrecognized() {
        // qcow2 magic, header with a zero L1 table (no clusters to be compressed),
        // and a payload that matches none of our signatures.
        let d = fakeQcow2(payload: "some BYO Linux image with no Sun banner")
        XCTAssertEqual(GuestOSDetector.detect(data: d), .unrecognized)
    }

    func testCompressedClusterIsReportedNotGuessed() {
        // Hand-build a qcow2 whose one populated L2 entry has the compressed flag
        // (bit 62) set, and whose payload deliberately lacks any banner. The
        // detector must report `.compressed`, not `.unrecognized`.
        //
        // Header layout (big-endian): cluster_bits @20, l1_size @36, l1_offset @40.
        var d = Data([0x51, 0x46, 0x49, 0xFB])          // magic
        d.append(contentsOf: [0, 0, 0, 3])              // version 3 @4
        d.append(contentsOf: [UInt8](repeating: 0, count: 72 - d.count))  // zero to 72
        func putBE32(_ v: UInt32, at off: Int) {
            d[off] = UInt8(v >> 24 & 0xFF); d[off+1] = UInt8(v >> 16 & 0xFF)
            d[off+2] = UInt8(v >> 8 & 0xFF); d[off+3] = UInt8(v & 0xFF)
        }
        func putBE64(_ v: UInt64, at off: Int) {
            for k in 0..<8 { d[off+k] = UInt8((v >> (8 * (7 - k))) & 0xFF) }
        }
        // cluster_bits = 9 -> 512-byte clusters -> 64 L2 entries per table.
        putBE32(9, at: 20)
        putBE32(1, at: 36)               // l1_size = 1 entry
        putBE64(512, at: 40)             // l1_table_offset = 512

        // Grow to hold the L1 table (@512) and the L2 table (@1024, 512 bytes).
        d.append(contentsOf: [UInt8](repeating: 0, count: 1024 + 512 - d.count))
        // L1[0] -> L2 table at offset 1024 (offset bits masked by 0x00ff...fe00).
        putBE64(1024, at: 512)
        // L2[0] with bit 62 (compressed) set.
        putBE64(0x4000_0000_0000_0000, at: 1024)

        XCTAssertEqual(GuestOSDetector.detect(data: d), .compressed)
    }

    func testUnreadablePathIsHandledCleanly() {
        XCTAssertEqual(GuestOSDetector.detect(imagePath: "/no/such/image.qcow2"), .unreadable)
        XCTAssertEqual(GuestOSDetector.detect(imagePath: ""), .unreadable)
    }
}
