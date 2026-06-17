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

    public init(helper: URL, firmwareDir: URL, diskImage: URL, memoryMB: Int = 128) {
        self.helper = helper
        self.firmwareDir = firmwareDir
        self.diskImage = diskImage
        self.memoryMB = memoryMB
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

    /// Console prompt that means we can auto-log-in. The image allows root
    /// console login with no password.
    private static let loginPrompt = "login:"
    private static let loginUser = "root"
    /// Console line Solaris prints once filesystems are flushed and unmounted
    /// -- the positive "safe to power off" signal (verified empirically with
    /// `init 5` on this image). qemu then powers off and exits on its own.
    private static let cleanHaltMarker = "syncing file systems"

    private let config: QemuEngineConfig
    private let queue = DispatchQueue(label: "swiftx.qemu-engine")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var shuttingDown = false
    /// Auto-login fires once per run, on the first login prompt.
    private var loggedIn = false
    /// The clean-halt signal fires once per shutdown.
    private var sawCleanHalt = false
    /// Rolling tail of recent console text, for marker detection across the
    /// chunk boundaries the pipe splits output on.
    private var consoleTail = ""

    /// 0...1 boot/shutdown progress, driven by console milestones. Grows
    /// while booting, recedes while shutting down.
    private var progress: Double = 0

    private var consoleCallback: ((String) -> Void)?
    private var stateCallback: ((State) -> Void)?
    private var terminatedCallback: ((Bool) -> Void)?
    private var cleanHaltCallback: (() -> Void)?
    private var progressCallback: ((Double) -> Void)?

    /// Console substrings mapped to a boot-progress fraction. The highest
    /// match present in the recent console wins (monotonic via max()).
    private static let bootMilestones: [(String, Double)] = [
        ("OpenBIOS", 0.12),
        ("SunOS Release", 0.30),
        ("configuring network interfaces", 0.50),
        ("syslog service starting", 0.70),
        ("The system is ready", 0.92),
        ("console login:", 1.0),
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

        let args = Self.buildArguments(config: config)

        let p = Process()
        p.executableURL = config.helper
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Writable stdin: we drive the serial console to auto-login and to
        // issue a graceful `init 5` shutdown.
        p.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.ingest(data) }
        }

        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self = self else { return }
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingest(rest)
                }
                if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingest(rest)
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
                self.loggedIn = false
                self.sawCleanHalt = false
                self.consoleTail = ""
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
        self.loggedIn = false
        self.sawCleanHalt = false
        self.consoleTail = ""
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
        progress = 0.05            // a visible sliver the moment qemu launches
        emitState()
        emitProgress()
    }

    /// Graceful shutdown: send `init 5` to the (root) console. Solaris syncs,
    /// unmounts, prints the clean-halt marker (onCleanHalt fires), then powers
    /// off so qemu exits on its own (onTerminated fires). Safe no-op if not
    /// running or already shutting down.
    public func shutDown() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, !self.shuttingDown else { return }
            self.shuttingDown = true
            self.emitState()
            self.writeConsole("init 5\n")
        }
    }

    /// Hard kill: SIGTERM to qemu (pulls the power cord -- Solaris will fsck on
    /// next boot). For wedged cases where graceful shutdown won't complete.
    public func kill() {
        queue.async { [weak self] in
            self?.process?.terminate()
        }
    }

    /// Write raw text to the serial console (appends nothing; include "\n").
    public func sendConsole(_ text: String) {
        queue.async { [weak self] in self?.writeConsole(text) }
    }

    // MARK: - Argument construction

    /// Build the qemu argv (everything after the binary itself). Static and
    /// pure so the exact recipe can be pinned in a unit test without spawning
    /// qemu. Mirrors the working recipe in SPARCSTATION_PLUGIN.md, with the
    /// firmware `-L` and the writable disk path filled in from the config.
    public static func buildArguments(config: QemuEngineConfig) -> [String] {
        return [
            "-M", "SS-5",                                   // SPARCstation 5 (sun4m)
            "-m", String(config.memoryMB),                  // RAM in MB
            "-nographic",                                   // serial console to stdio, no framebuffer window
            "-L", config.firmwareDir.path,                  // bundled openbios-sparc32 lives here
            "-prom-env", "input-device=ttya",               // OpenBOOT console policy: serial from boot
            "-prom-env", "output-device=ttya",
            // slirp NAT, AMD lance NIC (Solaris le0). hostfwd opens Mac ports
            // 2123/2222 -> guest 23/22 so the launcher can telnet in. Fixed
            // MAC for stable guest identity across reboots.
            "-nic", "user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp::2123-:23,hostfwd=tcp::2222-:22",
            "-drive", "file=\(config.diskImage.path),bus=0,unit=0,media=disk",
        ]
    }

    // MARK: - Default path resolution

    /// Canonical filename of the installed disk image in Application Support.
    /// Track C's downloader must write this name.
    public static let diskImageFilename = "solaris-2.6.qcow2"

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

        return QemuEngineConfig(helper: helper, firmwareDir: firmwareDir,
                                diskImage: diskImage, memoryMB: memoryMB)
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

        if !loggedIn, consoleTail.contains(Self.loginPrompt) {
            loggedIn = true
            writeConsole("\(Self.loginUser)\n")
        }

        if shuttingDown, !sawCleanHalt, consoleTail.contains(Self.cleanHaltMarker) {
            sawCleanHalt = true
            let cb = cleanHaltCallback
            DispatchQueue.main.async { cb?() }
        }

        // Progress: grow on boot milestones, recede on shutdown milestones.
        let updated = shuttingDown
            ? min(progress, Self.matchedProgress(Self.shutdownMilestones, in: consoleTail, default: 1.0, pickLowest: true))
            : max(progress, Self.matchedProgress(Self.bootMilestones, in: consoleTail, default: 0.0, pickLowest: false))
        if updated != progress {
            progress = updated
            let pc = progressCallback
            DispatchQueue.main.async { pc?(updated) }
        }

        let cb = consoleCallback
        DispatchQueue.main.async { cb?(s) }
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

    /// Write to qemu's stdin (the serial console). Best-effort: the pipe may
    /// already be closed if the guest powered off.
    private func writeConsole(_ text: String) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: Data(text.utf8))
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
