import AppKit
import Darwin
import UniformTypeIdentifiers
import SwiftXServerCore
import SwiftXCaptureCore
import SwiftXCaptureUI

// Wires up the menu-bar (status item) presence and the standard Mac main
// menu. The app runs as `.accessory` so there's no Dock icon; the status
// item is the only thing in the menu bar that's always visible. When one of
// our X windows becomes key, AppKit shows the main menu (Edit > Copy/Paste,
// App > Preferences..., Quit) at the top of the screen as usual.

/// NSApplicationDelegate for the server app: owns the status-bar item, the
/// standard Mac main menu, and the Preferences / Resources / Launchers windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    /// User-facing settings (capture, display scale, clipboard, Motif frame).
    let preferences: Preferences

    private var statusItem: NSStatusItem?
    private var prefsController: PreferencesWindowController?
    private var resourcesController: ResourcesWindowController?
    private var acknowledgementsController: AcknowledgementsWindowController?
    private var fontMappingsController: FontMappingsWindowController?
    private var dnsAdminController: DnsAdminWindowController?
    /// Helios file-browser windows, one per filebrowser launcher entry, keyed by
    /// "group/name" so reopening reuses the window (and its current folder).
    private var fileBrowserControllers: [String: FileBrowserWindowController] = [:]
    /// The SPARCstation "Admin" submenu parent; enabled only once the guest is
    /// fully booted (its tasks talk to the Helios daemon, which only answers
    /// then), gated on the machine's `controller?.isReady` -- NOT mere
    /// `.running`, which is true the instant the qemu process launches, long
    /// before the daemon is up.
    private var adminMenuItem: NSMenuItem?
    /// The SPARCstation submenu's leaf items. We turn off auto-enable for that
    /// submenu and drive these directly from the engine callbacks, so dim/undim
    /// happens live -- including while the menu is held open -- instead of only
    /// at menu-open time the way validateMenuItem works. See refreshSparcMenu().
    private var startMenuItem: NSMenuItem?
    private var shutDownMenuItem: NSMenuItem?
    private var forceQuitMenuItem: NSMenuItem?
    private var showConsoleMenuItem: NSMenuItem?
    private var backUpMenuItem: NSMenuItem?
    /// Whether the bundled machine's guest has answered `hello` this run lives
    /// on its `MachineController` now (`controller?.isReady`) -- it's per-machine
    /// state, not an app-global. Cleared the moment state leaves `.running` (so
    /// shutdown dims Admin immediately, and a fresh boot starts dimmed until the
    /// daemon actually answers).
    /// Shared model for the SPARCstation > Config windows (disk image, shared
    /// folder, Claude development). Created lazily; all Config windows bind to
    /// the one instance so they stay consistent. Writes flow to Preferences.
    private var sparcConfigModel: SparcConfigModel?
    /// One reused window controller per Config section.
    private var sparcConfigWindows: [SparcConfigSection: SparcConfigWindowController] = [:]
    private var launchersController: LaunchersWindowController?
    /// Open capture-viewer windows. The viewer supports multiple windows so
    /// several captures can be compared; each removes itself here on close.
    private var captureViewers: [CaptureViewerWindowController] = []
    private var currentLauncherFile: LauncherFile?
    private var launchersMenu: NSMenu?
    private var activeLauncher: RemoteLauncher?
    private var progressController: LaunchProgressWindowController?

    /// The machine registry: the configured machines + their live controllers,
    /// and the MCP-visible discovery layer. Loaded at launch (migrating from the
    /// legacy launchers file on first run). In P1 only the bundled emulated VM
    /// (`bundledMachineID`) has its lifecycle wired to the SPARCstation menu; the
    /// other machines are data awaiting the P1c list window.
    private var registry: MachineRegistry?
    /// The bundled emulated VM's id -- the machine the SPARCstation menu drives.
    private var bundledMachineID: UUID?
    /// The bundled machine's controller, via the registry. Get-only: the write
    /// paths are `registry.setController` (rebuildSparcEngine) and the
    /// controller's own `isReady`. Nil until the registry + controller exist.
    private var controller: MachineController? {
        guard let registry, let id = bundledMachineID else { return nil }
        return registry.controller(id)
    }
    private var sparcConsole: SparcPlugConsoleWindowController?
    private var sparcWelcome: SparcStationWelcomeWindowController?
    /// The Machines list window (the front door) + its observable model. Built at
    /// launch; the model's rows are recomputed by `refreshMachineList` from the
    /// registry + live controller state, the same source `refreshSparcMenu` reads.
    private var machineListWindow: MachineListWindowController?
    private var machineListModel: MachineListModel?
    /// Boot progress (0...1) of the bundled machine, mirrored into the list row's
    /// dot. Set from the engine's onProgress, reset when it leaves running.
    private var bundledBootProgress: Double?
    /// Set when an orphan's Helios shutdown call fails fast (connection refused,
    /// timed out, or auth rejected), so the poll loop can flip the panel to its
    /// failure state without waiting out the full countdown. Reset at the start
    /// of each attempt.
    private var orphanShutdownFailed = false
    /// Set when the user chose "Quit and Detach" with the VM still running. Tells
    /// `applicationWillTerminate` to PRESERVE the Claude-dev secret file: the guest
    /// keeps running after we quit, so Claude Code must still be able to reach its
    /// daemon. (A normal quit / guest exit clears it -- the secret is then dead.)
    private var detachingSparcOnQuit = false
    /// Live progress panel shown while we wait for an orphan to power off.
    /// Non-nil only during an in-flight "Try to Shut It Down"; its presence is
    /// also the poll loop's keep-going signal (cleared the instant the user
    /// cancels or escalates).
    private var sparcShutdownProgress: SparcShutdownProgressWindowController?

    /// LAN host the launcher hands to remote apps as `DISPLAY`; set by the
    /// bootstrap once the listener resolves the bind address.
    var advertisedHost: String = "localhost"
    /// X display number (port minus 6000), used to build the `DISPLAY` string.
    var displayNumber: String = "0"

    /// Display string shown in the status-bar menu's first (disabled) row,
    /// e.g. "Listening on :6000 (display :0)". main.swift sets this once
    /// the listener has bound; we copy it into the menu when the menu is
    /// next built.
    var listenerStatus: String = "MacXServer" {
        didSet { updateStatusMenu() }
    }

    /// Whether server-side capture is on for this process. Set once at
    /// startup from main.swift after CLI/Preferences resolution.
    /// Surfaced as a quiet suffix on the address row (no new menu
    /// items — status menu stays minimal per Todd's call).
    var captureActive: Bool = false {
        didSet { updateStatusMenu() }
    }

    /// Listener handle so the "Drop All Clients" menu action can reach
    /// it. Held weakly because the listener owns its own lifetime in
    /// ServerEntry.run and the AppDelegate shouldn't keep it alive.
    weak var listener: Listener?

    /// Window bridge handle so "Drop All Clients" can hard-sweep every
    /// managed NSWindow after the sessions are cancelled, catching any
    /// orphaned popup whose slot has drifted from a session's window
    /// table. Weak: ServerEntry.run owns the bridge for the listener's
    /// lifetime.
    weak var bridge: CocoaWindowBridge?

    /// Builds the delegate and its `Preferences` instance. Runs the one-
    /// time `[pointer]` resource-file → UserDefaults migration before the
    /// `Preferences` is observed, so a stale `swapButtons23: true` in the
    /// user's file lands as the right popup selections on first launch.
    /// Then snapshots the current mapping into `PointerConfig` so the
    /// first click after launch already honors the user's preference.
    override init() {
        Preferences.migratePointerResourceSection()
        let prefs = Preferences()
        prefs.applyPointerConfig()
        self.preferences = prefs
        super.init()
        // Re-apply whenever the Preferences dialog (or any other writer)
        // mutates a value. PointerConfig.install is the cheap path; we
        // re-snapshot all three keys but only the pointer ones can have
        // changed in a way that affects PointerConfig.
        NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.preferences.applyPointerConfig()
        }
    }

    /// Thread-safe handle to the clipboard preferences for the listener thread.
    nonisolated var sharedPreferences: ClipboardPreferencesProvider { preferences }

    // MARK: - NSApplicationDelegate

    /// Installs the status-bar item and main menu, and starts watching the
    /// launchers file for changes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wipe any dev-secret file left by a prior crashed session before we do
        // anything -- it's stale (a new guest gets a new secret) and shouldn't
        // outlive the session that wrote it.
        clearClaudeDevSecretFile()
        installStatusItem()
        installMainMenu()
        loadMachineRegistry()
        setupSparcEngine()
        setupMachineListWindow()
        checkForReconnectableOrphanOnLaunch()
        NotificationCenter.default.addObserver(
            self, selector: #selector(launchersFileChanged(_:)),
            name: .launchersFileDidChange, object: nil
        )
    }

    /// Build the engine controller and keep it in sync with the disk-image
    /// path in Preferences (the source of truth for where the image lives).
    private func setupSparcEngine() {
        rebuildSparcEngine()
        // When the disk-image path changes in Preferences, rebuild so the
        // menu state and the next Run pick it up. Don't yank the config out
        // from under a running VM.
        NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main means this block runs on the main thread, so the
            // main-actor hop is an assertion, not a dispatch.
            MainActor.assumeIsolated {
                guard let self = self, self.controller?.engine.state != .running else { return }
                self.syncBundledMachineImageFromPreferences()
                self.rebuildSparcEngine()
            }
        }
    }

    /// Load the machine registry, migrating the legacy launchers file on first
    /// run. The bundled emulated VM is the machine the SPARCstation menu drives.
    /// `bundledUser` is only consulted when migration has to seed a bundled
    /// machine with no launcher group to copy from (rare -- the seeded launchers
    /// file normally supplies a loopback group), so we derive it best-effort.
    private func loadMachineRegistry() {
        let launchers = LauncherFileLoader.loadOrSeed(seed: DefaultLaunchers.seedContent)
        let bundledUser = launchers.entries.first(where: { Self.isLoopbackHost($0.host) })?.user
            ?? launchers.entries.first?.user ?? ""
        let registry = MachineRegistry.load(bundledImagePath: preferences.sparcDiskImagePath,
                                            bundledUser: bundledUser)
        self.registry = registry
        self.bundledMachineID = registry.bundledMachine?.id
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "0.0.0.0", "::1"].contains(host.lowercased())
    }

    /// Keep the registry's bundled machine image in step with the Config UI, which
    /// still writes `sparcplug.diskImagePath` in P1 (the engine config is built
    /// from Preferences via makeSparcConfig, not yet from the machine -- see
    /// SHORTCUTS). Without this the registry's stored image would go stale after
    /// the user picks a new disk image.
    private func syncBundledMachineImageFromPreferences() {
        guard let registry, var m = registry.bundledMachine else { return }
        let newPath = preferences.sparcDiskImagePath.isEmpty ? nil : preferences.sparcDiskImagePath
        if m.imagePath != newPath {
            m.imagePath = newPath
            registry.update(m)
        }
    }

    // MARK: - Machines list window

    /// Build the list window + model, wire its actions to the existing lifecycle
    /// and launch methods, and open it as the front door. In P1 only the bundled
    /// emulated VM has lifecycle controls; the closures ignore the machine id for
    /// those (they drive the one wired machine) and use it for launches.
    private func setupMachineListWindow() {
        let model = MachineListModel()
        model.onStart     = { [weak self] _ in self?.startSparcStation(nil) }
        model.onShutDown  = { [weak self] _ in self?.shutDownSparcStation(nil) }
        model.onForceQuit = { [weak self] _ in self?.confirmForceQuit() }
        model.onBackup    = { [weak self] _ in self?.backUpDiskImage(nil) }
        model.onConsole   = { [weak self] _ in self?.showSparcConsole(nil) }
        model.onLaunch    = { [weak self] id, name in self?.launchFromMachine(id, launcherName: name) }
        model.onSetHeliosSecret = { [weak self] id in self?.promptHeliosSecret(for: id) }
        model.onAddMachine = { [weak self] in self?.presentAddMachineComingSoon() }
        self.machineListModel = model
        let controller = MachineListWindowController(model: model)
        self.machineListWindow = controller
        refreshMachineList()
        controller.showWindow()
    }

    /// Reopen (or focus) the list window -- from the status item / Machines menu.
    @MainActor
    @objc private func openMachineList(_ sender: Any?) {
        machineListWindow?.showWindow()
    }

    /// Recompute the list rows from the registry + live controller state. Mirrors
    /// `refreshSparcMenu`'s gating exactly so the window and the menu agree.
    private func refreshMachineList() {
        guard let registry, let model = machineListModel else { return }
        let bundledID = bundledMachineID
        model.rows = registry.machines.map { m in
            let isBundled = (m.id == bundledID)
            let isEmulated = m.kind == .emulatedVM
            let ctrl = registry.controller(m.id)
            let state = ctrl?.engine.state ?? .notInstalled
            let ready = ctrl?.isReady ?? false

            let dot: MachineStatusDot
            let statusText: String
            var progress: Double? = nil
            if !isEmulated {
                dot = .external; statusText = "external"
            } else if !m.isInstalledEmulatedVM {
                dot = .notInstalled; statusText = "not installed"
            } else if state == .running && ready {
                dot = .running; statusText = "running"
            } else if state == .running {
                dot = .booting; statusText = "booting"
                progress = isBundled ? bundledBootProgress : nil
            } else if state == .shuttingDown {
                dot = .booting; statusText = "shutting down"
            } else {
                dot = .stopped; statusText = "stopped"
            }

            let subtitle = isEmulated
                ? (m.image.map { $0.lastPathComponent } ?? "no disk image")
                : "\(m.host) · external"

            let chips = m.launchers.map { l -> MachineLauncherChip in
                // Same gating as validateMenuItem: a helios launcher on the
                // bundled guest needs the daemon up; everything else is enabled.
                let transport = l.transport ?? m.transport
                let enabled = !(isBundled && transport == .helios) || ready
                return MachineLauncherChip(id: l.name, name: l.name,
                                           isFileBrowser: l.fileBrowser, enabled: enabled)
            }

            return MachineRow(
                id: m.id, name: m.name, isEmulated: isEmulated,
                subtitle: subtitle, statusText: statusText, dot: dot, progress: progress,
                showsLifecycle: isBundled,
                canStart: (state == .stopped || state == .notInstalled),
                canShutDown: (state == .running && ready),
                canForceQuit: (state == .running || state == .shuttingDown),
                canBackup: (state == .stopped),
                canConsole: (sparcConsole != nil),
                canSetHeliosSecret: !isEmulated,
                launchers: chips)
        }
    }

    /// Launch (or open the file browser for) one of a machine's launchers, reusing
    /// the same paths the Launchers menu uses.
    private func launchFromMachine(_ machineID: UUID, launcherName: String) {
        guard let machine = registry?.machine(machineID),
              let ml = machine.launchers.first(where: { $0.name == launcherName }) else { return }
        var warnings: [String] = []
        guard let entry = machine.resolved(ml, warnings: &warnings) else { return }
        if entry.fileBrowser {
            openFileBrowser(entry: entry, key: "\(machine.id.uuidString)/\(ml.name)")
        } else {
            launch(entry)
        }
    }

    /// Enter / update / clear the Helios daemon secret for an external machine,
    /// stored in the Keychain keyed by user@host. Prefilled with the current
    /// value; blank clears it.
    @MainActor
    private func promptHeliosSecret(for machineID: UUID) {
        guard let m = registry?.machine(machineID) else { return }
        let account = heliosSecretAccount(host: m.host, user: m.user)
        let alert = NSAlert()
        alert.messageText = "Helios secret for \(m.user)@\(m.host)"
        alert.informativeText = "Enter the Helios daemon secret for this machine. "
            + "Leave blank to clear it. Stored in your macOS Keychain, sent as the "
            + "daemon's auth on every Helios call to this host."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = SecretEntryField()
        field.value = KeychainHelper.retrieve(account: account) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field.activeField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.value
        if value.isEmpty {
            KeychainHelper.delete(account: account)
        } else {
            try? KeychainHelper.store(account: account, password: value)
        }
        refreshMachineList()
    }

    private func presentAddMachineComingSoon() {
        let alert = NSAlert()
        alert.messageText = "Adding machines isn't available yet"
        alert.informativeText = "For now, machines are migrated from your launchers. "
            + "Editing and adding machines from this window lands in a follow-up."
        alert.runModal()
    }

    /// Resolve the engine config: the engine binary comes from the app
    /// bundle (or SPARCPLUG_ENGINE_DIR in dev), and the disk image from the
    /// Preferences path. Empty path -> the engine reports notInstalled.
    private func makeSparcConfig() -> QemuEngineConfig {
        var config = QemuEngine.defaultConfig()
        let path = preferences.sparcDiskImagePath
        if !path.isEmpty {
            config.diskImage = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        // Shared folder (TFTP): only wire it when the toggle is on. Create the
        // directory if it's missing so slirp (read-only, won't create it) has
        // something to serve. Failure to create just means no shared folder
        // this run, not a failed launch.
        if preferences.sparcTftpEnabled {
            let dir = (preferences.sparcTftpDirectory as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            config.tftpDirectory = dir
        }
        return config
    }

    /// (Re)create the engine and route its console + state to the observation
    /// window. The closures fire on the main queue (QemuEngine dispatches
    /// them), so touching the console window here is safe.
    private func rebuildSparcEngine() {
        // Build the bundled machine's controller keyed by its registry id. Engine
        // config still comes from Preferences (makeSparcConfig) in P1, not from
        // machine.makeEngineConfig -- the Config UI writes Preferences, so this
        // stays the source until the UI moves to the machine (SHORTCUTS).
        let controller = MachineController(id: bundledMachineID ?? UUID(),
                                           config: makeSparcConfig())
        let engine = controller.engine
        engine.onConsoleData { [weak self] data in
            self?.sparcConsole?.feedConsoleData(data)
        }
        engine.onStateChange { [weak self] state in
            self?.sparcConsole?.setState(state)
            // Keep the Preferences "restart to apply" note in sync if the
            // window is open. Running or shutting-down both mean a shared-
            // folder change can't take effect until the next clean start.
            self?.sparcConfigModel?.sparcEngineRunning =
                (state == .running || state == .shuttingDown)
            // Anything other than steady .running (boot-in-progress counts as
            // .running too, but shutdown/stop don't) means the daemon isn't
            // answering -- drop readiness so Admin dims. onReady re-enables it.
            if state != .running {
                self?.controller?.isReady = false
                self?.bundledBootProgress = nil
            }
            self?.refreshSparcMenu()
        }
        engine.onCleanHalt { [weak self] in
            self?.sparcConsole?.markCleanHalt()
        }
        engine.onProgress { [weak self] value in
            self?.sparcConsole?.setProgress(value)
            self?.bundledBootProgress = value
            self?.refreshMachineList()
        }
        engine.onReady { [weak self] in
            self?.sparcConsole?.markReady()
            // Daemon answered -- the guest is fully up. Unlock graceful Shut Down
            // and Admin now (not at process launch).
            self?.controller?.isReady = true
            self?.refreshSparcMenu()
        }
        engine.onBootStalled { [weak self] reason in
            // Wedged guest -- make sure the user sees it and can Force Quit.
            self?.ensureSparcConsole()
            self?.sparcConsole?.showWindow()
            self?.sparcConsole?.markBootStalled(reason)
        }
        engine.onShutdownUnavailable { [weak self] in
            // Graceful path couldn't reach the daemon -- surface Force Quit.
            self?.sparcConsole?.markShutdownUnavailable()
        }
        engine.onTerminated { [weak self] wasCleanHalt in
            self?.autoBackupAfterCleanShutdown(wasCleanHalt: wasCleanHalt)
            // The per-launch secret died with the guest; don't leave it on disk.
            self?.clearClaudeDevSecretFile()
        }
        if let id = bundledMachineID { registry?.setController(controller, for: id) }
        self.sparcConsole?.setState(engine.state)
    }

    /// Last gasp on a graceful quit: make sure the dev-secret file doesn't
    /// outlive the app. (The guest-exit path usually clears it first, since we
    /// block quitting while the VM runs; this covers the rest.)
    func applicationWillTerminate(_ notification: Notification) {
        // On a "Quit and Detach" the guest stays up, so its secret is still live --
        // leave the file so Claude Code keeps its daemon access. Every other quit
        // clears it (the secret dies with the guest, or there was none).
        if !detachingSparcOnQuit {
            clearClaudeDevSecretFile()
        }
    }

    /// Returns false so the status-bar app keeps running with no X windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Status-bar app — keep running after the last X window closes so
        // we can accept a fresh client connection without relaunching.
        false
    }

    /// Quitting macXserver with a SPARCstation still running is now a real choice,
    /// not a footgun: detaching leaves qemu running in the background (the serial
    /// console is on a socket, so there's no orphan CPU-spin), and macXserver will
    /// offer to reconnect next launch (VM_CONTROL.md Stage 3). So the dialog offers
    /// both -- **Quit and Detach** (leave it running) or **Go to Console** (shut
    /// Solaris down cleanly first) -- plus Cancel. The only thing detaching skips
    /// is the clean `init 5` sync; the VM keeps managing its own disk, so it's
    /// safe, but a clean shutdown is still tidier.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = controller?.engine,
              engine.state == .running || engine.state == .shuttingDown else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "The SPARCstation is still running"
        alert.informativeText = "You can quit and leave it running in the background -- macXserver "
            + "will offer to reconnect the next time you launch -- or go to its console to shut "
            + "Solaris down cleanly first. Detaching is safe; the VM keeps managing its own disk."
        alert.addButton(withTitle: "Quit and Detach")   // first / default
        alert.addButton(withTitle: "Go to Console")      // second
        alert.addButton(withTitle: "Cancel")             // third
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Detach: let the app terminate. qemu reparents to launchd and keeps
            // running; the image lock persists so the next launch can reconnect.
            // Preserve the Claude-dev secret file so Claude Code can still reach
            // the still-running guest while we're quit.
            detachingSparcOnQuit = true
            return .terminateNow
        case .alertSecondButtonReturn:
            ensureSparcConsole()
            sparcConsole?.showWindow()
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display",
                                     accessibilityDescription: "MacXServer")
        item.button?.image?.isTemplate = true
        statusItem = item
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        // Status-bar menu is deliberately minimal: the listening address
        // (so you can read off `xterm -display ...` at a glance) and a
        // way to stop the server. Everything else — Preferences,
        // editors, capture actions — lives in the standard app menu at
        // the top of the screen.
        let rowTitle = captureActive
            ? "\(listenerStatus) · capturing"
            : listenerStatus
        let statusRow = NSMenuItem(title: rowTitle, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        let openMgr = NSMenuItem(title: "Open Machine Manager\u{2026}",
                                 action: #selector(openMachineList(_:)),
                                 keyEquivalent: "")
        openMgr.target = self
        menu.addItem(openMgr)
        menu.addItem(.separator())

        let stopRow = NSMenuItem(title: "Stop Server",
                                 action: #selector(NSApplication.terminate(_:)),
                                 keyEquivalent: "")
        menu.addItem(stopRow)

        item.menu = menu
    }

    // MARK: - Main menu

    private func installMainMenu() {
        let main = NSMenu()

        // App menu (the bold one, always titled with the process name).
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About MacXServer",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        let acknowledgements = NSMenuItem(title: "Acknowledgements\u{2026}",
                                          action: #selector(openAcknowledgements(_:)),
                                          keyEquivalent: "")
        acknowledgements.target = self
        appMenu.addItem(acknowledgements)
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences\u{2026}",
                               action: #selector(openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)

        let resources = NSMenuItem(title: "Edit Resources\u{2026}",
                                   action: #selector(openResources(_:)),
                                   keyEquivalent: "")
        resources.target = self
        appMenu.addItem(resources)

        let fonts = NSMenuItem(title: "Edit Font Mappings\u{2026}",
                               action: #selector(openFontMappings(_:)),
                               keyEquivalent: "")
        fonts.target = self
        appMenu.addItem(fonts)

        appMenu.addItem(.separator())

        // Capture actions — the toggle lives in Preferences (Capture
        // tab). These are pure actions on the captures folder so they
        // belong here, not on the status-bar menu.
        let openCapture = NSMenuItem(title: "Open Capture\u{2026}",
                                     action: #selector(openCapture(_:)),
                                     keyEquivalent: "")
        openCapture.target = self
        appMenu.addItem(openCapture)

        let revealCaptures = NSMenuItem(title: "Reveal Captures Folder",
                                        action: #selector(revealCapturesFolder(_:)),
                                        keyEquivalent: "")
        revealCaptures.target = self
        appMenu.addItem(revealCaptures)

        let discardCaptures = NSMenuItem(title: "Discard All Captures\u{2026}",
                                         action: #selector(discardAllCaptures(_:)),
                                         keyEquivalent: "")
        discardCaptures.target = self
        appMenu.addItem(discardCaptures)

        appMenu.addItem(.separator())

        // One-and-done: cancel every active client read source. Listener
        // keeps accepting new connections. Useful when a stuck client
        // (orphan top-levels from a WM-emulation bug, a Sun ssh session
        // that got wedged) won't clean itself up.
        let dropClients = NSMenuItem(title: "Drop All Clients",
                                     action: #selector(dropAllClients(_:)),
                                     keyEquivalent: "")
        dropClients.target = self
        appMenu.addItem(dropClients)

        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide MacXServer",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MacXServer",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        // Edit menu — Cut/Copy/Paste route through the responder chain via
        // selectors `cut:` `copy:` `paste:`. FlippedXView implements `copy:`
        // and `paste:`; with target=nil and a key equivalent set, AppKit
        // walks up the responder chain to find a handler when the menu
        // item fires.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        // Launchers submenu -- one-click launch of X apps on remote Suns.
        let launchersMenuItem = NSMenuItem()
        let lMenu = NSMenu(title: "Launchers")
        self.launchersMenu = lMenu
        rebuildLaunchersMenu(lMenu)
        launchersMenuItem.submenu = lMenu
        main.addItem(launchersMenuItem)

        // SPARCstation menu -- the bundled QEMU SS-5. Start handles the
        // missing-image case itself (it presents the install flow), so there's
        // no separate Install item.
        //
        // Two stop verbs, deliberately gated differently:
        //  - "Shut Down" is the graceful halt (init 5 via the Helios daemon). It
        //    only works once the guest is fully up, so it gates on `isReady`,
        //    NOT mere `.running` (which is true the instant qemu launches, while
        //    Solaris is still booting and the daemon isn't listening yet).
        //  - "Force Quit" is the hard power-off (QMP quit / SIGTERM). It's always
        //    available while running, so there's a way out during boot or a wedge.
        let sparcMenuItem = NSMenuItem()
        let sparcMenu = NSMenu(title: "SPARCstation")
        // Drive these items' enablement ourselves (see the leaf-item properties
        // and refreshSparcMenu): auto-enable only revalidates at menu-open, which
        // leaves dim/undim stale if the guest's state changes while the menu is
        // held open. The Config/Admin submenus keep their own auto-enable.
        sparcMenu.autoenablesItems = false
        let start = NSMenuItem(title: "Start SPARCstation",
                               action: #selector(startSparcStation(_:)), keyEquivalent: "")
        start.target = self
        sparcMenu.addItem(start)
        startMenuItem = start
        let shutDown = NSMenuItem(title: "Shut Down SPARCstation",
                                  action: #selector(shutDownSparcStation(_:)), keyEquivalent: "")
        shutDown.target = self
        sparcMenu.addItem(shutDown)
        shutDownMenuItem = shutDown
        let forceQuit = NSMenuItem(title: "Force Quit SPARCstation\u{2026}",
                                   action: #selector(forceQuitSparcStation(_:)), keyEquivalent: "")
        forceQuit.target = self
        sparcMenu.addItem(forceQuit)
        forceQuitMenuItem = forceQuit
        sparcMenu.addItem(.separator())
        let showConsole = NSMenuItem(title: "Show Console",
                                     action: #selector(showSparcConsole(_:)), keyEquivalent: "")
        showConsole.target = self
        sparcMenu.addItem(showConsole)
        showConsoleMenuItem = showConsole
        let backup = NSMenuItem(title: "Back Up Disk Image\u{2026}",
                                action: #selector(backUpDiskImage(_:)), keyEquivalent: "")
        backup.target = self
        sparcMenu.addItem(backup)
        backUpMenuItem = backup
        sparcMenu.addItem(.separator())
        // Config submenu -- the bundled-SPARCstation setup that used to be the
        // Preferences "SPARCstation" tab, one window per task. Available
        // whether or not the guest is running (these are launch-time settings).
        let configItem = NSMenuItem(title: "Config", action: nil, keyEquivalent: "")
        let configMenu = NSMenu(title: "Config")
        for section in [SparcConfigSection.diskImage, .sharedFolder, .claudeDev] {
            let item = NSMenuItem(title: section.menuTitle,
                                  action: #selector(openSparcConfig(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = section
            configMenu.addItem(item)
        }
        configItem.submenu = configMenu
        sparcMenu.addItem(configItem)
        // Admin submenu -- guided sysadmin tasks run over the Helios daemon.
        // The daemon only answers while the guest is up, so the DNS item gates
        // on state == .running in validateMenuItem and the parent grays out
        // when stopped (kept in sync in onStateChange below).
        let adminItem = NSMenuItem(title: "Admin", action: nil, keyEquivalent: "")
        let adminMenu = NSMenu(title: "Admin")
        let dns = NSMenuItem(title: "DNS (/etc/resolv.conf)\u{2026}",
                             action: #selector(openDnsAdmin(_:)), keyEquivalent: "")
        dns.target = self
        adminMenu.addItem(dns)
        adminItem.submenu = adminMenu
        self.adminMenuItem = adminItem
        sparcMenu.addItem(adminItem)
        sparcMenuItem.submenu = sparcMenu
        main.addItem(sparcMenuItem)
        refreshSparcMenu()   // set the initial enabled states

        // Window menu -- minimise / close are handy when an X window is up.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Close",
                                      action: #selector(NSWindow.performClose(_:)),
                                      keyEquivalent: "w"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    // MARK: - Actions

    @MainActor
    @objc private func openPreferences(_ sender: Any?) {
        if prefsController == nil {
            prefsController = PreferencesWindowController(preferences: preferences)
        }
        // Always land on the first tab when opened from the menu. The window
        // controller is reused, so without this the model retains the last
        // tab and reopening drops you wherever you were, not at the top.
        prefsController?.showWindow(selecting: .cutPaste)
    }

    @MainActor
    @objc private func openResources(_ sender: Any?) {
        if resourcesController == nil {
            resourcesController = ResourcesWindowController()
        }
        resourcesController?.showWindow()
    }

    @MainActor
    @objc private func openAcknowledgements(_ sender: Any?) {
        if acknowledgementsController == nil {
            acknowledgementsController = AcknowledgementsWindowController()
        }
        acknowledgementsController?.showWindow()
    }

    /// Shared Config model, created on first use and seeded with the current
    /// engine-running state so the Shared Folder window's "restart to apply"
    /// note is correct the instant it opens.
    @MainActor
    private func ensureSparcConfigModel() -> SparcConfigModel {
        if let model = sparcConfigModel { return model }
        let running = controller?.engine.state == .running || controller?.engine.state == .shuttingDown
        let model = SparcConfigModel(preferences: preferences, engineRunning: running)
        sparcConfigModel = model
        return model
    }

    @MainActor
    @objc private func openSparcConfig(_ sender: Any?) {
        guard let section = (sender as? NSMenuItem)?.representedObject as? SparcConfigSection else { return }
        let model = ensureSparcConfigModel()
        let controller = sparcConfigWindows[section]
            ?? SparcConfigWindowController(section: section, model: model)
        sparcConfigWindows[section] = controller
        controller.showWindow()
    }

    @MainActor
    @objc private func openDnsAdmin(_ sender: Any?) {
        if dnsAdminController == nil {
            dnsAdminController = DnsAdminWindowController(
                secretProvider: { [weak self] in self?.controller?.engine.currentSecret })
        }
        dnsAdminController?.showWindow()
    }

    @MainActor
    @objc private func openFontMappings(_ sender: Any?) {
        if fontMappingsController == nil {
            fontMappingsController = FontMappingsWindowController()
        }
        fontMappingsController?.showWindow()
    }

    @MainActor
    @objc private func openCapture(_ sender: Any?) {
        let dir = preferences.captureDirectory
        // mkdir so the picker opens cleanly even before any capture has run.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let panel = NSOpenPanel()
        panel.title = "Open Capture"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: dir)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let xtap = UTType(filenameExtension: "xtap") {
            panel.allowedContentTypes = [xtap]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let decoded = try ChronoDumper.dump(path: url.path)
            let controller = CaptureViewerWindowController(
                title: url.lastPathComponent, sourcePath: url.path, text: decoded)
            controller.onClose = { [weak self, weak controller] in
                self?.captureViewers.removeAll { $0 === controller }
            }
            captureViewers.append(controller)
            controller.showWindow()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't decode capture"
            alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @MainActor
    @objc private func revealCapturesFolder(_ sender: Any?) {
        let path = preferences.captureDirectory
        // mkdir first so reveal works even before any capture has run.
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @MainActor
    @objc private func discardAllCaptures(_ sender: Any?) {
        let path = preferences.captureDirectory
        let fm = FileManager.default

        // Surface a count up front so the user sees what they're
        // committing to. Only count .xtap and .xtap.json — leave any
        // stray files (in-progress markers, accidentally-dropped
        // unrelated files) untouched.
        let captures = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let toRemove = captures.filter { $0.hasSuffix(".xtap") || $0.hasSuffix(".xtap.json") }

        let alert = NSAlert()
        alert.messageText = "Discard all captures?"
        alert.informativeText = toRemove.isEmpty
            ? "No capture files in \(path)."
            : "This will delete \(toRemove.count) file(s) in \(path). The folder itself stays so new captures keep landing there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: toRemove.isEmpty ? "OK" : "Discard")
        if !toRemove.isEmpty {
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()
        guard !toRemove.isEmpty, response == .alertFirstButtonReturn else { return }

        for name in toRemove {
            let full = (path as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: full)
        }
    }

    @objc private func dropAllClients(_ sender: Any?) {
        listener?.dropAllClients()
        // Cancelling the sessions runs each one's cleanupOnDisconnect, which
        // only destroys windows still linked to that session's window table.
        // An orphaned popup (slot drifted from the table) would survive that.
        // This is a user-initiated nuke, so follow up with a bridge-level
        // sweep that closes every managed NSWindow unconditionally — nothing
        // should be left on screen.
        bridge?.closeAllWindows()
    }

    // MARK: - Launchers

    private func rebuildLaunchersMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let file = LauncherFileLoader.loadOrSeed(seed: DefaultLaunchers.seedContent)
        currentLauncherFile = file
        let groups = file.groups()
        // Single-group case: flatten -- a submenu of one is just an extra
        // click for no reason.
        if groups.count == 1 {
            for entry in groups[0].entries { menu.addItem(launcherMenuItem(for: entry)) }
        } else {
            for group in groups {
                let submenu = NSMenu(title: group.label)
                for entry in group.entries { submenu.addItem(launcherMenuItem(for: entry)) }
                let header = NSMenuItem(title: group.label, action: nil, keyEquivalent: "")
                header.submenu = submenu
                menu.addItem(header)
            }
        }
        if !file.entries.isEmpty { menu.addItem(.separator()) }
        let edit = NSMenuItem(title: "Edit Launchers\u{2026}",
                              action: #selector(openLaunchers(_:)),
                              keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
    }

    private func launcherMenuItem(for entry: LauncherEntry) -> NSMenuItem {
        // A filebrowser entry isn't an app launcher: its menu item opens the
        // Helios file browser, never runs a command. It has no `command`, so it
        // must NOT fall through to launchRemoteApp even on a non-helios host
        // (that would silently telnet in and run an empty line). It wires to
        // openFileBrowser regardless of transport; the handler explains the
        // requirement if the transport isn't helios.
        let item = NSMenuItem(title: entry.fileBrowser ? "\(entry.name)\u{2026}" : entry.name,
                              action: entry.fileBrowser ? #selector(openFileBrowser(_:))
                                                        : #selector(launchRemoteApp(_:)),
                              keyEquivalent: "")
        item.target = self
        // group/name disambiguates same-named items across hosts
        // ("xterm cyan" can live under both u5 and ss2).
        item.representedObject = "\(entry.group)/\(entry.name)" as NSString
        return item
    }

    /// True when a launcher entry points at the bundled emulator's Helios daemon
    /// (the qemu hostfwd on the loopback), rather than a real Sun on the LAN.
    /// Only a loopback target's readiness (`controller?.isReady`) and per-launch
    /// secret (`controller?.engine.currentSecret`) apply -- an external box has its own daemon
    /// lifetime and its own (or no) auth, so gating those on the bundled guest
    /// is wrong.
    private func isBundledGuestTarget(_ entry: LauncherEntry) -> Bool {
        let h = entry.host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    /// Keychain account under which an external machine's Helios daemon secret is
    /// stored. Keyed by user@host so it survives a machine rename / re-migration
    /// and is shared by every launcher + file-browser call to that box.
    private func heliosSecretAccount(host: String, user: String) -> String {
        "helios:\(user)@\(host)"
    }

    /// The Helios `auth` secret to present to a box's daemon. The bundled emulator
    /// uses its per-boot `-prom-env` secret from the engine; an external host uses
    /// the secret the user saved in the Keychain (nil = none saved -- an open
    /// daemon still works, a secured one rejects until the user sets it). Supplying
    /// a secret to an open daemon is harmless, so this is safe against both.
    private func heliosSecret(host: String, user: String) -> String? {
        let h = host.lowercased()
        if h == "127.0.0.1" || h == "localhost" || h == "::1" {
            return controller?.engine.currentSecret
        }
        return KeychainHelper.retrieve(account: heliosSecretAccount(host: host, user: user))
    }

    @MainActor
    @objc private func openFileBrowser(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let entry = currentLauncherFile?.entries.first(where: { "\($0.group)/\($0.name)" == key }),
              entry.fileBrowser
        else { return }
        openFileBrowser(entry: entry, key: key)
    }

    /// Open (or focus) a Helios file browser for a resolved filebrowser entry,
    /// keyed so the window is reused. Shared by the Launchers menu and machine rows.
    @MainActor
    private func openFileBrowser(entry: LauncherEntry, key: String) {
        // The browser speaks the Helios protocol, so this key must use
        // transport = helios. filebrowser=true on a telnet/ssh key is a config
        // error -- it's under the wrong transport. This is per-key: a sibling
        // helios launcher on the same host doesn't make THIS key browsable.
        // (A correctly-transported key whose box has no agent is a different
        // failure -- the browser window opens and reports the connection error.)
        guard entry.transport == .helios else {
            let alert = NSAlert()
            alert.messageText = "The file browser needs a Helios transport"
            alert.informativeText =
                "\u{201C}\(entry.group)/\(entry.name)\u{201D} has filebrowser = true but "
                + "transport = \(entry.transport.rawValue). The browser moves files over the "
                + "Helios agent, so this key needs transport = helios pointing at a machine "
                + "that has the agent installed. (At present the bundled SPARCstation is the "
                + "only machine set up with the Helios agent.)"
            alert.runModal()
            return
        }

        if fileBrowserControllers[key] == nil {
            // Bundled → its per-boot engine secret; external → the Keychain secret
            // for that box (see heliosSecret). Resolved live each call.
            let host = entry.host, user = entry.user
            let config = HeliosFileBrowserConfig(
                host: entry.host, port: entry.port, user: entry.user,
                label: "\(entry.group): \(entry.user)",
                secretProvider: { [weak self] in self?.heliosSecret(host: host, user: user) })
            fileBrowserControllers[key] = FileBrowserWindowController(config: config)
        }
        fileBrowserControllers[key]?.showWindow()
    }

    @objc private func launchersFileChanged(_ note: Notification) {
        if let menu = launchersMenu { rebuildLaunchersMenu(menu) }
    }

    @MainActor
    @objc private func openLaunchers(_ sender: Any?) {
        if launchersController == nil {
            launchersController = LaunchersWindowController()
        }
        launchersController?.showWindow()
    }

    @MainActor
    @objc private func launchRemoteApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let entry = currentLauncherFile?.entries.first(where: { "\($0.group)/\($0.name)" == key })
        else { return }
        launch(entry)
    }

    /// Launch one resolved entry (from the Launchers menu or a machine row). Picks
    /// the auth path by transport: ssh/helios need none; telnet uses the launcher
    /// password, else the Keychain (prompting on first use).
    @MainActor
    private func launch(_ entry: LauncherEntry) {
        // ssh (keys-only) and helios (daemon, no auth) need no password: skip
        // the prompt and Keychain entirely. Any password field is ignored.
        if entry.transport == .ssh || entry.transport == .helios {
            executeLaunch(entry: entry, password: "")
            return
        }
        // Telnet path: explicit password in the launcher file wins (dev
        // convenience — skips the prompt every launch). Otherwise fall back
        // to the Keychain, prompting and storing on first use.
        if let pw = entry.password, !pw.isEmpty {
            executeLaunch(entry: entry, password: pw)
            return
        }
        let account = "\(entry.user)@\(entry.host)"
        if let password = KeychainHelper.retrieve(account: account) {
            executeLaunch(entry: entry, password: password)
        } else {
            promptForPassword(entry: entry, account: account)
        }
    }

    private func promptForPassword(entry: LauncherEntry, account: String) {
        let alert = NSAlert()
        alert.messageText = "Password for \(account)"
        alert.informativeText = "Enter the login password for \(entry.user) on \(entry.host).\nIt will be stored in the macOS Keychain."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        guard !password.isEmpty else { return }
        try? KeychainHelper.store(account: account, password: password)
        executeLaunch(entry: entry, password: password)
    }

    private func executeLaunch(entry: LauncherEntry, password: String) {
        let display = entry.display ?? "\(advertisedHost):\(displayNumber)"
        let launcher: RemoteLauncher
        switch entry.transport {
        case .telnet:
            launcher = TelnetLauncher(entry: entry, password: password, displayString: display)
        case .ssh:
            launcher = SSHLauncher(entry: entry, displayString: display)
        case .helios:
            // Same bundled-only rule as the file browser: the emulator's
            // per-launch secret goes only to the loopback target, not a real Sun.
            launcher = HeliosLauncher(entry: entry, displayString: display,
                                      secret: heliosSecret(host: entry.host, user: entry.user))
        }
        activeLauncher = launcher

        if entry.verbose {
            let ctrl = LaunchProgressWindowController(title: entry.name)
            progressController = ctrl
            ctrl.showWindow()
            launcher.onStatus { [weak ctrl] message in
                ctrl?.appendStatusLine(message)
            }
            launcher.onText { [weak ctrl] text, bold in
                if bold { ctrl?.appendBoldText(text) }
                else { ctrl?.appendText(text) }
            }
        }

        launcher.launch { [weak self] result in
            self?.activeLauncher = nil
            switch result {
            case .success:
                self?.progressController?.markDone(failed: false)
            case .failure(let error):
                if self?.progressController != nil {
                    self?.progressController?.appendStatusLine("FAILED: \(error.localizedDescription)")
                    self?.progressController?.markDone(failed: true)
                } else {
                    self?.showLaunchError("Launch failed for \(entry.name): \(error.localizedDescription)")
                }
            }
        }
    }

    private func showLaunchError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Launcher Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - SPARCstation

    private func ensureSparcConsole() {
        if sparcConsole == nil {
            let console = SparcPlugConsoleWindowController(
                onShutDown: { [weak self] in self?.controller?.engine.shutDown() },
                onForceQuit: { [weak self] in self?.confirmForceQuit() },
                onInput: { [weak self] data in self?.controller?.engine.sendConsole(data) },
                onLaunchXterm: { [weak self] in
                    self?.controller?.engine.launchXterm { result in
                        if case .failure(let error) = result {
                            let alert = NSAlert()
                            alert.messageText = "Couldn't launch xterm"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.runModal()
                        }
                    }
                }
            )
            console.setState(controller?.engine.state ?? .stopped)
            sparcConsole = console
            refreshSparcMenu()   // "Show Console" can undim now
        }
    }

    /// Recompute the SPARCstation submenu's enabled states from the live engine
    /// state + daemon readiness. Called from the engine callbacks (onStateChange,
    /// onReady) and when the console is created, so dim/undim tracks reality even
    /// while the menu is held open -- the submenu has auto-enable off, so these
    /// assignments are authoritative and there's no validateMenuItem for them.
    @MainActor
    private func refreshSparcMenu() {
        let state = controller?.engine.state ?? .notInstalled
        startMenuItem?.isEnabled    = (state == .stopped || state == .notInstalled)
        // Graceful halt needs the daemon up; greyed through boot. Force Quit
        // (hard power-off) covers stopping during boot or a wedge.
        shutDownMenuItem?.isEnabled  = (state == .running && (controller?.isReady ?? false))
        forceQuitMenuItem?.isEnabled = (state == .running || state == .shuttingDown)
        showConsoleMenuItem?.isEnabled = (sparcConsole != nil)
        backUpMenuItem?.isEnabled    = (state == .stopped)
        adminMenuItem?.isEnabled     = (controller?.isReady ?? false)
        refreshMachineList()
    }

    @MainActor
    @objc private func startSparcStation(_ sender: Any?) {
        guard let engine = controller?.engine else { return }
        switch engine.state {
        case .running, .shuttingDown:
            return                       // menu item is disabled here anyway
        case .stopped:
            launchSparcStation()
        case .notInstalled:
            presentInstallFlow()         // no image yet -> first-run install
        }
    }

    @objc private func shutDownSparcStation(_ sender: Any?) {
        ensureSparcConsole()
        sparcConsole?.showWindow()      // so the user sees the shutdown progress
        controller?.engine.shutDown()
    }

    @MainActor
    @objc private func forceQuitSparcStation(_ sender: Any?) {
        confirmForceQuit()
    }

    @MainActor
    private func confirmForceQuit() {
        let alert = NSAlert()
        alert.messageText = "Force quit the SPARCstation?"
        alert.informativeText = "This pulls the power without a clean shutdown, like yanking the "
            + "cord. Solaris will run fsck on the next boot.\n\nIf it's wedged mid-boot, try the "
            + "console first -- it's a real terminal now, so you can often recover by hand at the "
            + "ok prompt or in single-user. Force Quit only if you can't."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Show Console")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            controller?.engine.kill()
        case .alertSecondButtonReturn:
            ensureSparcConsole()
            sparcConsole?.showWindow()
        default:
            break
        }
    }

    @MainActor
    @objc private func backUpDiskImage(_ sender: Any?) {
        // Only valid when stopped (validateMenuItem enforces it). Copy the
        // qcow2 alongside itself with a dated name and reveal it in Finder.
        // Manual backups use the "backup" marker and are never auto-pruned.
        let path = (preferences.sparcDiskImagePath as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        let src = URL(fileURLWithPath: path)
        let dest = Self.backupDestination(for: src, marker: "backup")
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            showLaunchError("Backup failed: \(error.localizedDescription)")
        }
    }

    /// How many auto-backups to keep before pruning the oldest. Auto-backups
    /// are full logical images, so without a cap they'd accumulate one per
    /// clean shutdown forever. Manual backups are exempt from this.
    nonisolated private static let autoBackupKeepCount = 5

    /// Fired from `QemuEngine.onTerminated` after every run. Makes a "last
    /// known good" copy of the image, but only when the run ended via a
    /// verified clean halt (so we never snapshot a possibly-dirty image after
    /// a hard kill) and the user hasn't opted out. Runs off the main thread:
    /// same-volume APFS makes this an instant clonefile, but a cross-volume
    /// image would be a full copy we don't want to block the UI on.
    private func autoBackupAfterCleanShutdown(wasCleanHalt: Bool) {
        guard wasCleanHalt, preferences.sparcAutoBackupOnShutdown else { return }
        let path = (preferences.sparcDiskImagePath as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        let src = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .utility).async {
            Self.writeAutoBackup(of: src)
        }
    }

    /// Clone `src` to a dated "autobackup" sibling, then prune to the most
    /// recent `autoBackupKeepCount`. No UI: on the clean-shutdown path a modal
    /// would be intrusive, so failures are logged, not surfaced.
    nonisolated private static func writeAutoBackup(of src: URL) {
        let dest = backupDestination(for: src, marker: SparcBackup.autoMarker)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            NSLog("SPARCstation auto-backup failed: \(error.localizedDescription)")
            return
        }
        pruneAutoBackups(for: src, keep: autoBackupKeepCount)
    }

    /// Delete the oldest auto-backup siblings of `src` beyond `keep`. The
    /// selection (oldest-first, autobackup-marker-only) is `SparcBackup`'s job;
    /// this just gathers names + creation dates and does the deletes.
    nonisolated private static func pruneAutoBackups(for src: URL, keep: Int) {
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let entries = urls.map { url -> (name: String, created: Date) in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return (url.lastPathComponent, created)
        }
        let doomed = SparcBackup.autoBackupsToPrune(entries: entries, base: base, ext: ext, keep: keep)
        for name in doomed {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// A dated, collision-free backup path alongside `src`. Naming (marker,
    /// same-day suffixing) is `SparcBackup`'s job; this resolves the directory
    /// and the set of names already present.
    nonisolated private static func backupDestination(for src: URL, marker: String) -> URL {
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: Date())
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let name = SparcBackup.backupName(base: base, ext: ext, marker: marker,
                                          stamp: stamp, existing: existing)
        return dir.appendingPathComponent(name)
    }


    @MainActor
    @objc private func showSparcConsole(_ sender: Any?) {
        ensureSparcConsole()
        sparcConsole?.showWindow()
    }

    /// Pre-flight the image lock, then boot. The lock guards against opening
    /// the same qcow2 twice (corruption) — including across the two Macs that
    /// share the image via Dropbox. See ImageLock / PLUGIN_V1_PUNCHLIST L1.
    private func launchSparcStation() {
        let image = makeSparcConfig().diskImage
        switch ImageLockManager.evaluate(imageURL: image) {
        case .free:
            proceedSparcLaunch()
        case .staleSameHost:
            // Leftover lock from a crash on this Mac; the process is gone.
            ImageLockManager.forceRemove(imageURL: image)
            proceedSparcLaunch()
        case .localOrphan(let lock):
            presentLocalOrphanDialog(lock: lock, image: image)
        case .remoteLocked(let lock):
            presentRemoteLockedDialog(lock: lock, image: image)
        }
    }

    /// On launch, if a SPARCstation from a previous run is still alive on this
    /// Mac (the Xcode-stop / crash / SIGKILL orphan), offer to reconnect to it --
    /// the Design 2 flow (VM_CONTROL.md Stage 3). We probe the Helios daemon first
    /// so the prompt leads with a graceful **Shut It Down** when the guest is
    /// reachable, and only falls back to **Force Quit** when it isn't. **Reconnect**
    /// is offered either way (it just re-attaches the console + control channels;
    /// a still-booting guest comes to "Ready" on its own once Helios answers).
    private func checkForReconnectableOrphanOnLaunch() {
        guard let engine = controller?.engine, engine.state != .running else { return }
        let image = makeSparcConfig().diskImage
        guard case .localOrphan(let lock) = ImageLockManager.evaluate(imageURL: image) else { return }
        // Probe Helios off-main (it can block up to the timeout), then prompt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let heliosUp = Self.probeOrphanHelios(secret: lock.secret)
            DispatchQueue.main.async {
                self?.presentReconnectPrompt(lock: lock, image: image, heliosUp: heliosUp)
            }
        }
    }

    /// One-shot `hello` to a (possibly orphaned) guest's Helios daemon, using the
    /// secret the lock recorded. True means the guest OS is up and answering.
    nonisolated private static func probeOrphanHelios(secret: String?) -> Bool {
        let client = HeliosClient(timeout: 3, secret: secret)
        defer { client.close() }
        do {
            try client.connect()
            _ = try client.hello()
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func presentReconnectPrompt(lock: ImageLock, image: URL, heliosUp: Bool) {
        let since = lock.startedAt.isEmpty ? "" : " (started \(friendlyDate(lock.startedAt)))"
        let alert = NSAlert()
        alert.messageText = "Reconnect to the running SPARCstation?"
        if heliosUp {
            alert.informativeText =
                "A SPARCstation from a previous run (process \(lock.pid))\(since) is still running on "
                + "this Mac and answering. Reconnect to watch and control it, or shut it down cleanly."
            alert.addButton(withTitle: "Reconnect")       // first
            alert.addButton(withTitle: "Shut It Down")    // second
            alert.addButton(withTitle: "Ignore")          // third
            switch alert.runModal() {
            case .alertFirstButtonReturn:  reconnectToOrphan(lock: lock, image: image)
            case .alertSecondButtonReturn: attemptHeliosShutdown(lock: lock, image: image)
            default: break
            }
        } else {
            // Daemon isn't answering: graceful shutdown isn't available, so Force
            // Quit replaces it (per the graceful-first policy). Reconnect still
            // works -- the guest may just be mid-boot.
            alert.alertStyle = .warning
            alert.informativeText =
                "A SPARCstation from a previous run (process \(lock.pid))\(since) is still running on "
                + "this Mac but isn't answering yet. Reconnect to watch it (it may still be booting), "
                + "or force quit it (which risks a disk check on the next boot)."
            alert.addButton(withTitle: "Reconnect")       // first
            alert.addButton(withTitle: "Force Quit")      // second
            alert.addButton(withTitle: "Ignore")          // third
            switch alert.runModal() {
            case .alertFirstButtonReturn:  reconnectToOrphan(lock: lock, image: image)
            case .alertSecondButtonReturn: forceQuitOrphan(lock: lock, image: image)
            default: break
            }
        }
    }

    /// Adopt the orphan as this session's engine and surface its console. The
    /// existing engine callbacks (wired in `rebuildSparcEngine`) then drive the
    /// window exactly as a booted session would -- including clean-halt ->
    /// auto-backup. If the orphan died between detection and here, clear the
    /// stale lock instead.
    @MainActor
    private func reconnectToOrphan(lock: ImageLock, image: URL) {
        ensureSparcConsole()
        sparcConsole?.showWindow()
        if controller?.engine.attach(toOrphan: lock) == true {
            // Refresh the Claude-dev secret file from the adopted guest's secret
            // (the launch-time wipe cleared it; the engine now carries lock.secret).
            writeClaudeDevSecretFile()
        } else {
            ImageLockManager.forceRemove(imageURL: image)
        }
    }

    /// Actually boot the engine and bring up the console. Assumes the image is
    /// set and the lock is clear.
    private func proceedSparcLaunch() {
        ensureSparcConsole()
        sparcConsole?.showWindow()
        do {
            try controller?.engine.start()
            writeClaudeDevSecretFile()
        } catch {
            showLaunchError("Couldn't start SPARCstation: \(error.localizedDescription)")
        }
    }

    /// Path the "Claude development" secret is written to (per Todd's design).
    private static let claudeDevSecretPath = "/tmp/sparkplug"

    /// When "Claude development" is on, write the just-launched guest's Helios
    /// secret to a 0600 file so Claude Code can authenticate to the daemon.
    /// Otherwise make sure no stale secret lingers. Best-effort.
    private func writeClaudeDevSecretFile() {
        guard preferences.sparcClaudeDevelopment, let secret = controller?.engine.currentSecret else {
            clearClaudeDevSecretFile()
            return
        }
        // Create 0600 up front so the secret is never briefly world-readable.
        FileManager.default.createFile(
            atPath: Self.claudeDevSecretPath,
            contents: Data(secret.utf8),
            attributes: [.posixPermissions: 0o600])
    }

    /// Remove the dev-secret file. Called everywhere the secret could go stale:
    /// app launch (wipe a prior crash's leftover), guest exit, and app quit --
    /// EXCEPT a "Quit and Detach", where the guest keeps running and the secret is
    /// still live (see `detachingSparcOnQuit`). We can't catch a kill -9, but this
    /// guarantees a dead secret is never left readable on disk.
    private func clearClaudeDevSecretFile() {
        try? FileManager.default.removeItem(atPath: Self.claudeDevSecretPath)
    }

    // MARK: - Image-lock dialogs

    /// Different machine holds the lock: hard stop. We can't verify a remote
    /// pid, so the user must delete the lock if they know that Mac is idle.
    private func presentRemoteLockedDialog(lock: ImageLock, image: URL) {
        let lockPath = ImageLockManager.lockURL(for: image).path
        let alert = NSAlert()
        alert.messageText = "This disk image is in use by another Mac"
        let since = lock.startedAt.isEmpty ? "" : " since \(friendlyDate(lock.startedAt))"
        alert.informativeText =
            "“\(lock.host)” is using this SPARCstation disk image\(since). Running it on two "
            + "machines at once would corrupt the image.\n\nIf \(lock.host) isn’t actually "
            + "running it, delete the lock file to continue:\n\(lockPath)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reveal Lock in Finder")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(lockPath, inFileViewerRootedAtPath: "")
        }
    }

    /// Same machine, a previous qemu is still alive (the Xcode-stop / crash
    /// orphan). Offer best-effort graceful shutdown, force quit, or manual
    /// instructions.
    private func presentLocalOrphanDialog(lock: ImageLock, image: URL) {
        let alert = NSAlert()
        alert.messageText = "A SPARCstation is already running"
        alert.informativeText =
            "A SPARCstation from a previous run (process \(lock.pid)) is still running on this "
            + "Mac and holding the disk image. Starting another would corrupt it.\n\nTry to shut "
            + "it down cleanly, or force quit it (which risks a disk check on the next boot)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try to Shut It Down")   // first
        alert.addButton(withTitle: "Force Quit")            // second
        alert.addButton(withTitle: "Show Me How")           // third
        alert.addButton(withTitle: "Cancel")                // fourth
        switch alert.runModal() {
        case .alertFirstButtonReturn:  attemptHeliosShutdown(lock: lock, image: image)
        case .alertSecondButtonReturn: forceQuitOrphan(lock: lock, image: image)
        case .alertThirdButtonReturn:  showManualShutdownInstructions()
        default: break
        }
    }

    /// Stop the orphan, then clear the lock and boot. Prefers a qcow2-clean QMP
    /// `quit` through the socket path the lock records (VM_CONTROL.md Stage 3):
    /// qemu drains + closes the block layer, so the container can't be torn
    /// mid-write the way SIGKILL can. Falls back to a verified SIGKILL (still our
    /// qemu, so a recycled pid is never killed) when the lock has no QMP socket or
    /// the channel is wedged. The guest filesystem is dirty either way (no
    /// `init 5`), so it still fscks next boot -- the win is container integrity.
    /// The QMP attempt blocks, so it runs off-main.
    private func forceQuitOrphan(lock: ImageLock, image: URL) {
        let qmp = lock.qmpSocketPath ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cleanStopped = QemuEngine.quitOrphanViaQmp(qmpSocketPath: qmp)
            if !cleanStopped,
               ImageLockManager.isProcessAlive(lock.pid),
               ImageLockManager.processIsOurQemu(lock.pid) {
                kill(lock.pid, SIGKILL)
            }
            // Give it a beat to die, then clear the (now-stale) lock and launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ImageLockManager.forceRemove(imageURL: image)
                self?.proceedSparcLaunch()
            }
        }
    }

    /// Ask the orphan's Helios daemon to `init 5` over the 2125 hostfwd, then
    /// poll for the pid to die behind a live progress panel. This is the C4
    /// replacement for the old telnet path: the daemon runs as root and answers
    /// on the hostfwd even for an orphan (the forwarded port belongs to that
    /// still-running qemu), so it sidesteps the root-over-telnet refusal that
    /// made the old path unreliable on 2.6. Success is measured by the pid
    /// dying, not the call's ACK (the daemon ACKs before the guest goes down).
    /// On a fast daemon failure the poll loop flips the panel to Force Quit /
    /// Show Me How / Cancel. See PLUGIN_V1_PUNCHLIST L2.
    private func attemptHeliosShutdown(lock: ImageLock, image: URL) {
        orphanShutdownFailed = false
        // The orphan's daemon requires the secret it was launched with. The lock
        // records it (persisted at acquire time); fall back to this session's
        // current secret for the same-session case where the lock predates the
        // field. Without a matching secret an authed daemon rejects the call.
        let secret = lock.secret ?? controller?.engine.currentSecret
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let client = HeliosClient(timeout: 8, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.shutdown()
            } catch {
                DispatchQueue.main.async { self?.orphanShutdownFailed = true }
            }
        }

        let total = 35
        let progress = SparcShutdownProgressWindowController(
            totalSeconds: total,
            onForceQuit: { [weak self] in self?.forceQuitFromProgress(lock: lock, image: image) },
            onShowManual: { [weak self] in self?.showManualFromProgress() },
            onCancel: { [weak self] in self?.cancelShutdownWait() })
        sparcShutdownProgress = progress
        progress.showWindow()

        pollOrphanDeath(lock: lock, image: image, deadline: Date().addingTimeInterval(TimeInterval(total)))
    }

    private func pollOrphanDeath(lock: ImageLock, image: URL, deadline: Date) {
        // The user cancelled or escalated; the panel is gone, so stop polling.
        guard sparcShutdownProgress != nil else { return }

        if !ImageLockManager.isProcessAlive(lock.pid) {
            ImageLockManager.forceRemove(imageURL: image)
            sparcShutdownProgress?.markSucceeded()
            // Let the green "Powered off" state register, then dismiss + boot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.sparcShutdownProgress?.close()
                self?.sparcShutdownProgress = nil
                self?.proceedSparcLaunch()
            }
            return
        }
        // Daemon couldn't be reached -- no point waiting out the countdown.
        if orphanShutdownFailed || Date() >= deadline {
            // Leave the panel up; it flips to the actionable failure state.
            sparcShutdownProgress?.markFailed()
            return
        }
        sparcShutdownProgress?.updateRemaining(Int(deadline.timeIntervalSinceNow.rounded(.up)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pollOrphanDeath(lock: lock, image: image, deadline: deadline)
        }
    }

    /// Force Quit chosen from the progress panel: tear the panel down, then run
    /// the verified SIGKILL path. The Helios shutdown call is one-shot and needs
    /// no cancellation -- the poll loop stops once the panel is gone.
    private func forceQuitFromProgress(lock: ImageLock, image: URL) {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
        forceQuitOrphan(lock: lock, image: image)
    }

    /// Show Me How chosen from the progress panel: tear down and show the
    /// manual telnet steps.
    private func showManualFromProgress() {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
        showManualShutdownInstructions()
    }

    /// Cancel chosen from the progress panel: stop waiting and leave the orphan
    /// running. Clearing `sparcShutdownProgress` also halts the poll loop.
    private func cancelShutdownWait() {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
    }

    private func showManualShutdownInstructions() {
        let alert = NSAlert()
        alert.messageText = "Shut down the running SPARCstation by hand"
        alert.informativeText =
            "In Terminal, connect to the running guest and halt it. Solaris 2.6 "
            + "refuses a direct root telnet login, so log in as a normal user and "
            + "then su to root:\n\n"
            + "    telnet 127.0.0.1 \(QemuEngine.telnetHostPort)\n"
            + "    (log in as a user, then:)\n"
            + "    su -\n"
            + "    init 5\n\n"
            + "Once it powers off, start the SPARCstation again. If telnet won’t connect, use "
            + "Force Quit instead (it risks a disk check on the next boot)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// ISO-8601 lock timestamp → a short local date/time, or the raw string.
    private func friendlyDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// First-run / no-image flow: a friendly hero-panel window (not the
    /// Settings tab, not a system error alert) explaining the bundled emulator
    /// and offering to pick an existing image or download a starter image. If
    /// the user dismisses, nothing changes and they'll see it again next
    /// Start. Changing the location later is done in Preferences.
    private func presentInstallFlow() {
        if sparcWelcome == nil {
            sparcWelcome = SparcStationWelcomeWindowController(
                onChooseImage: { [weak self] in self?.chooseImageThenStart() },
                onDownload: { [weak self] in self?.downloadStarterImage() }
            )
        }
        sparcWelcome?.showWindow()
    }

    /// Pick an existing qcow2, store it as the image path, and boot.
    private func chooseImageThenStart() {
        let panel = NSOpenPanel()
        panel.title = "Choose Solaris Disk Image"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.sparcDiskImagePath = url.path
        rebuildSparcEngine()             // pick up the new path now, not on the async notification
        launchSparcStation()
    }

    /// Download flow: ask where to put the image, then fetch it. The fetch
    /// itself is Track C and not wired yet, so for now we collect the
    /// destination and explain. When Track C lands, this downloads, verifies,
    /// sets the path, and boots.
    private func downloadStarterImage() {
        let save = NSSavePanel()
        save.title = "Download Starter Image"
        save.prompt = "Choose Location"
        save.message = "Choose where to save the Solaris starter image."
        save.nameFieldStringValue = QemuEngine.diskImageFilename
        guard save.runModal() == .OK, let url = save.url else { return }
        let alert = NSAlert()
        alert.messageText = "Download isn't available yet"
        alert.informativeText = "The starter-image download is still being built. When it ships "
            + "it will fetch the image to:\n\n\(url.path)\n\nFor now, use \u{201C}Choose Image\u{2026}\u{201D} "
            + "to select a qcow2 you already have."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Enable the SPARCstation items by engine state. Start is available
    /// whenever not running (it triggers the install flow if no image yet);
    /// Most SPARCstation items are driven live by refreshSparcMenu() (auto-enable
    /// off), so they're intentionally absent here. These remaining items live in
    /// auto-enabled menus and still validate the normal way.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openDnsAdmin(_:)):         return (controller?.isReady ?? false)
        case #selector(openFileBrowser(_:)):
            // A helios filebrowser key targeting the BUNDLED guest gates on its
            // readiness (isReady). One pointed at a real Sun on the LAN does
            // not -- that daemon's availability is independent, so enable it and
            // let the browser window surface any connection error itself. A
            // mis-transported key also stays enabled so clicking shows the
            // config error.
            let key = item.representedObject as? String
            guard let entry = currentLauncherFile?.entries.first(where: { "\($0.group)/\($0.name)" == key }),
                  entry.transport == .helios else { return true }
            return isBundledGuestTarget(entry) ? (controller?.isReady ?? false) : true
        default: return true
        }
    }
}

extension Notification.Name {
    static let launchersFileDidChange = Notification.Name("SwiftXLaunchersFileDidChange")
}
