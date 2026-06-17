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
        /// No disk image installed yet (the menu offers "Install").
        case notInstalled
        /// Image present, engine not running (the menu offers "Run").
        case stopped
        /// Engine running (the menu offers "Stop"; launcher entry un-grays).
        case running
    }

    private let config: QemuEngineConfig
    private let queue = DispatchQueue(label: "swiftx.qemu-engine")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var isRunning = false

    private var consoleCallback: ((String) -> Void)?
    private var stateCallback: ((State) -> Void)?

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

    // MARK: - State

    /// Current state. When not running, distinguishes notInstalled vs stopped
    /// by whether the disk image is on disk.
    public var state: State {
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

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // No stdin for v1: the observation window is read-only. Interactive
        // console / QMP control is a post-v1 concern.
        p.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.handleChunk(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.handleChunk(data)
        }

        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self = self else { return }
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.handleChunk(rest)
                }
                if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.handleChunk(rest)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.isRunning = false
                self.emitState()
            }
        }

        self.process = p
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        do {
            try p.run()
        } catch {
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            throw QemuEngineError.spawnFailed(error.localizedDescription)
        }
        isRunning = true
        emitState()
    }

    public func stop() {
        queue.async { [weak self] in
            self?.process?.terminate()
        }
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

    // MARK: - I/O

    private func handleChunk(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else { return }
        let cb = consoleCallback
        DispatchQueue.main.async { cb?(s) }
    }

    private func emitState() {
        let s = state
        let cb = stateCallback
        DispatchQueue.main.async { cb?(s) }
    }
}
