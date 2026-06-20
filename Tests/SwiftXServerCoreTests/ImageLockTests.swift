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
