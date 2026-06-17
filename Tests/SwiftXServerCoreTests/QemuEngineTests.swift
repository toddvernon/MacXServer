import XCTest
@testable import SwiftXServerCore

final class QemuEngineTests: XCTestCase {

    private func cfg(memoryMB: Int = 128) -> QemuEngineConfig {
        QemuEngineConfig(
            helper: URL(fileURLWithPath: "/Apps/MacXServer.app/Contents/Helpers/qemu-system-sparc"),
            firmwareDir: URL(fileURLWithPath: "/Apps/MacXServer.app/Contents/Resources/qemu-firmware"),
            diskImage: URL(fileURLWithPath: "/Users/x/Library/Application Support/macXserver/solaris-2.6.qcow2"),
            memoryMB: memoryMB
        )
    }

    /// Pin the exact argv. The shape is load-bearing: -M SS-5 is the machine,
    /// -nographic routes the serial console to stdio (what the observation
    /// window reads), -L points at the bundled ROM (the binary's default
    /// firmware path is a dead build-tree path on a customer machine), the
    /// lance NIC matches Solaris's le0, and the hostfwd opens the telnet port
    /// the launcher dials.
    func testBuildArgumentsShape() {
        let args = QemuEngine.buildArguments(config: cfg())
        XCTAssertEqual(args, [
            "-M", "SS-5",
            "-m", "128",
            "-nographic",
            "-L", "/Apps/MacXServer.app/Contents/Resources/qemu-firmware",
            "-prom-env", "input-device=ttya",
            "-prom-env", "output-device=ttya",
            "-nic", "user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp::2123-:23,hostfwd=tcp::2222-:22",
            "-drive", "file=/Users/x/Library/Application Support/macXserver/solaris-2.6.qcow2,bus=0,unit=0,media=disk",
        ])
    }

    func testMemoryIsHonored() {
        let args = QemuEngine.buildArguments(config: cfg(memoryMB: 256))
        XCTAssertEqual(args[args.firstIndex(of: "-m")! + 1], "256")
    }

    /// Engine-dir override builds helper + firmware from the dist layout.
    func testDevEngineDirOverride() {
        withEnv(["SPARCPLUG_ENGINE_DIR": "/dev/SPARCplug/dist",
                     "SPARCPLUG_DISK_IMAGE": "/dev/SPARCplug/SUN40G.qcow2"]) {
            let c = QemuEngine.defaultConfig()
            XCTAssertEqual(c.helper.path, "/dev/SPARCplug/dist/qemu-system-sparc")
            XCTAssertEqual(c.firmwareDir.path, "/dev/SPARCplug/dist/firmware")
            XCTAssertEqual(c.diskImage.path, "/dev/SPARCplug/SUN40G.qcow2")
        }
    }

    /// Without overrides, paths resolve against the bundle and Application Support.
    func testBundleLayoutResolution() {
        withEnv(["SPARCPLUG_ENGINE_DIR": nil, "SPARCPLUG_DISK_IMAGE": nil]) {
            let bundle = Bundle(path: "/tmp/Fake.app") ?? .main
            let c = QemuEngine.defaultConfig(bundle: bundle)
            XCTAssertTrue(c.helper.path.hasSuffix("/Contents/Helpers/qemu-system-sparc"), c.helper.path)
            XCTAssertTrue(c.firmwareDir.path.hasSuffix("/Contents/Resources/qemu-firmware"), c.firmwareDir.path)
            XCTAssertTrue(c.diskImage.path.hasSuffix("/macXserver/solaris-2.6.qcow2"), c.diskImage.path)
        }
    }

    /// State is notInstalled when the disk image is absent, stopped when present.
    func testStateReflectsDiskImagePresence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qemu-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let img = tmp.appendingPathComponent("solaris-2.6.qcow2")
        let c = QemuEngineConfig(
            helper: tmp.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: tmp.appendingPathComponent("firmware"),
            diskImage: img)
        let engine = QemuEngine(config: c)

        XCTAssertEqual(engine.state, .notInstalled)
        FileManager.default.createFile(atPath: img.path, contents: Data("x".utf8))
        XCTAssertEqual(engine.state, .stopped)
    }

    /// Live test: spawn the real bundled engine and confirm the controller
    /// streams its serial console and tracks running -> stopped. Gated behind
    /// SPARCPLUG_LIVE_TEST because it needs the built dist/ and runs qemu.
    /// Uses a throwaway empty disk so it never touches a real qcow2: qemu
    /// boots OpenBIOS, finds no OS, and sits in firmware emitting console
    /// output, which is all we need to prove spawn + stream + state.
    ///
    ///   SPARCPLUG_LIVE_TEST=1 SPARCPLUG_ENGINE_DIR=~/dev/SPARCplug/dist \
    ///     swift test --filter testLiveBootStreamsConsole
    func testLiveBootStreamsConsole() throws {
        guard ProcessInfo.processInfo.environment["SPARCPLUG_LIVE_TEST"] != nil,
              let dir = ProcessInfo.processInfo.environment["SPARCPLUG_ENGINE_DIR"], !dir.isEmpty
        else { throw XCTSkip("set SPARCPLUG_LIVE_TEST=1 and SPARCPLUG_ENGINE_DIR to run") }

        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qemu-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 64 MB sparse throwaway disk (no OS) so we never mutate a real image.
        let disk = tmp.appendingPathComponent("throwaway.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let fh = try FileHandle(forWritingTo: disk)
        try fh.truncate(atOffset: 64 * 1024 * 1024)
        try fh.close()

        let config = QemuEngineConfig(
            helper: base.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: base.appendingPathComponent("firmware", isDirectory: true),
            diskImage: disk)
        let engine = QemuEngine(config: config)

        let lock = NSLock()
        var console = ""
        let sawConsole = expectation(description: "console output")
        sawConsole.assertForOverFulfill = false
        engine.onConsole { chunk in
            lock.lock(); console += chunk; let hit = console.contains("SPARC") || console.contains("Probing"); lock.unlock()
            if hit { sawConsole.fulfill() }
        }
        let sawStopped = expectation(description: "stopped after terminate")
        sawStopped.assertForOverFulfill = false
        engine.onStateChange { state in if state != .running { sawStopped.fulfill() } }

        try engine.start()
        XCTAssertEqual(engine.state, .running)

        wait(for: [sawConsole], timeout: 30)
        engine.kill()
        wait(for: [sawStopped], timeout: 10)
        XCTAssertNotEqual(engine.state, .running)
    }

    /// Live test: boot the real image, let auto-login happen, then drive a
    /// graceful `init 5` shutdown and assert the clean-halt signal and process
    /// termination both fire. Uses an APFS clone of the image so the master is
    /// never mutated. Gated like the other live test, plus needs the real
    /// SPARCPLUG_DISK_IMAGE (a bootable Solaris qcow2).
    ///
    ///   SPARCPLUG_LIVE_TEST=1 SPARCPLUG_ENGINE_DIR=~/dev/SPARCplug/dist \
    ///   SPARCPLUG_DISK_IMAGE=~/Dropbox/dev/SPARCplug/SUN40G.qcow2 \
    ///     swift test --filter testLiveGracefulShutdown
    func testLiveGracefulShutdown() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SPARCPLUG_LIVE_TEST"] != nil,
              let dir = env["SPARCPLUG_ENGINE_DIR"], !dir.isEmpty,
              let img = env["SPARCPLUG_DISK_IMAGE"], !img.isEmpty
        else { throw XCTSkip("set SPARCPLUG_LIVE_TEST=1, SPARCPLUG_ENGINE_DIR, SPARCPLUG_DISK_IMAGE") }

        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qemu-graceful-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // APFS clonefile: instant, copy-on-write, master untouched.
        let work = tmp.appendingPathComponent("work.qcow2")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: img), to: work)

        let config = QemuEngineConfig(
            helper: base.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: base.appendingPathComponent("firmware", isDirectory: true),
            diskImage: work)
        let engine = QemuEngine(config: config)

        let cleanHalt = expectation(description: "clean halt marker")
        let terminated = expectation(description: "process terminated")
        engine.onCleanHalt { cleanHalt.fulfill() }
        engine.onTerminated { _ in terminated.fulfill() }

        // Once the login prompt appears, the engine auto-logs-in as root; give
        // the shell a few seconds to settle, then request graceful shutdown.
        let lock = NSLock()
        var buf = ""
        var triggered = false
        engine.onConsole { chunk in
            lock.lock()
            buf += chunk
            let fire = !triggered && buf.contains("login:")
            if fire { triggered = true }
            lock.unlock()
            if fire {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { engine.shutDown() }
            }
        }

        try engine.start()
        wait(for: [cleanHalt], timeout: 200)   // boot + auto-login + init 5 + sync
        wait(for: [terminated], timeout: 30)    // power-off -> qemu exits
        XCTAssertEqual(engine.state, .stopped)
    }

    // MARK: - helpers

    /// Set/clear env vars around a block. A nil value unsets the var.
    private func withEnv(_ vars: [String: String?], _ body: () throws -> Void) rethrows {
        let saved = vars.keys.reduce(into: [String: String?]()) { $0[$1] = ProcessInfo.processInfo.environment[$1] }
        for (k, v) in vars {
            if let v = v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        defer {
            for (k, v) in saved {
                if let v = v { setenv(k, v, 1) } else { unsetenv(k) }
            }
        }
        try body()
    }
}
