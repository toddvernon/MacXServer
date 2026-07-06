import XCTest
@testable import SwiftXServerCore

final class ImageLockTests: XCTestCase {

    private var tmp: URL!
    private var image: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imagelock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        image = tmp.appendingPathComponent("SUN40G.qcow2")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLockPathIsSidecar() {
        XCTAssertEqual(ImageLockManager.lockURL(for: image).lastPathComponent,
                       "SUN40G.qcow2.macxserver-lock")
    }

    func testNoLockIsFree() {
        XCTAssertEqual(ImageLockManager.evaluate(imageURL: image, host: "MacA"), .free)
    }

    func testSerializeParseRoundTrip() {
        let lock = ImageLock(host: "MacA", pid: 4242,
                             imagePath: image.path, startedAt: "2026-06-20T15:00:00Z",
                             appVersion: "0.1.0")
        XCTAssertEqual(ImageLock.parse(lock.serialized()), lock)
    }

    func testParseRequiresHostAndPid() {
        XCTAssertNil(ImageLock.parse("image: /x\nstarted: now"))     // no host/pid
        XCTAssertNil(ImageLock.parse("host: MacA\npid: notanumber")) // bad pid
        XCTAssertNotNil(ImageLock.parse("host: MacA\npid: 7"))       // minimal ok
    }

    // The per-boot Helios secret round-trips so an orphan shutdown can authenticate.
    func testSecretRoundTripsAndIsOptional() {
        let withSecret = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                                   startedAt: "2026-06-24T19:00:00Z", appVersion: "dev",
                                   secret: "deadbeefcafe")
        let reparsed = ImageLock.parse(withSecret.serialized())
        XCTAssertEqual(reparsed?.secret, "deadbeefcafe")
        XCTAssertEqual(reparsed, withSecret)

        // No secret: the line is omitted, and an older secret-less lock parses to nil.
        let noSecret = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                                 startedAt: "2026-06-24T19:00:00Z", appVersion: "dev")
        XCTAssertFalse(noSecret.serialized().contains("secret:"))
        XCTAssertNil(ImageLock.parse("host: MacA\npid: 7")?.secret)
    }

    // The QMP + console socket paths round-trip (VM_CONTROL.md Stage 3,
    // "lock-as-VM-handle") and are optional, so older locks still parse.
    func testSocketPathsRoundTripAndAreOptional() {
        let withSockets = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                                    startedAt: "2026-06-25T19:00:00Z", appVersion: "dev",
                                    secret: "abc123",
                                    qmpSocketPath: "/tmp/macxserver-qmp-1234.sock",
                                    consoleSocketPath: "/tmp/macxserver-con-1234.sock")
        let reparsed = ImageLock.parse(withSockets.serialized())
        XCTAssertEqual(reparsed?.qmpSocketPath, "/tmp/macxserver-qmp-1234.sock")
        XCTAssertEqual(reparsed?.consoleSocketPath, "/tmp/macxserver-con-1234.sock")
        XCTAssertEqual(reparsed, withSockets)

        // Omitted when absent, and older socket-less locks parse to nil.
        let noSockets = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                                  startedAt: "2026-06-25T19:00:00Z", appVersion: "dev")
        XCTAssertFalse(noSockets.serialized().contains("qmp:"))
        XCTAssertFalse(noSockets.serialized().contains("console:"))
        let older = ImageLock.parse("host: MacA\npid: 7")
        XCTAssertNil(older?.qmpSocketPath)
        XCTAssertNil(older?.consoleSocketPath)
    }

    // acquire() persists the socket paths so a later process can pick up the
    // VM handle.
    func testAcquireWritesSocketPaths() {
        ImageLockManager.acquire(imageURL: image, pid: 321, appVersion: "9",
                                 secret: "s", qmpSocketPath: "/tmp/q.sock",
                                 consoleSocketPath: "/tmp/c.sock", host: "MacA")
        let text = try! String(contentsOf: ImageLockManager.lockURL(for: image), encoding: .utf8)
        let lock = ImageLock.parse(text)
        XCTAssertEqual(lock?.qmpSocketPath, "/tmp/q.sock")
        XCTAssertEqual(lock?.consoleSocketPath, "/tmp/c.sock")
    }

    // The helios hostfwd port rides in the lock (P2): with the secret it makes
    // the lock a complete handle for reaching the guest's daemon -- orphan
    // recovery on a non-Solaris guest needs it, and it's the interim channel
    // for Claude-side tooling until the MCP bridge lands.
    func testHeliosPortRoundTripsAndIsOptional() {
        let with = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                             startedAt: "2026-07-06T10:00:00Z", appVersion: "dev",
                             secret: "abc", heliosPort: 2135)
        let reparsed = ImageLock.parse(with.serialized())
        XCTAssertEqual(reparsed?.heliosPort, 2135)
        XCTAssertEqual(reparsed, with)

        // Omitted when absent; pre-P2 locks parse to nil (callers fall back to
        // the machine's current block).
        let without = ImageLock(host: "MacA", pid: 7, imagePath: image.path,
                                startedAt: "2026-07-06T10:00:00Z", appVersion: "dev")
        XCTAssertFalse(without.serialized().contains("heliosPort:"))
        XCTAssertNil(ImageLock.parse("host: MacA\npid: 7")?.heliosPort)

        ImageLockManager.acquire(imageURL: image, pid: 321, appVersion: "9",
                                 secret: "s", heliosPort: 2155, host: "MacA")
        let text2 = try! String(contentsOf: ImageLockManager.lockURL(for: image), encoding: .utf8)
        XCTAssertEqual(ImageLock.parse(text2)?.heliosPort, 2155)
    }

    /// A lock written by a different machine is a hard stop regardless of the
    /// recorded pid (we can't verify a remote pid).
    func testRemoteHostLocked() {
        write(ImageLock(host: "MacB", pid: 999, imagePath: image.path,
                        startedAt: "", appVersion: ""))
        let status = ImageLockManager.evaluate(
            imageURL: image, host: "MacA",
            isAlive: { _ in true }, isOurQemu: { _ in true })
        XCTAssertEqual(status, .remoteLocked(ImageLock(host: "MacB", pid: 999,
            imagePath: image.path, startedAt: "", appVersion: "")))
    }

    /// Same host, pid alive AND actually our qemu → real orphan.
    func testLocalOrphan() {
        write(ImageLock(host: "MacA", pid: 555, imagePath: image.path,
                        startedAt: "", appVersion: ""))
        let status = ImageLockManager.evaluate(
            imageURL: image, host: "MacA",
            isAlive: { $0 == 555 }, isOurQemu: { $0 == 555 })
        guard case .localOrphan(let lock) = status else {
            return XCTFail("expected localOrphan, got \(status)")
        }
        XCTAssertEqual(lock.pid, 555)
    }

    /// Same host but the pid is dead → stale, reclaimable.
    func testStaleSameHostWhenPidDead() {
        write(ImageLock(host: "MacA", pid: 555, imagePath: image.path,
                        startedAt: "", appVersion: ""))
        let status = ImageLockManager.evaluate(
            imageURL: image, host: "MacA",
            isAlive: { _ in false }, isOurQemu: { _ in true })
        guard case .staleSameHost = status else {
            return XCTFail("expected staleSameHost, got \(status)")
        }
    }

    /// Same host, pid alive but it's NOT our qemu (recycled pid) → stale, not
    /// an orphan — we must never treat someone else's process as the orphan.
    func testStaleWhenPidRecycledByOtherProcess() {
        write(ImageLock(host: "MacA", pid: 555, imagePath: image.path,
                        startedAt: "", appVersion: ""))
        let status = ImageLockManager.evaluate(
            imageURL: image, host: "MacA",
            isAlive: { _ in true }, isOurQemu: { _ in false })
        guard case .staleSameHost = status else {
            return XCTFail("expected staleSameHost, got \(status)")
        }
    }

    func testAcquireThenEvaluateSeesOurLock() {
        ImageLockManager.acquire(imageURL: image, pid: 321, appVersion: "9", host: "MacA")
        let status = ImageLockManager.evaluate(
            imageURL: image, host: "MacA",
            isAlive: { _ in true }, isOurQemu: { _ in true })
        guard case .localOrphan(let lock) = status else {
            return XCTFail("expected localOrphan, got \(status)")
        }
        XCTAssertEqual(lock.pid, 321)
        XCTAssertEqual(lock.host, "MacA")
    }

    func testReleaseRemovesOwnLockOnly() {
        // Our lock → released.
        ImageLockManager.acquire(imageURL: image, pid: 1, appVersion: "", host: "MacA")
        ImageLockManager.release(imageURL: image, host: "MacA")
        XCTAssertEqual(ImageLockManager.evaluate(imageURL: image, host: "MacA"), .free)

        // Another host's lock → NOT removed by our release.
        write(ImageLock(host: "MacB", pid: 2, imagePath: image.path,
                        startedAt: "", appVersion: ""))
        ImageLockManager.release(imageURL: image, host: "MacA")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ImageLockManager.lockURL(for: image).path))
    }

    private func write(_ lock: ImageLock) {
        try? lock.serialized().write(to: ImageLockManager.lockURL(for: image),
                                     atomically: true, encoding: .utf8)
    }
}
