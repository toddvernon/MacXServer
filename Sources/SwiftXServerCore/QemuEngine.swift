import Foundation
import Darwin

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
    /// QMP control channel to the captive qemu (VM_CONTROL.md Stage 1). nil until
    /// we connect after launch, or when stopped. Source of the SHUTDOWN clean-halt
    /// signal and a qcow2-clean `quit` on Force Quit.
    private var qmpClient: QmpClient?
    /// The per-launch QMP unix-socket path qemu serves on; "" when stopped.
    private var qmpSocketPath = ""
    /// Serial console channel (VM_CONTROL.md Stage 2). qemu serves the console on
    /// a unix socket instead of the stdio pipe; this client streams it into
    /// `ingest`. nil until connected after launch, or when stopped.
    private var consoleClient: SerialConsoleClient?
    /// The per-launch console unix-socket path qemu serves on; "" when stopped.
    private var consoleSocketPath = ""
    /// Set while this engine drives an ADOPTED orphan (VM_CONTROL.md Stage 3,
    /// Design 2): a qemu we connected to but did NOT spawn, so there's no child
    /// Process -- exit is detected by polling `orphanPid`, not a terminationHandler.
    private var adopted = false
    /// The adopted orphan's qemu pid (0 when not adopting). Polled for death.
    private var orphanPid: Int32 = 0
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
    private var consoleDataCallback: ((Data) -> Void)?
    private var stateCallback: ((State) -> Void)?
    private var terminatedCallback: ((Bool) -> Void)?
    private var cleanHaltCallback: (() -> Void)?
    private var progressCallback: ((Double) -> Void)?
    private var readyCallback: (() -> Void)?
    private var bootStalledCallback: ((String) -> Void)?
    private var shutdownUnavailableCallback: (() -> Void)?

    // Boot/shutdown progress milestones are derived from real console
    // transcripts (see ProgressReference) rather than a hand-tuned table:
    // landmark lines spread evenly across the bar, matched by substring. Boot
    // takes the highest match (monotonic max), shutdown the lowest (monotonic
    // recede via min). Both are cosmetic and stop short of the ends -- boot's
    // 1.0 comes from the first `hello` (C3), shutdown's 0 from pid-death.
    private static let bootMilestones: [(String, Double)] = ProgressReference.boot
    private static let shutdownMilestones: [(String, Double)] = ProgressReference.shutdown

    public init(config: QemuEngineConfig) {
        self.config = config
    }

    // MARK: - Callbacks (set before start)

    /// Serial-console text as it arrives (stdout + stderr merged). Still used
    /// for the boot/shutdown marker detection; the interactive terminal renders
    /// from `onConsoleData` instead.
    public func onConsole(_ callback: @escaping (String) -> Void) {
        self.consoleCallback = callback
    }

    /// Raw serial-console bytes as they arrive, on the main queue. This is what
    /// the interactive terminal (TerminalEmulator) consumes -- it needs the
    /// unmodified byte stream (escape sequences intact), not the sanitized
    /// String the marker-detection path uses.
    public func onConsoleData(_ callback: @escaping (Data) -> Void) {
        self.consoleDataCallback = callback
    }

    /// Send input bytes to the guest's serial console (keystrokes from the
    /// interactive terminal). No-op if the console client isn't connected.
    public func sendConsole(_ data: Data) {
        queue.async { [weak self] in self?.consoleClient?.write(data) }
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

    /// Fires on the main queue when a graceful shutdown couldn't reach the Helios
    /// daemon, so Force Quit is the only stop left. Lets the console surface Force
    /// Quit even though the guest may still look "ready" (graceful-first policy).
    public func onShutdownUnavailable(_ callback: @escaping () -> Void) {
        self.shutdownUnavailableCallback = callback
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
        let qmpPath = Self.makeQmpSocketPath()
        self.qmpSocketPath = qmpPath
        let consolePath = Self.makeConsoleSocketPath()
        self.consoleSocketPath = consolePath
        let args = Self.buildArguments(config: config, heliosSecret: secret,
                                       qmpSocketPath: qmpPath, consoleSocketPath: consolePath)

        let p = Process()
        p.executableURL = config.helper
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // The serial console is on its own unix socket now (Stage 2), so qemu no
        // longer reads stdin for the console -- hand it /dev/null rather than a
        // pipe we'd have to hold open.
        p.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Guest console arrives via the serial socket now; anything qemu
            // writes to stdout is emulator-level diagnostics, treated like stderr.
            self?.queue.async { self?.ingestEmulatorOutput(data) }
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
                // Drain any trailing emulator stdout/stderr (the guest console is
                // on the serial socket now), detach the handlers, drop the
                // process + pipes, then run the shared end-of-run teardown.
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingestEmulatorOutput(rest)
                }
                if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.ingestEmulatorOutput(rest)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.finishRun()
            }
        }

        self.process = p
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
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
            throw QemuEngineError.spawnFailed(error.localizedDescription)
        }
        isRunning = true
        // Claim the image lock with the *qemu* pid, so if macXserver dies and
        // orphans this qemu, the next launch finds a live pid to reclaim.
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        // Persist the per-launch secret in the lock so a later process (this Mac
        // after a crash, or the other Mac) can authenticate to this qemu's daemon
        // and shut it down via Helios if it's ever orphaned.
        // Record the QMP + console socket paths in the lock (VM_CONTROL.md Stage 3,
        // "lock-as-VM-handle"): a later process on this Mac can then clean-stop an
        // orphan via a qcow2-clean QMP `quit` and re-attach the console view.
        ImageLockManager.acquire(imageURL: config.diskImage,
                                 pid: p.processIdentifier, appVersion: appVersion,
                                 secret: self.currentSecret,
                                 qmpSocketPath: qmpPath, consoleSocketPath: consolePath)
        progress = 0.05            // a visible sliver the moment qemu launches
        emitState()
        emitProgress()
        // Start polling the daemon for liveness; first success flips us to ready.
        readinessDeadline = Date().addingTimeInterval(Self.readinessBudget)
        scheduleReadinessProbe(after: Self.readinessPollInterval)
        // Connect the QMP control channel. qemu opens the socket early in startup
        // (well before Solaris boots), so a short retry covers the launch race.
        connectQmp(path: qmpPath)
        // Connect the serial console channel the same way -- qemu opens its
        // listening socket during startup, so retry briefly past the launch race.
        connectConsole(path: consolePath)
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
                    let cb = self.shutdownUnavailableCallback
                    DispatchQueue.main.async { cb?() }
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

    /// Force stop (pulls the power cord -- Solaris will fsck on next boot, since
    /// this skips `init 5`). For wedged cases where graceful shutdown won't
    /// complete. Prefers a qcow2-clean QMP `quit` (qemu drains + closes the block
    /// layer so the *container* stays consistent); falls back to SIGTERM if QMP
    /// isn't connected or doesn't answer. VM_CONTROL.md Stage 1.
    public func kill() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let qmp = self.qmpClient else {
                self.hardKill()
                return
            }
            // quit() blocks; run it off `queue`. On any QMP failure, hard-stop.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try qmp.quit()
                } catch {
                    self?.queue.async { self?.hardKill() }
                }
            }
        }
    }

    /// Last-resort stop when QMP can't do it: SIGTERM the child process we
    /// spawned, or SIGKILL an adopted orphan by pid (we have no Process handle for
    /// a qemu we didn't spawn). Runs on `queue`.
    private func hardKill() {
        if let p = process {
            p.terminate()
        } else if orphanPid > 0 {
            Darwin.kill(orphanPid, SIGKILL)
        }
    }

    /// Shared end-of-run teardown for BOTH lifecycle paths -- the spawned-process
    /// terminationHandler and the adopted-orphan death poll funnel here. Runs on
    /// `queue`. Releases the image lock, tears down the QMP + console channels and
    /// their socket files, resets per-run state, and fires onTerminated with the
    /// clean-halt verdict (so the auto-backup path can tell a graceful power-off
    /// from a hard kill). Any process/pipe-specific cleanup happens at the call
    /// site before this runs.
    private func finishRun() {
        ImageLockManager.release(imageURL: config.diskImage)
        qmpClient?.close()
        qmpClient = nil
        if !qmpSocketPath.isEmpty { unlink(qmpSocketPath); qmpSocketPath = "" }
        consoleClient?.close()
        consoleClient = nil
        if !consoleSocketPath.isEmpty { unlink(consoleSocketPath); consoleSocketPath = "" }
        let wasCleanHalt = sawCleanHalt
        isRunning = false
        adopted = false
        orphanPid = 0
        shuttingDown = false
        sawCleanHalt = false
        ready = false
        bootStalled = false
        readinessDeadline = nil
        currentSecret = nil
        consoleTail = ""
        stderrTail = ""
        progress = 0
        emitState()
        emitProgress()
        let cb = terminatedCallback
        DispatchQueue.main.async { cb?(wasCleanHalt) }
    }

    /// Adopt an already-running ORPHAN qemu (VM_CONTROL.md Stage 3, Design 2):
    /// wire the QMP + console channels to the sockets its image lock records and
    /// present it as a live session, WITHOUT a child Process. This is what lets a
    /// restarted macXserver pick up a VM the previous instance left running. The
    /// caller should confirm the guest is reachable first (Helios `hello`); this
    /// still works if it isn't (the session sits in "booting" until Helios answers
    /// or the readiness budget elapses). Returns false if the orphan isn't alive
    /// (nothing to adopt) or we're already running. Mirrors `start()`'s threading
    /// (runs on the caller's thread, kicks the async channels) -- safe because
    /// nothing is running yet.
    @discardableResult
    public func attach(toOrphan lock: ImageLock) -> Bool {
        guard !isRunning else { return false }
        guard lock.pid > 0, ImageLockManager.isProcessAlive(lock.pid) else { return false }

        let qmp = lock.qmpSocketPath ?? ""
        let console = lock.consoleSocketPath ?? ""

        currentSecret = lock.secret
        orphanPid = lock.pid
        adopted = true
        qmpSocketPath = qmp
        consoleSocketPath = console
        shuttingDown = false
        sawCleanHalt = false
        ready = false
        bootStalled = false
        readinessDeadline = nil
        consoleTail = ""
        stderrTail = ""
        slirpWaitCount = 0
        // Adopted mid-session: no boot to track, so park the bar near full and let
        // the `hello` probe flip it green (1.0) once the daemon answers.
        progress = 0.9
        isRunning = true
        emitState()
        emitProgress()

        // The serial socket replays NO history -- a late joiner only sees new
        // bytes -- so stamp the reconnection in the transcript or the window sits
        // blank until the guest next prints.
        emitDiagnostic("reconnected to console")

        // Wire the control channels to the orphan's sockets (same retry as boot).
        // Older orphans (pre-Stage-2/3 locks) may lack one or both paths; we adopt
        // anyway -- graceful shutdown still works over Helios, just without the
        // QMP clean-halt event or the console view.
        if !qmp.isEmpty { connectQmp(path: qmp) }
        if !console.isEmpty { connectConsole(path: console) }
        // No child Process to deliver an exit, so poll the pid for death.
        scheduleOrphanDeathPoll()
        // Drive readiness off Helios `hello`, exactly like a boot.
        readinessDeadline = Date().addingTimeInterval(Self.readinessBudget)
        scheduleReadinessProbe(after: 0)
        return true
    }

    /// Poll an adopted orphan's pid for death (we have no terminationHandler).
    /// A clean halt fires the QMP `SHUTDOWN` event first (setting `sawCleanHalt`),
    /// then qemu exits and this notices; an external kill just leaves the pid gone
    /// with `sawCleanHalt` false. Either way, run the shared teardown.
    private func scheduleOrphanDeathPoll() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.orphanDeathProbe()
        }
    }

    private func orphanDeathProbe() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, self.adopted else { return }
            if self.orphanPid > 0, ImageLockManager.isProcessAlive(self.orphanPid) {
                self.scheduleOrphanDeathPoll()        // still alive; keep watching
            } else {
                self.finishRun()                      // orphan exited
            }
        }
    }


    /// Clean-stop an *orphaned* qemu (one this process didn't spawn) through the
    /// QMP socket path recorded in its image lock. qemu drains + closes the block
    /// layer, so the qcow2 container stays consistent -- the qcow2-clean teardown
    /// SIGKILL can't give. Returns true if the `quit` was issued (a connection
    /// close right after counts as success, since qemu may exit before replying);
    /// the caller falls back to a verified SIGKILL when this returns false (socket
    /// gone, qemu already dead, or QMP wedged). Blocks; call off the main thread.
    /// VM_CONTROL.md Stage 3 (orphan QMP recovery).
    public static func quitOrphanViaQmp(qmpSocketPath: String) -> Bool {
        guard !qmpSocketPath.isEmpty else { return false }
        let client = QmpClient(socketPath: qmpSocketPath, timeout: 5)
        defer { client.close() }
        do {
            try client.connect()
            try client.quit()
            return true
        } catch {
            return false
        }
    }

    // MARK: - QMP control channel (VM_CONTROL.md Stage 1)

    /// Connect the QMP channel after launch, retrying briefly while qemu opens
    /// its socket. Runs off `queue` (connect blocks). Stores the client only if
    /// this run is still current, so a stop/relaunch race can't strand it.
    private func connectQmp(path: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let stillCurrent = self.queue.sync { self.isRunning && self.qmpSocketPath == path }
                guard stillCurrent else { return }

                let client = QmpClient(socketPath: path, timeout: 5)
                client.onEvent { [weak self] event in self?.handleQmpEvent(event) }
                do {
                    try client.connect()
                    let kept = self.queue.sync { () -> Bool in
                        guard self.isRunning, self.qmpSocketPath == path else { return false }
                        self.qmpClient = client
                        return true
                    }
                    if !kept { client.close() }
                    return
                } catch {
                    Thread.sleep(forTimeInterval: 0.25)   // socket not up yet; retry
                }
            }
        }
    }

    /// Connect the serial console channel after launch, retrying briefly while
    /// qemu opens its listening socket. Runs off `queue` (connect blocks). Stores
    /// the client only if this run is still current, so a stop/relaunch race can't
    /// strand it. Streamed bytes hop to `queue` and into `ingest`, exactly where
    /// the old stdout-pipe handler delivered them. VM_CONTROL.md Stage 2.
    private func connectConsole(path: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let stillCurrent = self.queue.sync { self.isRunning && self.consoleSocketPath == path }
                guard stillCurrent else { return }

                let client = SerialConsoleClient(socketPath: path)
                client.onData { [weak self] data in
                    self?.queue.async { self?.ingest(data) }
                }
                do {
                    try client.connect()
                    let kept = self.queue.sync { () -> Bool in
                        guard self.isRunning, self.consoleSocketPath == path else { return false }
                        self.consoleClient = client
                        return true
                    }
                    if !kept { client.close() }
                    return
                } catch {
                    Thread.sleep(forTimeInterval: 0.25)   // socket not up yet; retry
                }
            }
        }
    }

    /// Handle a QMP event (called on the QmpClient reader queue). A `SHUTDOWN`
    /// with `reason: guest-shutdown` means the guest powered itself off via the
    /// sun4m AUX2_PWROFF path, which fires *after* `init 5` syncs the filesystems
    /// -- so it's a clean-halt signal. We back up the console-string detection
    /// (fire once, dedup with `sawCleanHalt`), independent of who initiated it.
    private func handleQmpEvent(_ event: [String: Any]) {
        guard (event["event"] as? String) == "SHUTDOWN" else { return }
        let reason = (event["data"] as? [String: Any])?["reason"] as? String
        queue.async { [weak self] in
            guard let self = self, reason == "guest-shutdown", !self.sawCleanHalt else { return }
            self.sawCleanHalt = true
            let cb = self.cleanHaltCallback
            DispatchQueue.main.async { cb?() }
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
    public static func buildArguments(config: QemuEngineConfig, heliosSecret: String = "",
                                      qmpSocketPath: String = "",
                                      consoleSocketPath: String = "") -> [String] {
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
        ]
        if consoleSocketPath.isEmpty {
            // Legacy form: serial console multiplexed onto stdio, no framebuffer.
            args += ["-nographic"]
        } else {
            // VM_CONTROL.md Stage 2: route the serial console to a unix socket
            // instead of the stdio pipe, so an orphaned qemu doesn't busy-spin on
            // a hung-up stdio console fd and the console can be reconnected.
            // `-display none` keeps the headless build from any UI; `-monitor none`
            // disables the HMP monitor (its non-graphical default is stdio) because
            // we drive the VM through `-qmp` instead.
            args += [
                "-display", "none",
                "-serial", "unix:\(consoleSocketPath),server=on,wait=off",
                "-monitor", "none",
            ]
        }
        args += [
            "-L", config.firmwareDir.path,                  // bundled openbios-sparc32 lives here
            "-prom-env", "input-device=ttya",               // OpenBOOT console policy: serial from boot
            "-prom-env", "output-device=ttya",
            // Console speed via the OpenBoot console line setting (was the 9600
            // default). ttya-mode = baud,bits,parity,stop,handshake. The
            // emulated ESCC doesn't pace by baud itself (Tx immediate, no FIFO
            // in hw/char/escc.c); the guest (OpenBIOS/Solaris) paces by ospeed,
            // so a higher rate -> faster console. 115200 is honored and stable
            // here (verified live: faster than 38400, clear/top fine) even
            // though it's above the real sun zilog's 38400 -- qemu does no real
            // bit-timing so the emulated line happily runs faster than the
            // hardware could. The earlier clear/top breakage at 115200 was just
            // the fresh-boot TERM default, not the baud. -prom-env is
            // runtime-only (never persisted to the image).
            "-prom-env", "ttya-mode=115200,8,n,1,-",
        ]
        if !heliosSecret.isEmpty {
            args += ["-prom-env", "helios-secret=\(heliosSecret)"]
        }
        if !qmpSocketPath.isEmpty {
            // QMP control channel (VM_CONTROL.md Stage 1): server mode, don't wait
            // for a client, so qemu boots whether or not macXserver has connected.
            args += ["-qmp", "unix:\(qmpSocketPath),server=on,wait=off"]
        }
        args += [
            "-nic", nic,
            "-drive", "file=\(config.diskImage.path),bus=0,unit=0,media=disk",
        ]
        return args
    }

    /// Per-launch QMP socket under the user-private temp dir (mode-700 on macOS,
    /// so the unauthenticated QMP socket isn't world-reachable). Short enough for
    /// the sockaddr_un 104-byte limit.
    private static func makeQmpSocketPath() -> String {
        let name = "macxserver-qmp-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    /// Per-launch serial-console socket, same placement/constraints as the QMP
    /// socket (mode-700 temp dir, short enough for the 104-byte sockaddr_un limit).
    private static func makeConsoleSocketPath() -> String {
        let name = "macxserver-con-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
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

    /// Mac-side port forwarded to the guest's telnet (23). Used by launchers
    /// with `transport = telnet` and by the by-hand shutdown instructions
    /// (orphan shutdown itself goes over Helios, not telnet).
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

    /// Process a console chunk: forward it to the UI and fire the boot/shutdown
    /// markers (clean-halt, fsck stall, progress). Read-only -- the console is a
    /// pure observation glass-TTY; control (readiness, shutdown) runs over Helios,
    /// not the console. Runs on `queue` so the flags and tail buffer aren't raced.
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

        // Raw bytes to the interactive terminal (escape sequences intact).
        let dcb = consoleDataCallback
        DispatchQueue.main.async { dcb?(data) }
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
