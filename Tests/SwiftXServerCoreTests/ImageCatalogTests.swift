import XCTest
@testable import SwiftXServerCore

final class ImageCatalogTests: XCTestCase {

    /// The catalog JSON shape from IMAGE_DOWNLOAD_PLAN.md, verbatim.
    private let sampleJSON = """
    { "formatVersion": 1,
      "images": [
        { "os": "solaris26",
          "version": "2026.07",
          "url": "https://macxserver.com/images/solaris26-boot.qcow2.gz",
          "sizeGz": 262144000, "sha256Gz": "aa11",
          "size": 1395864371, "sha256": "bb22",
          "notes": "Solaris 2.6 + CDE, helios agent installed" },
        { "os": "netbsd",
          "version": "2026.07",
          "url": "https://macxserver.com/images/netbsd-boot.qcow2.gz",
          "sizeGz": 200000000, "sha256Gz": "cc33",
          "size": 1200000000, "sha256": "dd44" }
      ] }
    """

    func testDecodesTheDocumentedShape() throws {
        let catalog = try JSONDecoder().decode(ImageCatalog.self,
                                               from: Data(sampleJSON.utf8))
        XCTAssertEqual(catalog.formatVersion, 1)
        XCTAssertEqual(catalog.images.count, 2)

        let solaris = try XCTUnwrap(catalog.entry(for: .solaris26))
        XCTAssertEqual(solaris.version, "2026.07")
        XCTAssertEqual(solaris.sizeGz, 262_144_000)
        XCTAssertEqual(solaris.sha256Gz, "aa11")
        XCTAssertEqual(solaris.size, 1_395_864_371)
        XCTAssertEqual(solaris.sha256, "bb22")
        XCTAssertEqual(solaris.notes, "Solaris 2.6 + CDE, helios agent installed")

        // notes is optional; an OS not in the catalog has no entry.
        let netbsd = try XCTUnwrap(catalog.entry(for: .netbsd))
        XCTAssertNil(netbsd.notes)
        XCTAssertNil(catalog.entry(for: .sunos414))
    }

    func testUnknownOSEntryIsSkippedNotFatal() throws {
        // A future catalog carries an OS this build doesn't profile. The
        // known entries must survive the decode.
        let json = """
        { "formatVersion": 1,
          "images": [
            { "os": "irix65", "version": "2027.01",
              "url": "https://macxserver.com/images/irix.gz",
              "sizeGz": 1, "sha256Gz": "x", "size": 1, "sha256": "y" },
            { "os": "netbsd", "version": "2026.07",
              "url": "https://macxserver.com/images/netbsd-boot.qcow2.gz",
              "sizeGz": 2, "sha256Gz": "a", "size": 3, "sha256": "b" }
          ] }
        """
        let catalog = try JSONDecoder().decode(ImageCatalog.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(catalog.images.count, 1)
        XCTAssertNotNil(catalog.entry(for: .netbsd))
    }

    func testFetchFromFileURL() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("catalog.json")
        try Data(sampleJSON.utf8).write(to: file)

        let catalog = try await ImageCatalog.fetch(from: file)
        XCTAssertEqual(catalog.images.count, 2)
    }

    func testDevCatalogDotfileDrivesTheCatalogURLInDebugBuilds() throws {
        #if DEBUG
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgcat-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home,
                                                withIntermediateDirectories: true)
        defer {
            ImageCatalog.homeOverride = nil
            try? FileManager.default.removeItem(at: home)
        }
        ImageCatalog.homeOverride = home.path

        // The env override outranks the dotfile, so the URL assertions only
        // hold when the runner didn't set one.
        let envSet = !(ProcessInfo.processInfo
            .environment["SPARCPLUG_CATALOG_URL"] ?? "").isEmpty

        // No dotfile: not active, production URL.
        XCTAssertFalse(ImageCatalog.devCatalogActive)
        if !envSet {
            XCTAssertEqual(ImageCatalog.catalogURL, ImageCatalog.defaultURL)
        }

        // Dotfile present: active, and (absent the env override) it IS the
        // catalog URL.
        try Data("{}".utf8).write(
            to: home.appendingPathComponent(".macxserver-dev-catalog.json"))
        XCTAssertTrue(ImageCatalog.devCatalogActive)
        if !envSet {
            XCTAssertEqual(ImageCatalog.catalogURL,
                           ImageCatalog.devCatalogFileURL)
        }
        #endif
    }

    func testCatalogURLDefaultsToThePinnedProductionURL() {
        // (The env override can't be exercised here — setenv after process
        // start isn't visible to ProcessInfo caching on all runners — but the
        // pinned default is load-bearing: it's what ships.)
        XCTAssertEqual(ImageCatalog.defaultURL.absoluteString,
                       "https://raw.githubusercontent.com/toddvernon/"
                       + "macxserver-images/main/catalog.json")
    }
}
