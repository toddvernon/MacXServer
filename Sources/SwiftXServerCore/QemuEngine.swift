import Foundation

public enum QemuEngineError: Error, LocalizedError, Sendable {
    case engineNotFound(String)
    case diskImageNotFound(String)
    case alreadyRunning
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotFound(let p): return "Bundled engine not found at \(p)"
        case .diskImageNotFound(let p): return "Disk image not found at \(p)"
        case .alreadyRunning: return "The engine is already running"
        case .spawnFailed(let s): return "Failed to spawn the engine: \(s)"
        }
    }
}

/// Where the engine sits, decoupled from how it's run. Built either from the
/// app bundle (the shipped layout) or from a dev override pointing at
/// SPARCplug's `dist/` so the controller is testable before the bundle
/// wiring lands. See `defaultConfig()`.
public struct QemuEngineConfig: Sendable, Equatable {
    /// The qemu-system-sparc helper. Its bundled dylibs are resolved by the
    /// `@executable_path/lib/` rpath baked in at packaging time, so they must
    /// live in a `lib/` dir alongside this binary.
    public var helper: URL
    /// Dir holding `openbios-sparc32`. Passed to qemu as `-L`, because the
    /// built binary's default firmware path is an absolute build-tree path
    /// that does not exist on a customer machine.
    public var firmwareDir: URL
    /// The writable Solaris qcow2. Lives in Application Support in the shipped
    /// product (Track C installs it there); overridable for dev.
    public var diskImage: URL
    public var memoryMB: Int
    /// When non-nil, slirp serves this directory over its built-in TFTP server
    /// on the guest gateway (10.0.2.2). nil = no TFTP (the `-nic` line omits
    /// `tftp=`). The caller is responsible for the directory existing; slirp
    /// is read-only and won't create it.
    public var tftpDirectory: String?

    public init(helper: URL, firmwareDir: URL, diskImage: URL, memoryMB: Int = 128,
                tftpDirectory: String? = nil) {
        self.helper = helper
        self.firmwareDir = firmwareDir
        self.diskImage = diskImage
        self.memoryMB = memoryMB
        self.tftpDirectory = tftpDirectory
    }
}

/// Locates and runs the bundled SPARCplug qemu engine as a subprocess, and
/// streams its `-nographic` serial console out for an observation window.
///
/// This is the long-running sibling of the remote launchers: where
/// `SSHLauncher` spawns a command that exits, the engine runs until it's
/// stopped, so the controller owns lifecycle (start/stop/crash) and a state
/// machine rather than a one-shot completion.
public final class QemuEngine: @unchecked Sendable {

    public enum State: Sendable, Equatable {
        /// No disk image installed yet.
        case notInstalled
        /// Image present, engine not running.
        case stopped
        /// Engine running.
        case running
        /// Graceful shutdown in progress (init 5 sent, waiting for halt).
        case shuttingDown
    }

    /// Console line Solaris prints once filesystems are flushed and unmounted
    /// -- the positive "safe to power off" signal (verified empirically with
    /// `init 5` on this image). qemu then powers off and exits on its own.
    private static let cleanHaltMarker = "syncing file systems"

    /// Console phrase Solaris prints when boot-time fsck can't preen a dirty
    /// filesystem and drops to the maintenance shell for a human. The guest
    /// never reaches multiuser, so the daemon never starts and `hello` never
    /// answers -- detecting this lets us declare the boot stalled immediately
    /// instead of waiting out the readiness budget. It's the *failure* phrase,
    /// not bare "fsck": a clean boot runs a routine preen check too.
    static let fsckStallMarker = "RUN fsck MANUALLY"

    /// How long to wait for the guest to answer `hello` before declaring the
    /// boot stalled. ~4 min covers a slow emulated-SPARC 2.6 boot (close enough
    /// for the real box); an fsck drop preempts it well before this.
    private static let readinessBudget: TimeInterval = 240
    /// Gap between `hello` probes while waiting for readiness.
    private static let readinessPollInterval: TimeInterval = 2

    private let config: QemuEngineConfig
    private let queue = DispatchQueue(label: "swiftx.qemu-engine")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var shuttingDown = false
    /// The clean-halt signal fires once per shutdown.
    private var sawCleanHalt = false
    /// Set once `hello` first succeeds -- the authoritative "guest is up and
    /// serving" signal that replaces the old `login:`-scrape readiness.
    private var ready = false
    /// Set when the boot is declared stalled (fsck maintenance drop, or the
    /// readiness budget elapsing). Stops the `hello` poll.
    private var bootStalled = false
    /// Deadline for `hello` to answer before the boot is declared stalled.
    private var readinessDeadline: Date?
    /// Per-launch shared secret published to the guest via `-prom-env`; the
    /// daemon requires it and our own daemon calls present it. nil when stopped.
    /// Read by the app to hand to `HeliosLauncher` and (in dev) write to disk.
    public private(set) var currentSecret: String?
    /// Rolling tail of recent console text, for marker detection across the
    /// chunk boundaries the pipe splits output on.
    private var consoleTail = ""
    /// Line buffer for qemu's stderr (emulator diagnostics), assembled across
    /// chunk boundaries so we filter on whole lines.
    private var stderrTail = ""
    /// How many slirp "waiting" lines we've shown this run -- drives the
    /// escalating banter (it fires ~3 times during early network bring-up).
    private var slirpWaitCount = 0

    /// 0...1 boot/shutdown progress, driven by console milestones. Grows
    /// while booting, recedes while shutting down.
    private var progress: Double = 0

    private var consoleCallback: ((String) -> Void)?
    private var stateCallback: ((State) -> Void)?
    private var terminatedCallback: ((Bool) -> Void)?
    private var cleanHaltCallback: (() -> Void)?
    private var progressCallback: ((Double) -> Void)?
    private var readyCallback: (() -> Void)?
    private var bootStalledCallback: ((String) -> Void)?

    /// Console substrings mapped to a boot-progress fraction. The highest
    /// match present in the recent console wins (monotonic via max()). These
    /// are cosmetic only and top out below 1.0: the authoritative "ready" 1.0
    /// comes from the first successful `hello` (C3), not a console string. The
    /// old `console login:` -> 1.0 entry was the pre-C3 readiness proxy and is
    /// gone -- readiness no longer derives from the console at all.
    private static let bootMilestones: [(String, Double)] = [
        ("OpenBIOS", 0.12),
        ("SunOS Release", 0.30),
        ("configuring network interfaces", 0.50),
        ("syslog service starting", 0.70),
        ("The system is ready", 0.90),
    ]
    /// Console substrings mapped to a shutdown-progress fraction. The lowest
    /// match present wins (monotonic recede via min()).
    private static let shutdownMilestones: [(String, Double)] = [
        ("The system is coming down", 0.70),
        ("System services are now being stopped", 0.45),
        ("The system is down", 0.20),
        (cleanHaltMarker, 0.10),
    ]

    public init(config: QemuEngineConfig) {
        self.config = config
    }

    // MARK: - Callbacks (set before start)

    /// Serial-console text as it arrives (stdout + stderr merged). Read-only
    /// for v1; this is what the observation window renders.
    public func onConsole(_ callback: @escaping (String) -> Void) {
        self.consoleCallback = callback
    }

    /// Fires on the main queue whenever the state changes.
    public func onStateChange(_ callback: @escaping (State) -> Void) {
        self.stateCallback = callback
    }

    /// Fires on the main queue when the qemu process has exited (clean
    /// power-off or kill). Used by the app-quit path to know the guest is down.
    /// The Bool is whether this run ended via a verified clean halt (the
    /// `syncing file systems` signal was seen) vs. a hard kill / crash -- the
    /// auto-backup path uses it to copy only known-good images. It's captured
    /// before per-run state is reset, so it reflects the run that just ended.
    public func onTerminated(_ callback: @escaping (Bool) -> Void) {
        self.terminatedCallback = callback
    }

    /// Fires on the main queue when Solaris reports filesystems synced during
    /// a graceful shutdown -- the positive "safe to power off" signal.
    public func onCleanHalt(_ callback: @escaping () -> Void) {
        self.cleanHaltCallback = callback
    }

    /// Fires on the main queue with a 0...1 boot/shutdown progress value.
    public func onProgress(_ callback: @escaping (Double) -> Void) {
        self.progressCallback = callback
    }

    /// Fires on the main queue when the guest first answers `hello` -- the
    /// authoritative "ready to use" signal (progress reaches 1.0 at the same
    /// moment). Replaces inferring readiness from the console `login:` prompt.
    public func onReady(_ callback: @escaping () -> Void) {
        self.readyCallback = callback
    }

    /// Fires on the main queue if the guest never becomes ready: an fsck
    /// maintenance drop, or the readiness budget elapsing. The String is a
    /// short human reason. The qemu process is still alive (wedged), so Force
    /// Quit is the recovery.
    public func onBootStalled(_ callback: @escaping (String) -> Void) {
        self.bootStalledCallback = callback
    }

    // MARK: - State

    /// Current state. Shutting-down takes precedence; otherwise running vs
    /// (stopped | notInstalled by disk-image presence).
    public var state: State {
        if shuttingDown { return .shuttingDown }
        if isRunning { return .running }
        return FileManager.default.fileExists(atPath: config.diskImage.path)
            ? .stopped : .notInstalled
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { throw QemuEngineError.alreadyRunning }

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.helper.path) else {
            throw QemuEngineError.engineNotFound(config.helper.path)
        }
        guard fm.fileExists(atPath: config.diskImage.path) else {
            throw QemuEngineError.diskImageNotFound(config.diskImage.path)
        }

        // Fresh per-launch secret: passed to the guest via -prom-env (the daemon
        // requires it), held for our own daemon calls + the launcher + dev file.
        let secret = Self.generateHeliosSecret()
        self.currentSecret = secret
        let args = Self.buildArguments(config: config, heliosSecret: secret)

        let p = Process()
        p.executableURL = config.helper
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Give qemu a stdin pipe we hold open but never write to. The console
        // is observation-only (C5: control goes through the Helios daemon, not
        // the serial line), but qemu's serial console still reads stdin -- a
        // live, silent pipe keeps it from hitting EOF on an inherited stdin.
        p.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // stderr is qemu's OWN diagnostics, not the guest serial console.
            self?.queue.async { self?.ingestEmulatorOutput(data) }
        }

        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self = self else { return }
                // Release the image lock (only ours, by host) now that qemu
                // has exited cleanly under our control.
                ImageLockManager.release(imageURL: self.config.diskImage)
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingest(rest)
                }
                if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingestEmulatorOutput(rest)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.stdinPipe = nil
                // Capture the clean-halt result before resetting per-run
                // state, so the terminated callback can tell a graceful
                // power-off from a hard kill.
                let wasCleanHalt = self.sawCleanHalt
                self.isRunning = false
                self.shuttingDown = false
                self.sawCleanHalt = false
                self.ready = false
                self.bootStalled = false
                self.readinessDeadline = nil
                self.currentSecret = nil
                self.consoleTail = ""
                self.stderrTail = ""
                self.progress = 0
                self.emitState()
                self.emitProgress()
                let cb = self.terminatedCallback
                DispatchQueue.main.async { cb?(wasCleanHalt) }
            }
        }

        self.process = p
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.stdinPipe = inPipe
        self.shuttingDown = false
        self.sawCleanHalt = false
        self.ready = false
        self.bootStalled = false
        self.readinessDeadline = nil
        self.consoleTail = ""
        self.stderrTail = ""
        self.slirpWaitCount = 0
        self.progress = 0

        do {
            try p.run()
        } catch {
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.stdinPipe = nil
            throw QemuEngineError.spawnFailed(error.localizedDescription)
        }
        isRunning = true
        // Claim the image lock with the *qemu* pid, so if macXserver dies and
        // orphans this qemu, the next launch finds a live pid to reclaim.
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        ImageLockManager.acquire(imageURL: config.diskImage,
                                 pid: p.processIdentifier, appVersion: appVersion)
        progress = 0.05            // a visible sliver the moment qemu launches
        emitState()
        emitProgress()
        // Start polling the daemon for liveness; first success flips us to ready.
        readinessDeadline = Date().addingTimeInterval(Self.readinessBudget)
        scheduleReadinessProbe(after: Self.readinessPollInterval)
    }

    /// Graceful shutdown via the Helios daemon's `shutdown` verb (it runs
    /// `init 5` as root over the hostfwd). Solaris then syncs, unmounts, prints
    /// the clean-halt marker (onCleanHalt fires) and powers off so qemu exits on
    /// its own (onTerminated fires) -- we still read the console, so the
    /// clean-halt detection that gates the auto-backup is unchanged. The console
    /// is observation-only (C5): there is no console fallback, so if the daemon
    /// can't be reached we revert to `.running` and the user recovers with Force
    /// Quit. Safe no-op if not running or already shutting down.
    public func shutDown() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, !self.shuttingDown else { return }
            self.shuttingDown = true
            self.emitState()
            self.requestShutdownViaDaemon()
        }
    }

    /// Ask the guest's Helios daemon to halt. The network call runs OFF `queue`
    /// so console ingest -- and the clean-halt detection it drives -- keeps
    /// flowing while we wait on connect/ACK.
    private func requestShutdownViaDaemon() {
        let secret = currentSecret
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let daemonError = Self.performDaemonShutdown(secret: secret)
            self.queue.async {
                guard self.shuttingDown else { return } // raced with terminate/kill
                if let daemonError {
                    // Console is observation-only (C5): nothing left to fall back
                    // to. We never asked the guest to halt, so we're still
                    // running -- revert the flag and tell the user to Force Quit.
                    self.shuttingDown = false
                    self.emitState()
                    self.emitDiagnostic("Helios daemon unreachable (\(daemonError)). "
                                        + "Couldn't request shutdown -- use Force Quit.")
                } else {
                    self.emitDiagnostic("shutdown requested via Helios daemon, give it a second")
                }
            }
        }
    }

    /// One-shot daemon shutdown. Returns nil on success, or a short description
    /// of why the daemon couldn't be reached so the caller can fall back.
    private static func performDaemonShutdown(secret: String?) -> String? {
        let client = HeliosClient(timeout: 8, secret: secret)
        defer { client.close() }
        do {
            try client.connect()
            _ = try client.shutdown()
            return nil
        } catch {
            return (error as? HeliosClient.HeliosError)?.errorDescription ?? "\(error)"
        }
    }

    /// Hard kill: SIGTERM to qemu (pulls the power cord -- Solaris will fsck on
    /// next boot). For wedged cases where graceful shutdown won't complete.
    public func kill() {
        queue.async { [weak self] in
            self?.process?.terminate()
        }
    }


    // MARK: - Readiness (hello liveness drives "guest is up")

    /// Schedule a `hello` probe after `delay`. The probe does its blocking
    /// network call off `queue` so console ingest keeps flowing, then hops back
    /// to `queue` to update state. The poll stops itself once the guest is
    /// ready, the boot is declared stalled (here or by the fsck hook in
    /// `ingest`), or qemu exits.
    private func scheduleReadinessProbe(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.readinessProbe()
        }
    }

    private func readinessProbe() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, !self.ready, !self.bootStalled else { return }
            let deadline = self.readinessDeadline ?? Date()
            let secret = self.currentSecret
            DispatchQueue.global(qos: .utility).async {
                let answered = Self.probeHello(secret: secret)
                self.queue.async {
                    guard self.isRunning, !self.ready, !self.bootStalled else { return }
                    if answered {
                        self.markReady()
                    } else if Date() >= deadline {
                        self.markBootStalled("guest did not answer Helios within "
                                             + "\(Int(Self.readinessBudget))s")
                    } else {
                        self.scheduleReadinessProbe(after: Self.readinessPollInterval)
                    }
                }
            }
        }
    }

    /// One-shot `hello`. A fresh connect each probe IS the liveness test, so a
    /// short timeout keeps probes from overlapping. Matches the one-shot style
    /// of the shutdown call.
    private static func probeHello(secret: String?) -> Bool {
        let client = HeliosClient(timeout: 2, secret: secret)
        defer { client.close() }
        do {
            try client.connect()
            _ = try client.hello()
            return true
        } catch {
            return false
        }
    }

    /// Authoritative readiness: drive progress to 1.0 and fire `onReady` once.
    private func markReady() {
        guard !ready else { return }
        ready = true
        progress = 1.0
        emitProgress()
        emitDiagnostic("guest is up (Helios daemon answered)")
        let cb = readyCallback
        DispatchQueue.main.async { cb?() }
    }

    /// The boot won't complete: surface the reason and stop polling. The qemu
    /// process is still alive (wedged), so Force Quit is the recovery.
    private func markBootStalled(_ reason: String) {
        guard !bootStalled, !ready else { return }
        bootStalled = true
        emitDiagnostic("guest did not come up: \(reason). It's still running but "
                       + "wedged -- Force Quit to recover (the next boot will fsck).")
        let cb = bootStalledCallback
        DispatchQueue.main.async { cb?(reason) }
    }

    /// True when the console shows the boot-time fsck maintenance drop. Keyed on
    /// the failure phrase, not bare "fsck" (a clean boot preens routinely).
    /// Internal for unit testing.
    static func indicatesFsckStall(_ text: String) -> Bool {
        text.contains(fsckStallMarker)
    }

    /// Cosmetic boot progress (0...~0.9) from console milestones. Internal for
    /// unit testing. Tops out below 1.0 -- `hello` owns the final step.
    static func bootProgress(in text: String) -> Double {
        matchedProgress(bootMilestones, in: text, default: 0.0, pickLowest: false)
    }

    // MARK: - Argument construction

    /// Build the qemu argv (everything after the binary itself). Static and
    /// pure so the exact recipe can be pinned in a unit test without spawning
    /// qemu. Mirrors the working recipe in SPARCSTATION_PLUGIN.md, with the
    /// firmware `-L` and the writable disk path filled in from the config.
    /// `heliosSecret`, when non-empty, is published to the guest as the OpenBoot
    /// NVRAM variable `helios-secret` (read back by the daemon's init script via
    /// `eeprom`). It's per-launch and runtime-only -- `-prom-env` never persists
    /// to the qcow2 (verified 2026-06-22), so the secret never lands on disk.
    public static func buildArguments(config: QemuEngineConfig, heliosSecret: String = "") -> [String] {
        // slirp NAT, AMD lance NIC (Solaris le0). hostfwd opens Mac ports
        // 2123/2222/2125 -> guest 23/22/2125 so the launcher can telnet/ssh in
        // and the Mac reaches the Helios daemon directly (no ssh tunnel). Fixed
        // MAC for stable guest identity across reboots. When a shared folder is
        // configured, append slirp's built-in TFTP server pointed at it; the
        // guest pulls files with `tftp 10.0.2.2`.
        var nic = "user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp::\(telnetHostPort)-:23,hostfwd=tcp::2222-:22,hostfwd=tcp::\(heliosHostPort)-:2125"
        if let tftp = config.tftpDirectory, !tftp.isEmpty {
            nic += ",tftp=\(tftp)"
        }
        var args = [
            "-M", "SS-5",                                   // SPARCstation 5 (sun4m)
            "-m", String(config.memoryMB),                  // RAM in MB
            "-nographic",                                   // serial console to stdio, no framebuffer window
            "-L", config.firmwareDir.path,                  // bundled openbios-sparc32 lives here
            "-prom-env", "input-device=ttya",               // OpenBOOT console policy: serial from boot
            "-prom-env", "output-device=ttya",
        ]
        if !heliosSecret.isEmpty {
            args += ["-prom-env", "helios-secret=\(heliosSecret)"]
        }
        args += [
            "-nic", nic,
            "-drive", "file=\(config.diskImage.path),bus=0,unit=0,media=disk",
        ]
        return args
    }

    /// A fresh per-launch shared secret (128 bits, hex). `SystemRandomNumberGenerator`
    /// is cryptographically secure on Apple platforms.
    static func generateHeliosSecret() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    // MARK: - Default path resolution

    /// Canonical filename of the installed disk image in Application Support.
    /// Track C's downloader must write this name.
    public static let diskImageFilename = "solaris-2.6.qcow2"

    /// Mac-side port forwarded to the guest's telnet (23). The best-effort
    /// "shut down an orphan over telnet" path dials this.
    public static let telnetHostPort: UInt16 = 2123

    /// Mac-side port forwarded to the guest's Helios daemon (2125). Both clients
    /// -- macXserver's HeliosClient and Claude Code's bridge -- connect here
    /// directly over loopback, no ssh tunnel. (DECISIONS 2026-06-21: macXserver
    /// owns the network path; advertising this port is the discovery follow-up.)
    public static let heliosHostPort: UInt16 = 2125

    /// `~/Library/Application Support/macXserver/`.
    public static func applicationSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("macXserver", isDirectory: true)
    }

    /// Resolve the engine layout. Dev overrides come first so the controller
    /// is exercisable before the bundle wiring exists:
    ///   - `SPARCPLUG_ENGINE_DIR`  -> a SPARCplug `dist/` dir (helper +
    ///     `lib/` + `firmware/`).
    ///   - `SPARCPLUG_DISK_IMAGE`  -> an explicit qcow2 path.
    /// Otherwise the shipped bundle layout:
    ///   helper   = .../Contents/Helpers/qemu-system-sparc
    ///   firmware = .../Contents/Resources/qemu-firmware
    ///   image    = Application Support/macXserver/<diskImageFilename>
    public static func defaultConfig(bundle: Bundle = .main, memoryMB: Int = 128) -> QemuEngineConfig {
        let env = ProcessInfo.processInfo.environment

        let helper: URL
        let firmwareDir: URL
        if let dir = env["SPARCPLUG_ENGINE_DIR"], !dir.isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            helper = base.appendingPathComponent("qemu-system-sparc")
            firmwareDir = base.appendingPathComponent("firmware", isDirectory: true)
        } else {
            let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
            helper = contents.appendingPathComponent("Helpers/qemu-system-sparc")
            firmwareDir = contents.appendingPathComponent("Resources/qemu-firmware", isDirectory: true)
        }

        let diskImage: URL
        if let img = env["SPARCPLUG_DISK_IMAGE"], !img.isEmpty {
            diskImage = URL(fileURLWithPath: img)
        } else {
            diskImage = applicationSupportDir().appendingPathComponent(diskImageFilename)
        }

        // Dev override for the shared folder, so the bundled engine can be
        // exercised with TFTP before/independent of the Preferences toggle.
        // The app normally sets tftpDirectory from Preferences instead.
        let tftpDir = env["SPARCPLUG_TFTP_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        return QemuEngineConfig(helper: helper, firmwareDir: firmwareDir,
                                diskImage: diskImage, memoryMB: memoryMB,
                                tftpDirectory: tftpDir)
    }

    // MARK: - I/O (all on `queue`)

    /// Process a console chunk: forward it to the UI, auto-login on the first
    /// login prompt, and fire the clean-halt signal during shutdown. Runs on
    /// `queue` so the flags and tail buffer aren't raced.
    private func ingest(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else { return }

        // Keep a bounded tail so markers split across chunks still match.
        consoleTail += s
        if consoleTail.count > 8192 {
            consoleTail = String(consoleTail.suffix(8192))
        }

        if shuttingDown, !sawCleanHalt, consoleTail.contains(Self.cleanHaltMarker) {
            sawCleanHalt = true
            let cb = cleanHaltCallback
            DispatchQueue.main.async { cb?() }
        }

        // fsck couldn't preen a dirty filesystem and dropped to maintenance:
        // the boot is wedged and the daemon will never come up. Declare it
        // stalled now rather than waiting out the readiness budget.
        if !ready, !bootStalled, Self.indicatesFsckStall(consoleTail) {
            markBootStalled("filesystem check failed (RUN fsck MANUALLY)")
        }

        // Progress: grow on boot milestones, recede on shutdown milestones.
        let updated = shuttingDown
            ? min(progress, Self.matchedProgress(Self.shutdownMilestones, in: consoleTail, default: 1.0, pickLowest: true))
            : max(progress, Self.bootProgress(in: consoleTail))
        if updated != progress {
            progress = updated
            let pc = progressCallback
            DispatchQueue.main.async { pc?(updated) }
        }

        let cb = consoleCallback
        DispatchQueue.main.async { cb?(s) }
    }

    /// qemu's OWN stderr (emulator diagnostics), kept out of the guest serial
    /// console on stdout. We must drain it so the pipe never blocks qemu, but
    /// it isn't guest output: known-benign-but-scary chatter (the slirp "Failed
    /// to send packet" spam during early network bring-up) is reworded into a
    /// calm status line, and anything else is surfaced as a labeled `[qemu]`
    /// line so a real emulator error (bad disk, missing firmware) stays visible
    /// without masquerading as console text.
    private func ingestEmulatorOutput(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else { return }
        stderrTail += s
        while let nl = stderrTail.firstIndex(of: "\n") {
            let line = String(stderrTail[..<nl]).trimmingCharacters(in: .whitespaces)
            stderrTail = String(stderrTail[stderrTail.index(after: nl)...])
            if line.isEmpty { continue }
            let shown: String
            if Self.isSlirpWaitLine(line) {
                slirpWaitCount += 1
                shown = Self.slirpWaitMessage(slirpWaitCount)
            } else {
                shown = "[qemu] \(line)"
            }
            let cb = consoleCallback
            DispatchQueue.main.async { cb?(shown + "\n") }
        }
        // Bound the tail so a never-terminated stderr line can't grow unbounded.
        if stderrTail.count > 4096 { stderrTail = String(stderrTail.suffix(4096)) }
    }

    /// The slirp "Failed to send packet" line: fires while the guest sends
    /// before its interface is up. Sounds like a failure, but networking comes
    /// up fine moments later -- so we reframe it instead of scaring the user.
    static func isSlirpWaitLine(_ line: String) -> Bool {
        line.contains("Slirp: Failed to send packet")
    }

    /// Escalating banter for the slirp waits (1-based; ~3 fire per boot). Clamps
    /// to the last line if it ever fires more than expected. Internal for tests.
    static func slirpWaitMessage(_ n: Int) -> String {
        let lines = [
            "[macXserver] guest network not up yet, waiting\u{2026}",
            "[macXserver] waiting some more \u{2014} love these old machines\u{2026}",
            "[macXserver] waiting\u{2026} err, c\u{2019}mon baby\u{2026}",
        ]
        return lines[min(max(n, 1), lines.count) - 1]
    }

    /// Scan `text` for milestone substrings; return the highest (boot) or
    /// lowest (shutdown) matching fraction, or `default` if none match.
    private static func matchedProgress(_ milestones: [(String, Double)], in text: String,
                                        default def: Double, pickLowest: Bool) -> Double {
        var result: Double? = nil
        for (marker, value) in milestones where text.contains(marker) {
            if let r = result {
                result = pickLowest ? Swift.min(r, value) : Swift.max(r, value)
            } else {
                result = value
            }
        }
        return result ?? def
    }

    /// Surface a macXserver-side status note in the observation console so the
    /// user can see which shutdown path ran. Clearly bracketed so it doesn't
    /// read as guest serial output.
    private func emitDiagnostic(_ message: String) {
        let cb = consoleCallback
        DispatchQueue.main.async { cb?("\r\n[macXserver] \(message)\r\n") }
    }

    private func emitState() {
        let s = state
        let cb = stateCallback
        DispatchQueue.main.async { cb?(s) }
    }

    private func emitProgress() {
        let p = progress
        let cb = progressCallback
        DispatchQueue.main.async { cb?(p) }
    }
}
