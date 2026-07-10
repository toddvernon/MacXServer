import XCTest
import CryptoKit
@testable import SwiftXServerCore

/// Pipeline tests against file:// fixtures — no network, tiny payloads. The
/// fixture is a fake qcow2 (magic + banner, same trick as GuestOSDetectorTests)
/// gzipped with the system gzip, with real checksums, so the happy path runs
/// every verification for real and the failure paths corrupt exactly one link
/// in the chain.
final class ImageDownloaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixture plumbing

    /// A minimal fake qcow2 with a Solaris banner in its payload.
    private func fakeQcow2(banner: String) -> Data {
        var d = Data([0x51, 0x46, 0x49, 0xFB])          // "QFI\xFB"
        d.append(contentsOf: [0, 0, 0, 3])              // version 3
        d.append(contentsOf: [UInt8](repeating: 0, count: 72 - d.count))
        d.append(contentsOf: Array("boot: \(banner) (GENERIC)".utf8))
        return d
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Write the image, gzip it, and build a truthful catalog entry pointing
    /// at the gz via file://. Returns (entry, destination URL).
    private func makeFixture(banner: String = "SunOS Release 5.6",
                             os: MachineOS = .solaris26,
                             corruptGzSha: Bool = false,
                             corruptImageSha: Bool = false)
        throws -> (entry: ImageCatalog.Entry, destination: URL)
    {
        let image = fakeQcow2(banner: banner)
        let rawFile = dir.appendingPathComponent("payload.qcow2")
        try image.write(to: rawFile)

        // System gzip: -k keeps the original for hashing, -f overwrites.
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-kf", rawFile.path]
        try gzip.run()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
        let gzFile = dir.appendingPathComponent("payload.qcow2.gz")
        let gzData = try Data(contentsOf: gzFile)

        let entry = ImageCatalog.Entry(
            os: os, version: "test",
            url: gzFile,
            sizeGz: Int64(gzData.count),
            sha256Gz: corruptGzSha ? "0000" : sha256Hex(gzData),
            size: Int64(image.count),
            sha256: corruptImageSha ? "0000" : sha256Hex(image))
        return (entry, dir.appendingPathComponent("installed.qcow2"))
    }

    /// No partials: the install's temp siblings must be gone.
    private func assertNoPartials(near destination: URL) {
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: destination.path + ".download.gz"))
        XCTAssertFalse(fm.fileExists(atPath: destination.path + ".download"))
    }

    // MARK: Tests

    func testHappyPathInstallsAndReportsPhases() async throws {
        let (entry, dest) = try makeFixture()

        let phases = PhaseCollector()
        try await ImageDownloader.install(entry: entry, destination: dest,
                                          expectedOS: .solaris26,
                                          onPhase: { phases.append($0) })

        // Installed, byte-identical to the original image.
        let installed = try Data(contentsOf: dest)
        XCTAssertEqual(sha256Hex(installed), entry.sha256)
        assertNoPartials(near: dest)

        // Every phase reported, in pipeline order. (Callbacks land on the
        // main queue; drain it before asserting.)
        await MainActor.run {}
        let seen = phases.snapshot()
        XCTAssertEqual(seen.first, .downloading(fraction: 0))
        let nonDownload = seen.filter {
            if case .downloading = $0 { return false } else { return true }
        }
        XCTAssertEqual(nonDownload, [.verifyingDownload, .decompressing,
                                     .verifyingImage, .installing])
    }

    func testCorruptDownloadChecksumFailsCleanly() async throws {
        let (entry, dest) = try makeFixture(corruptGzSha: true)
        await assertThrows(entry: entry, dest: dest, expected: .solaris26,
                           .checksumMismatch(what: "downloaded file"))
        assertNoPartials(near: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testCorruptImageChecksumFailsCleanly() async throws {
        let (entry, dest) = try makeFixture(corruptImageSha: true)
        await assertThrows(entry: entry, dest: dest, expected: .solaris26,
                           .checksumMismatch(what: "decompressed image"))
        assertNoPartials(near: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testWrongGuestBannerFailsCleanly() async throws {
        // The catalog claims solaris26 but the payload is NetBSD: checksums
        // pass (they're truthful), the banner check must catch it.
        let (entry, dest) = try makeFixture(banner: "NetBSD 9.2", os: .solaris26)
        do {
            try await ImageDownloader.install(entry: entry, destination: dest,
                                              expectedOS: .solaris26,
                                              onPhase: { _ in })
            XCTFail("expected wrongGuest")
        } catch let e as ImageDownloadError {
            guard case .wrongGuest(let expected, _) = e else {
                return XCTFail("expected wrongGuest, got \(e)")
            }
            XCTAssertEqual(expected, .solaris26)
        }
        assertNoPartials(near: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRefusesToClobberAnExistingImage() async throws {
        let (entry, dest) = try makeFixture()
        try Data("someone's disk state".utf8).write(to: dest)
        await assertThrows(entry: entry, dest: dest, expected: .solaris26,
                           .destinationExists(dest.path))
        // The existing file is untouched.
        XCTAssertEqual(try Data(contentsOf: dest),
                       Data("someone's disk state".utf8))
    }

    func testStalePartialsAreSweptBeforeAFreshRun() async throws {
        // A crashed prior run left temp siblings; a new install must succeed.
        let (entry, dest) = try makeFixture()
        try Data("stale".utf8).write(to: URL(fileURLWithPath: dest.path + ".download.gz"))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: dest.path + ".download"))
        try await ImageDownloader.install(entry: entry, destination: dest,
                                          expectedOS: .solaris26,
                                          onPhase: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        assertNoPartials(near: dest)
    }

    func testImageFilenames() {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        XCTAssertEqual(
            ImageDownloader.imageFilename(os: .netbsd, machineID: id, bundled: true),
            "netbsd-boot.qcow2")
        XCTAssertEqual(
            ImageDownloader.imageFilename(os: .netbsd, machineID: id, bundled: false),
            "netbsd-abcdef01.qcow2")
        // Identity-derived, not name-derived: same machine, same filename.
        XCTAssertEqual(
            ImageDownloader.imageFilename(os: .solaris26, machineID: id, bundled: false),
            "solaris26-abcdef01.qcow2")
    }

    func testSha256HexMatchesCryptoKit() throws {
        let file = dir.appendingPathComponent("hash-me")
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })  // > 1 chunk
        try data.write(to: file)
        XCTAssertEqual(try ImageDownloader.sha256Hex(of: file), sha256Hex(data))
    }

    func testFullFlowCatalogFetchToInstalledImage() async throws {
        // The whole app-side seam in one pass: a catalog.json on disk (what
        // build-catalog.sh emits) → fetch → entry(for:) → install → the
        // detector agrees with the machine's OS. This is exactly what the
        // Download… button drives, minus the NSAlert.
        let (entry, dest) = try makeFixture(banner: "NetBSD 9.2", os: .netbsd)
        let catalogFile = dir.appendingPathComponent("catalog.json")
        let json = """
        { "formatVersion": 1,
          "images": [
            { "os": "netbsd", "version": "test",
              "url": "\(entry.url.absoluteString)",
              "sizeGz": \(entry.sizeGz), "sha256Gz": "\(entry.sha256Gz)",
              "size": \(entry.size), "sha256": "\(entry.sha256)" }
          ] }
        """
        try Data(json.utf8).write(to: catalogFile)

        let catalog = try await ImageCatalog.fetch(from: catalogFile)
        let fetched = try XCTUnwrap(catalog.entry(for: .netbsd))
        try await ImageDownloader.install(entry: fetched, destination: dest,
                                          expectedOS: .netbsd, onPhase: { _ in })
        XCTAssertEqual(GuestOSDetector.detect(imagePath: dest.path).os, .netbsd)
    }

    // MARK: Helpers

    private func assertThrows(entry: ImageCatalog.Entry, dest: URL,
                              expected os: MachineOS,
                              _ want: ImageDownloadError,
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
        do {
            try await ImageDownloader.install(entry: entry, destination: dest,
                                              expectedOS: os, onPhase: { _ in })
            XCTFail("expected \(want)", file: file, line: line)
        } catch let e as ImageDownloadError {
            XCTAssertEqual(e, want, file: file, line: line)
        } catch {
            XCTFail("expected ImageDownloadError, got \(error)",
                    file: file, line: line)
        }
    }
}

/// Thread-safe phase sink (callbacks land on the main queue; the test awaits
/// a main-queue drain before reading).
private final class PhaseCollector: @unchecked Sendable {
    private var phases: [ImageDownloadPhase] = []
    private let lock = NSLock()
    func append(_ p: ImageDownloadPhase) {
        lock.lock(); defer { lock.unlock() }
        phases.append(p)
    }
    func snapshot() -> [ImageDownloadPhase] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }
}
