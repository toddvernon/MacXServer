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
            "-prom-env", "ttya-mode=115200,8,n,1,-",
            "-nic", "user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp:127.0.0.1:2123-:23,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:2125-:2125",
            "-drive", "file=/Users/x/Library/Application Support/macXserver/solaris-2.6.qcow2,bus=0,unit=0,media=disk",
        ])
    }

    /// A non-default port block (e.g. SunOS 4.1.4) drives the hostfwd rules, so
    /// a second image can run alongside the bundled Solaris one without fighting
    /// over host ports. Default stays the Solaris block (pinned above).
    func testBuildArgumentsPerImagePorts() {
        var c = cfg()
        c.ports = .sunos414
        let nic = QemuEngine.buildArguments(config: c)[
            QemuEngine.buildArguments(config: c).firstIndex(of: "-nic")! + 1]
        XCTAssertEqual(nic,
            "user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp:127.0.0.1:2133-:23,hostfwd=tcp:127.0.0.1:2232-:22,hostfwd=tcp:127.0.0.1:2135-:2125")
        // The three OS blocks must not overlap, or concurrent images collide.
        let all = [ImagePorts.solaris26, .sunos414, .netbsd]
            .flatMap { [$0.telnet, $0.ssh, $0.helios] }
        XCTAssertEqual(Set(all).count, all.count, "ImagePorts blocks overlap")
    }

    /// The QMP control socket (VM_CONTROL.md Stage 1) is added only when a path
    /// is given, in server/no-wait mode; the default omits it (so existing argv
    /// is unchanged).
    func testBuildArgumentsQmpSocket() {
        let withQmp = QemuEngine.buildArguments(config: cfg(), qmpSocketPath: "/tmp/q.sock")
        let i = withQmp.firstIndex(of: "-qmp")
        XCTAssertNotNil(i, "expected a -qmp flag")
        XCTAssertEqual(withQmp[i! + 1], "unix:/tmp/q.sock,server=on,wait=off")

        XCTAssertFalse(QemuEngine.buildArguments(config: cfg()).contains("-qmp"),
                       "no -qmp when the path is omitted")
    }

    /// The serial-console socket (VM_CONTROL.md Stage 2) replaces `-nographic`
    /// with an explicit `-display none` + `-serial unix:...` + `-monitor none`
    /// when a path is given; the default keeps the legacy `-nographic` stdio form.
    func testBuildArgumentsConsoleSocket() {
        let withCon = QemuEngine.buildArguments(config: cfg(), consoleSocketPath: "/tmp/c.sock")
        XCTAssertFalse(withCon.contains("-nographic"),
                       "the socket console form drops -nographic")
        let i = withCon.firstIndex(of: "-serial")
        XCTAssertNotNil(i, "expected a -serial flag")
        XCTAssertEqual(withCon[i! + 1], "unix:/tmp/c.sock,server=on,wait=off")
        XCTAssertTrue(withCon.contains("-display") && withCon.contains("none"),
                      "headless: -display none")
        let m = withCon.firstIndex(of: "-monitor")
        XCTAssertNotNil(m, "expected a -monitor flag")
        XCTAssertEqual(withCon[m! + 1], "none", "HMP disabled; we drive via QMP")

        let plain = QemuEngine.buildArguments(config: cfg())
        XCTAssertTrue(plain.contains("-nographic"), "no console path -> legacy stdio console")
        XCTAssertFalse(plain.contains("-serial"))
    }

    /// Orphan QMP recovery (VM_CONTROL.md Stage 3): a fresh QmpClient connects to
    /// the socket path the lock recorded and issues `quit`, returning true. This
    /// is the qcow2-clean Force Quit a *different* process drives via the
    /// socket-in-lock -- no process handle, no guest, no network auth.
    func testQuitOrphanViaQmpSucceeds() throws {
        let server = try MockQmpServer { cmd, _ in
            if cmd["execute"] as? String == "qmp_capabilities" { return ["return": [:]] }
            return nil   // `quit`: send nothing, then the mock closes (mimics qemu exit)
        }
        defer { server.stop() }
        server.start()

        XCTAssertTrue(QemuEngine.quitOrphanViaQmp(qmpSocketPath: server.socketPath))
    }

    /// An empty or dead socket path returns false so the caller falls back to a
    /// verified SIGKILL.
    func testQuitOrphanViaQmpFailsForMissingSocket() {
        XCTAssertFalse(QemuEngine.quitOrphanViaQmp(qmpSocketPath: ""))
        XCTAssertFalse(QemuEngine.quitOrphanViaQmp(
            qmpSocketPath: "/tmp/qmp-orphan-missing-\(UUID().uuidString).sock"))
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

    /// Live test: simulate an orphan -- a qemu with a lock but NO controlling
    /// client (its parent macXserver "died", so the single-client QMP socket is
    /// free) -- then recover it the way a fresh macXserver process would: read the
    /// QMP socket path back out of the image lock (Stage 3 "lock-as-VM-handle")
    /// and clean-stop qemu through it. Asserts the process exits. Spawning qemu
    /// directly (not via QemuEngine) is deliberate: the engine would hold the QMP
    /// connection, which a real orphan's dead parent does not. Throwaway empty
    /// disk, gated like the other live tests.
    ///
    ///   SPARCPLUG_LIVE_TEST=1 SPARCPLUG_ENGINE_DIR=~/dev/SPARCplug/dist \
    ///     swift test --filter testLiveOrphanQmpQuitViaLock
    func testLiveOrphanQmpQuitViaLock() throws {
        guard ProcessInfo.processInfo.environment["SPARCPLUG_LIVE_TEST"] != nil,
              let dir = ProcessInfo.processInfo.environment["SPARCPLUG_ENGINE_DIR"], !dir.isEmpty
        else { throw XCTSkip("set SPARCPLUG_LIVE_TEST=1 and SPARCPLUG_ENGINE_DIR to run") }

        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qemu-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let disk = tmp.appendingPathComponent("throwaway.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let fh = try FileHandle(forWritingTo: disk)
        try fh.truncate(atOffset: 64 * 1024 * 1024)
        try fh.close()

        // Spawn qemu directly with explicit QMP + console socket paths -- an orphan
        // with no live controller. Console socket served but nobody attached.
        let qmpPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orphan-qmp-\(UUID().uuidString.prefix(8)).sock")
        let conPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orphan-con-\(UUID().uuidString.prefix(8)).sock")
        let config = QemuEngineConfig(
            helper: base.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: base.appendingPathComponent("firmware", isDirectory: true),
            diskImage: disk)
        let args = QemuEngine.buildArguments(config: config,
                                             qmpSocketPath: qmpPath, consoleSocketPath: conPath)
        let p = Process()
        p.executableURL = config.helper
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let terminated = expectation(description: "orphan qemu terminated")
        p.terminationHandler = { _ in terminated.fulfill() }
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }

        // Write the lock the way QemuEngine.start() does (the VM handle).
        ImageLockManager.acquire(imageURL: disk, pid: p.processIdentifier, appVersion: "test",
                                 qmpSocketPath: qmpPath, consoleSocketPath: conPath, host: "TestHost")
        defer { ImageLockManager.forceRemove(imageURL: disk) }

        // Recover: read the QMP path back out of the lock, then clean-stop.
        let text = try String(contentsOf: ImageLockManager.lockURL(for: disk), encoding: .utf8)
        let recoveredPath = try XCTUnwrap(ImageLock.parse(text)?.qmpSocketPath,
                                          "the lock should record the QMP socket path")
        // qemu opens the QMP socket during early startup; give it a moment.
        var quit = false
        let connectDeadline = Date().addingTimeInterval(8)
        while Date() < connectDeadline {
            if QemuEngine.quitOrphanViaQmp(qmpSocketPath: recoveredPath) { quit = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(quit, "a fresh QMP client should clean-stop the orphan via the socket-in-lock")
        wait(for: [terminated], timeout: 10)
        XCTAssertFalse(p.isRunning)
    }

    /// attach() refuses an orphan that isn't actually alive -- nothing to adopt,
    /// so the engine stays stopped. (pid 0 never passes the liveness guard.)
    func testAttachRejectsDeadOrphan() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attach-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let img = tmp.appendingPathComponent("solaris-2.6.qcow2")
        FileManager.default.createFile(atPath: img.path, contents: Data("x".utf8))

        let engine = QemuEngine(config: QemuEngineConfig(
            helper: tmp.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: tmp.appendingPathComponent("firmware"),
            diskImage: img))
        XCTAssertEqual(engine.state, .stopped)

        let deadLock = ImageLock(host: "MacA", pid: 0, imagePath: img.path,
                                 startedAt: "", appVersion: "",
                                 qmpSocketPath: "/tmp/x.sock", consoleSocketPath: "/tmp/y.sock")
        XCTAssertFalse(engine.attach(toOrphan: deadLock))
        XCTAssertEqual(engine.state, .stopped)
    }

    /// Live test: spawn an orphan qemu (no controller), then ADOPT it via
    /// `attach(toOrphan:)` -- the Design 2 reconnect path. Asserts the engine
    /// flips to running, the "reconnected to console" marker lands in the
    /// transcript (the serial socket replays no history, so without it the window
    /// is blank), and that a clean-stop via the adopted engine fires onTerminated
    /// and returns to stopped (proving the no-Process death detection). Gated like
    /// the other live tests.
    ///
    ///   SPARCPLUG_LIVE_TEST=1 SPARCPLUG_ENGINE_DIR=~/dev/SPARCplug/dist \
    ///     swift test --filter testLiveAdoptOrphanLifecycle
    func testLiveAdoptOrphanLifecycle() throws {
        guard ProcessInfo.processInfo.environment["SPARCPLUG_LIVE_TEST"] != nil,
              let dir = ProcessInfo.processInfo.environment["SPARCPLUG_ENGINE_DIR"], !dir.isEmpty
        else { throw XCTSkip("set SPARCPLUG_LIVE_TEST=1 and SPARCPLUG_ENGINE_DIR to run") }

        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qemu-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let disk = tmp.appendingPathComponent("throwaway.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let fh = try FileHandle(forWritingTo: disk)
        try fh.truncate(atOffset: 64 * 1024 * 1024)
        try fh.close()

        // Spawn the orphan directly with explicit sockets (no controlling client).
        let qmpPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("adopt-qmp-\(UUID().uuidString.prefix(8)).sock")
        let conPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("adopt-con-\(UUID().uuidString.prefix(8)).sock")
        let config = QemuEngineConfig(
            helper: base.appendingPathComponent("qemu-system-sparc"),
            firmwareDir: base.appendingPathComponent("firmware", isDirectory: true),
            diskImage: disk)
        let args = QemuEngine.buildArguments(config: config,
                                             qmpSocketPath: qmpPath, consoleSocketPath: conPath)
        let p = Process()
        p.executableURL = config.helper
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }

        let lock = ImageLock(host: ImageLockManager.currentHost(), pid: p.processIdentifier,
                             imagePath: disk.path, startedAt: "", appVersion: "test",
                             qmpSocketPath: qmpPath, consoleSocketPath: conPath)

        // Adopt it.
        let engine = QemuEngine(config: config)
        let lockOut = NSLock()
        var console = ""
        let sawMarker = expectation(description: "reconnected-to-console marker")
        sawMarker.assertForOverFulfill = false
        engine.onConsole { chunk in
            lockOut.lock(); console += chunk
            let hit = console.contains("reconnected to console"); lockOut.unlock()
            if hit { sawMarker.fulfill() }
        }
        let terminated = expectation(description: "adopted orphan terminated")
        terminated.assertForOverFulfill = false
        engine.onTerminated { _ in terminated.fulfill() }

        // qemu needs a beat to open its sockets before the adopt connects.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(engine.attach(toOrphan: lock), "should adopt the live orphan")
        XCTAssertEqual(engine.state, .running)

        wait(for: [sawMarker], timeout: 5)

        // Clean-stop through the adopted engine; the no-Process death poll should
        // notice the exit and fire onTerminated.
        engine.kill()
        wait(for: [terminated], timeout: 15)
        XCTAssertNotEqual(engine.state, .running)
    }

    // MARK: - C3 readiness helpers

    /// The fsck maintenance drop is detected on its failure phrase, and a
    /// routine clean-boot preen ("fsck" alone) does NOT trip it -- otherwise the
    /// stall warning would fire on every healthy boot.
    func testFsckStallDetection() {
        let solaris = MachineOS.solaris26.fsckStallMarkers
        XCTAssertTrue(QemuEngine.indicatesFsckStall(
            "/dev/rdsk/c0t0d0s0: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.", markers: solaris))
        XCTAssertTrue(QemuEngine.indicatesFsckStall(
            "lots of boot text\nRUN fsck MANUALLY\nEnter maintenance mode", markers: solaris))
        XCTAssertFalse(QemuEngine.indicatesFsckStall(
            "/dev/rdsk/c0t0d0s0: is clean\nThe / file system (/dev/...) was checked with fsck", markers: solaris))
        XCTAssertFalse(QemuEngine.indicatesFsckStall("Booting...\nThe system is ready", markers: solaris))

        // Regression (CODE_AUDIT §1): NetBSD's fsck_ffs wording. The Solaris
        // marker set never matched it, so stall detection silently no-op'd on
        // NetBSD and boot waited out the full readiness budget.
        let netbsd = MachineOS.netbsd.fsckStallMarkers
        XCTAssertTrue(QemuEngine.indicatesFsckStall(
            "/dev/sd0a: UNEXPECTED INCONSISTENCY; RUN fsck_ffs MANUALLY.", markers: netbsd))
        XCTAssertFalse(QemuEngine.indicatesFsckStall(
            "/dev/sd0a: UNEXPECTED INCONSISTENCY; RUN fsck_ffs MANUALLY.", markers: solaris),
            "the Solaris marker set must NOT match NetBSD's phrase — that was the bug")
    }

    /// Boot progress is cosmetic and tops out below 1.0 -- the authoritative
    /// 1.0 comes from the first `hello`, not a console string. The old
    /// `console login:` -> 1.0 proxy is gone. Milestones are per-OS now, so
    /// every guest's table must satisfy the same contract.
    func testBootProgressTopsOutBelowReady() {
        for os in MachineOS.allCases {
            // Milestones derive from the real boot transcript (ProgressReference),
            // so assert behavior against that table rather than brittle constants.
            let marks = ProgressReference.boot(for: os)
            guard os.emulatable else {
                // External-host-only OSes have no qemu console; their tables
                // must be honestly empty, not padded with fake landmarks.
                XCTAssertTrue(marks.isEmpty, "\(os)")
                XCTAssertTrue(ProgressReference.shutdown(for: os).isEmpty, "\(os)")
                continue
            }
            let first = marks.first!
            let last = marks.last!

            XCTAssertEqual(QemuEngine.bootProgress(in: "", milestones: marks), 0.0)
            // A recognized early landmark gives its (small, positive) fraction.
            XCTAssertEqual(QemuEngine.bootProgress(in: first.0, milestones: marks),
                           first.1, accuracy: 0.0001)
            XCTAssertGreaterThan(first.1, 0.0, "\(os)")
            // The highest landmark present wins (monotonic via max): an early plus
            // a late line resolves to the late line's fraction.
            XCTAssertEqual(QemuEngine.bootProgress(in: first.0 + "\n" + last.0, milestones: marks),
                           last.1, accuracy: 0.0001)
            XCTAssertGreaterThan(last.1, first.1, "\(os)")
            // Even the last console landmark stays below 1.0 -- `hello` owns ready.
            XCTAssertLessThan(last.1, 1.0, "\(os)")
        }
    }

    /// The per-OS tables actually recognize their own guest's late-boot lines
    /// (same Solaris-default-on-all-guests class as the fsck/shutdown bugs:
    /// with only the Solaris table, a NetBSD or SunOS boot moved the bar for
    /// the shared OpenBIOS prelude, then parked it for the whole kernel +
    /// userland bring-up).
    func testBootProgressMilestonesArePerOS() {
        // Real console lines from the 2026-07-07 captures, one deep-boot line
        // per guest. NetBSD's carries the live kernel timestamp + a hostname to
        // prove marker matching ignores both.
        let sunosLine  = "starting network daemons: inetd printer."
        let netbsdLine = "Starting heliosagent."
        let netbsdKernelLine = "[   4.0975230] root file system type: ffs"

        let sunos  = ProgressReference.boot(for: .sunos414)
        let netbsd = ProgressReference.boot(for: .netbsd)
        let solaris = ProgressReference.boot(for: .solaris26)

        // Each OS's own table drives well past the OpenBIOS prelude (~0.2).
        XCTAssertGreaterThan(QemuEngine.bootProgress(in: sunosLine, milestones: sunos), 0.5)
        XCTAssertGreaterThan(QemuEngine.bootProgress(in: netbsdLine, milestones: netbsd), 0.5)
        XCTAssertGreaterThan(QemuEngine.bootProgress(in: netbsdKernelLine, milestones: netbsd), 0.2)

        // The Solaris table must NOT recognize the BSD lines -- that silence is
        // the parked-bar bug this change fixes.
        XCTAssertEqual(QemuEngine.bootProgress(in: sunosLine, milestones: solaris), 0.0)
        XCTAssertEqual(QemuEngine.bootProgress(in: netbsdLine, milestones: solaris), 0.0)
    }

    /// NetBSD kernel timestamps ("[   1.0000060] ") vary run to run, so the
    /// landmark parser strips them; non-timestamp brackets pass through.
    func testKernelTimestampStripping() {
        XCTAssertEqual(ProgressReference.stripKernelTimestamp(
            "[   1.0000060] tcx0: SUNW,tcx, 1024 x 768"), "tcx0: SUNW,tcx, 1024 x 768")
        XCTAssertEqual(ProgressReference.stripKernelTimestamp(
            "[ 176.4179230] unmounting done"), "unmounting done")
        XCTAssertEqual(ProgressReference.stripKernelTimestamp(
            "[qemu] some diagnostic"), "[qemu] some diagnostic")
        XCTAssertEqual(ProgressReference.stripKernelTimestamp(
            "plain line"), "plain line")
    }

    /// Shutdown landmark hygiene: no marker in an OS's shutdown table may be a
    /// substring of that OS's FIRST shutdown line, or pickLowest would snap the
    /// receding bar to the bottom the moment shutdown starts (the bare
    /// "halted" trap -- "halt: halted by <user>" contains it).
    func testShutdownMilestonesDontBottomOutOnFirstLine() {
        let firstLine: [MachineOS: String] = [
            .solaris26: "INIT: New run level: 5",
            .sunos414:  "Jul  7 10:58:41 sunos halt: halted by root",
            .netbsd:    "Jul  7 16:56:20 netbsd halt: halted by tvernon",
        ]
        for os in MachineOS.allCases where os.emulatable {
            let marks = ProgressReference.shutdown(for: os)
            let matched = marks.filter { firstLine[os]!.contains($0.0) }
            // The first line may match its OWN landmark (the top of the recede),
            // but never a deeper one.
            let deepest = marks.map(\.1).min()!
            for (marker, value) in matched {
                XCTAssertGreaterThan(value, deepest,
                    "\(os): first shutdown line matches deep marker '\(marker)'")
            }
        }
    }

    /// The slirp packet-send line is recognized; real qemu errors are not (they
    /// get shown verbatim as [qemu] ...).
    func testSlirpWaitDetection() {
        XCTAssertTrue(QemuEngine.isSlirpWaitLine(
            "qemu-system-sparc: Slirp: Failed to send packet, ret: -1"))
        XCTAssertFalse(QemuEngine.isSlirpWaitLine(
            "qemu-system-sparc: Could not open disk image: Permission denied"))
        XCTAssertFalse(QemuEngine.isSlirpWaitLine("Invalid FCode start byte"))
    }

    /// The three slirp waits escalate, and a 4th+ clamps to the last line.
    func testSlirpWaitBanterEscalates() {
        XCTAssertEqual(QemuEngine.slirpWaitMessage(1),
                       "[macXserver] guest network not up yet, waiting\u{2026}")
        XCTAssertEqual(QemuEngine.slirpWaitMessage(2),
                       "[macXserver] waiting some more \u{2014} love these old machines\u{2026}")
        XCTAssertEqual(QemuEngine.slirpWaitMessage(3),
                       "[macXserver] waiting\u{2026} err, c\u{2019}mon baby\u{2026}")
        XCTAssertEqual(QemuEngine.slirpWaitMessage(4), QemuEngine.slirpWaitMessage(3))
    }

    // MARK: - per-OS boot wiring (SunOS 4.1.4 disk-unit / boot-command)

    /// SunOS 4.1.4 must attach the boot disk at qemu unit 3 (its kernel reverses
    /// target<->sd naming, so target 3 = sd0, matching its fstab), plus an explicit
    /// boot-command since OpenBIOS ignores boot-device. Without unit=3 the guest
    /// names the disk sd3 and /usr (fstab sd0g) won't mount -> single-user.
    func testBuildArgumentsSunOS414UnitAndBootCommand() {
        var c = cfg()
        c.diskImage = URL(fileURLWithPath: "/img/sunos414-boot.qcow2")
        c.os = .sunos414                              // the single per-OS input
        let args = QemuEngine.buildArguments(config: c)
        XCTAssertTrue(args.contains("file=/img/sunos414-boot.qcow2,bus=0,unit=3,media=disk"))
        XCTAssertTrue(args.contains("auto-boot?=true"))
        XCTAssertTrue(args.contains("boot-command=boot /iommu/sbus/espdma/esp/sd@3,0"))
    }

    /// Solaris (the default) stays at unit 0 with no baked boot-command -- it boots
    /// fine on OpenBIOS's default auto-boot. Guards against regressing the common path.
    func testBuildArgumentsSolarisNoBootCommand() {
        let args = QemuEngine.buildArguments(config: cfg())
        XCTAssertTrue(args.contains(where: { $0.hasSuffix("bus=0,unit=0,media=disk") }))
        XCTAssertFalse(args.contains("auto-boot?=true"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("boot-command=") }))
    }

    /// The per-OS mapping the config builders read.
    func testMachineOSBootWiring() {
        XCTAssertEqual(MachineOS.solaris26.bootDiskUnit, 0)
        XCTAssertNil(MachineOS.solaris26.bootCommand)
        XCTAssertEqual(MachineOS.sunos414.bootDiskUnit, 3)
        XCTAssertEqual(MachineOS.sunos414.bootCommand, "boot /iommu/sbus/espdma/esp/sd@3,0")
        XCTAssertEqual(MachineOS.netbsd.bootDiskUnit, 0)
        XCTAssertEqual(MachineOS.netbsd.bootCommand, "boot /iommu/sbus/espdma/esp/sd@0,0")
    }

    /// The machine-driven config path carries the OS end to end: the config's
    /// single `os` input drives the per-OS argv (unit 3 + boot-command) and ports.
    func testMakeEngineConfigThreadsOS() {
        let m = Machine(name: "s", kind: .emulatedVM, os: .sunos414,
                        host: "127.0.0.1", user: "t", imagePath: "/img/s.qcow2")
        let config = m.makeEngineConfig(bundle: .main)
        XCTAssertEqual(config?.os, .sunos414)
        XCTAssertEqual(config?.ports, .sunos414)   // per-OS host-port block too
        let args = QemuEngine.buildArguments(config: config!)
        XCTAssertTrue(args.contains(where: { $0.hasSuffix("bus=0,unit=3,media=disk") }))
        XCTAssertTrue(args.contains("boot-command=boot /iommu/sbus/espdma/esp/sd@3,0"))
    }

    /// The guest profile is exhaustive and self-consistent (the forcing function
    /// that turns a silent per-OS gap into a compile error lives in the switches;
    /// this pins the current values).
    func testGuestProfileValues() {
        XCTAssertEqual(MachineOS.solaris26.shutdownCommand, "/usr/sbin/init 5")
        XCTAssertEqual(MachineOS.sunos414.shutdownCommand, "/usr/etc/halt")
        XCTAssertEqual(MachineOS.netbsd.shutdownCommand, "/sbin/halt")
        // Lockstep with heliosAgent PROTOCOL.md; init 5 is NOT power-off on IRIX.
        XCTAssertEqual(MachineOS.irix65.shutdownCommand, "/etc/shutdown -y -g0 -i0")
        XCTAssertTrue(MachineOS.solaris26.cleanHaltMarkers.contains("syncing file systems"))
        XCTAssertFalse(MachineOS.sunos414.xBinDirs.contains("/usr/dt/bin"))  // no CDE on 4.1.4
        XCTAssertTrue(MachineOS.netbsd.xBinDirs.contains("/usr/X11R7/bin"))
        XCTAssertEqual(MachineOS.irix65.xBinDirs, "/usr/bin/X11")
    }

    /// IRIX is the first external-host-only OS: the sysinfo prober must adopt
    /// it from both kernel spellings, and nothing emulation-side may claim it.
    func testIrixIsExternalHostOnly() {
        XCTAssertFalse(MachineOS.irix65.emulatable)
        XCTAssertEqual(MachineOS.detect(unameSysname: "IRIX", release: "6.5"), .irix65)
        XCTAssertEqual(MachineOS.detect(unameSysname: "IRIX64", release: "6.5"), .irix65)
        // External standard ports, never an emulated 21x0 block.
        XCTAssertEqual(MachineOS.irix65.defaultPorts, .externalHost)
        XCTAssertNil(MachineOS.irix65.bootCommand)
        XCTAssertTrue(MachineOS.irix65.cleanHaltMarkers.isEmpty)
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
