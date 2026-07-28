import Foundation

/// The curated-image catalog the downloader consumes: one `catalog.json` at a
/// pinned URL, one entry per curated guest OS. Fetched on demand when the user
/// clicks Download — no background polling, no telemetry. Entries are keyed by
/// `MachineOS` raw value, the same key the bundled fixtures carry, which is
/// what makes wrong-image-to-wrong-machine impossible in the download path:
/// the Download button on the Solaris fixture can only ever fetch the
/// `solaris26` entry. Design: IMAGE_DOWNLOAD_PLAN.md.
public struct ImageCatalog: Equatable, Sendable {

    /// One downloadable image. Both checksums on purpose: `sha256Gz` catches a
    /// corrupt download before we spend the decompress; `sha256` catches a
    /// truncated/bad gunzip (the 2026-07-04 NAS lesson: size-correct files can
    /// still be silently corrupt — never trust size).
    public struct Entry: Codable, Equatable, Sendable {
        public let os: MachineOS
        /// Catalog release stamp for this image, e.g. "2026.07". Informational
        /// in v1 (no update checking).
        public let version: String
        /// The gzipped qcow2 payload.
        public let url: URL
        public let sizeGz: Int64
        public let sha256Gz: String
        /// Decompressed size + checksum.
        public let size: Int64
        public let sha256: String
        /// One human line for the confirm sheet ("Solaris 2.6 + CDE, helios
        /// agent installed").
        public let notes: String?
        /// The account names that actually exist on this image, captured from
        /// its passwd file by strip-release.sh after the publish surgery
        /// (root + stock system accounts on a published image). The install
        /// wizard validates the typed username against THIS, not a
        /// hand-maintained guess -- only names that really exist can collide.
        /// nil (an older catalog): the wizard falls back to the static
        /// UserAdmin.reservedNames list.
        public let reservedUsernames: [String]?

        public init(os: MachineOS, version: String, url: URL,
                    sizeGz: Int64, sha256Gz: String,
                    size: Int64, sha256: String, notes: String? = nil,
                    reservedUsernames: [String]? = nil) {
            self.os = os; self.version = version; self.url = url
            self.sizeGz = sizeGz; self.sha256Gz = sha256Gz
            self.size = size; self.sha256 = sha256; self.notes = notes
            self.reservedUsernames = reservedUsernames
        }
    }

    public let formatVersion: Int
    public let images: [Entry]

    public init(formatVersion: Int = 1, images: [Entry]) {
        self.formatVersion = formatVersion
        self.images = images
    }

    /// The catalog entry for a guest OS, or nil when the catalog doesn't carry
    /// one (BYO-image only for that OS).
    public func entry(for os: MachineOS) -> Entry? {
        images.first { $0.os == os }
    }

    // MARK: - Where the catalog lives

    /// The pinned production catalog URL (Todd, 2026-07-15: the index lives
    /// in the public macxserver-images repo, so the raw URL is stable across
    /// image releases; the payloads are that repo's release assets, which the
    /// catalog entries point at). See DECISIONS 2026-07-15.
    public static let defaultURL = URL(string:
        "https://raw.githubusercontent.com/toddvernon/macxserver-images/main/catalog.json")!

    /// Test hook only: substitutes the home directory the dev-catalog path
    /// derives from, so the dotfile behavior is testable without touching
    /// the real `~`. (unsafe is fine: set once at the top of a serial test,
    /// never from production code.)
    nonisolated(unsafe) internal static var homeOverride: String?

    /// The dev-catalog dotfile (Todd, 2026-07-16): a catalog at this path is
    /// used by DEBUG builds instead of the production URL, so running from
    /// Xcode against a locally-built catalog needs no env var and no scheme
    /// surgery. `build-catalog.sh --local` (SPARCplug repo) symlinks it at
    /// the staging catalog it emits; `rm` the symlink to go back to the real
    /// catalog. Same convention as `.macxserver-dev-secrets.json`.
    public static var devCatalogFileURL: URL {
        URL(fileURLWithPath: homeOverride ?? NSHomeDirectory())
            .appendingPathComponent(".macxserver-dev-catalog.json")
    }

    /// True when a fetch will read the dev-catalog dotfile. Always false in
    /// Release builds -- the conditional is compiled out, so a shipped app
    /// can never be redirected by a stray file on a stranger's Mac.
    public static var devCatalogActive: Bool {
        #if DEBUG
        return FileManager.default.fileExists(atPath: devCatalogFileURL.path)
        #else
        return false
        #endif
    }

    /// The effective catalog URL, in precedence order: the explicit
    /// `SPARCPLUG_CATALOG_URL` env override (tests; same pattern as
    /// `SPARCPLUG_ENGINE_DIR`), the dev-catalog dotfile (DEBUG builds only),
    /// then the pinned production URL.
    public static var catalogURL: URL {
        if let s = ProcessInfo.processInfo.environment["SPARCPLUG_CATALOG_URL"],
           !s.isEmpty, let u = URL(string: s) {
            return u
        }
        #if DEBUG
        if devCatalogActive { return devCatalogFileURL }
        #endif
        return defaultURL
    }

    // MARK: - Fetch

    /// Fetch and decode the catalog. Small JSON; used at Download-click time
    /// only. Works against `file://` URLs so tests never touch the network.
    public static func fetch(from url: URL = catalogURL) async throws -> ImageCatalog {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw ImageDownloadError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ImageCatalog.self, from: data)
    }
}

extension ImageCatalog: Decodable {
    enum CodingKeys: String, CodingKey { case formatVersion, images }

    /// Forgiving decode: an entry this build can't understand (a future
    /// catalog adds an OS we don't profile yet) is skipped, not fatal — the
    /// entries we DO know stay downloadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        images = try c.decode([Failable<Entry>].self, forKey: .images)
            .compactMap(\.value)
    }
}

/// Wraps a decode so one bad element drops out instead of failing the array.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
