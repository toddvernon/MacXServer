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
    /// Helios file-browser windows, one per filebrowser launcher entry, keyed by
    /// "group/name" so reopening reuses the window (and its current folder).
    private var fileBrowserControllers: [String: FileBrowserWindowController] = [:]
    /// The Server menu's listener-status info row; kept in sync with `listenerStatus`.
    private var serverStatusMenuItem: NSMenuItem?
    /// The top-level Machines menu, rebuilt from the registry whenever machine
    /// state changes (rebuildMachinesMenu). Per-item enablement is computed at
    /// rebuild time, so the menu reflects current state each rebuild.
    private var machinesMenu: NSMenu?
    /// Whether the bundled machine's guest has answered `hello` this run lives
    /// on its `MachineController` now (`controller?.isReady`) -- it's per-machine
    /// state, not an app-global. Cleared the moment state leaves `.running` (so
    /// shutdown dims Admin immediately, and a fresh boot starts dimmed until the
    /// daemon actually answers).
    /// Shared model for the SPARCstation Config window (shared folder; the
    /// disk-image and Claude-development sections were removed in the P2 /
    /// /tmp/sparkplug-retirement work). Created lazily; binds to the one
    /// instance so windows stay consistent. Writes flow to Preferences.
    private var sparcConfigModel: SparcConfigModel?
    /// One reused window controller per Config section.
    private var sparcConfigWindows: [SparcConfigSection: SparcConfigWindowController] = [:]
    /// Open capture-viewer windows. The viewer supports multiple windows so
    /// several captures can be compared; each removes itself here on close.
    private var captureViewers: [CaptureViewerWindowController] = []
    private var activeLauncher: RemoteLauncher?
    private var progressController: LaunchProgressWindowController?

    /// The machine registry: the configured machines + their live controllers,
    /// and the MCP-visible discovery layer. Loaded at launch (migrating from the
    /// legacy launchers file on first run). P2: every emulated VM's lifecycle is
    /// wired; any number can run at once, each with its own controller.
    private var registry: MachineRegistry?
    /// Per-machine console windows, keyed by machine id, created lazily the
    /// first time a machine starts (or its console is asked for). Each window
    /// is fed only by its own machine's engine, so consoles never follow or
    /// steal (the P1 single-`sparcConsole` bug).
    private var consoles: [UUID: SparcPlugConsoleWindowController] = [:]
    /// Per-machine DNS-admin windows, keyed by machine id (the panel talks to
    /// one machine's Helios daemon).
    private var dnsAdminControllers: [UUID: DnsAdminWindowController] = [:]
    private var sparcWelcome: SparcStationWelcomeWindowController?
    /// The machine the welcome/install flow was opened for (Start pressed on an
    /// image-less VM); chooseImageThenStart attaches the picked image to it.
    private var installTargetID: UUID?
    /// The unified Machines window (the front door) + its observable model. Built
    /// at launch. `refreshMachines` mirrors the registry + live controller state
    /// into the model (both the `machines` list for the master/Settings and the
    /// per-machine `rows` for the Overview), the same source the Machines menu
    /// reads, so window and menu never disagree.
    private var machinesWindow: MachinesWindowController?
    private var machinesModel: MachinesModel?

    // MARK: Helios prober state (see "Helios prober" section)

    /// What the last probe learned about a machine's agent. `up` requires a
    /// completed hello; `unauthorized` means the agent ANSWERED but refused the
    /// secret (alive, misconfigured); `down` is connect-failed/timed-out.
    enum HeliosReachability { case unknown, up, unauthorized, down }
    struct HeliosProbeResult {
        var reach: HeliosReachability
        var hello: HelloResult?
        var sysinfo: SysInfoResult?
        /// When the probe completed (drives the clock-drift math: the guest's
        /// `sysinfo.time` is compared against the Mac clock AT PROBE TIME).
        var at: Date
    }
    /// Latest probe result per machine id. Main-thread only.
    private var probeResults: [UUID: HeliosProbeResult] = [:]
    /// Serial queue for the blocking socket work (HeliosClient is sync).
    private let probeQueue = DispatchQueue(label: "macxserver.helios.prober", qos: .utility)
    private var probeTimer: Timer?
    /// Coalesces probeAllSoon() bursts (mutations arrive in flurries).
    private var probePassScheduled = false
    /// Set when an orphan's Helios shutdown call fails fast (connection refused,
    /// timed out, or auth rejected), so the poll loop can flip the panel to its
    /// failure state without waiting out the full countdown. Reset at the start
    /// of each attempt.
    private var orphanShutdownFailed = false
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
        didSet {
            updateStatusMenu()
            serverStatusMenuItem?.title = listenerStatus
        }
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

    /// Installs the status-bar item and main menu, loads the machine registry,
    /// and scans for reconnectable orphan guests.
    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installMainMenu()
        loadMachineRegistry()
        setupMachinesWindow()
        checkForReconnectableOrphansOnLaunch()
        startHeliosProber()
    }

    /// Load the machine registry, migrating the legacy launchers file on first
    /// run. `bundledUser` is only consulted when migration has to seed a bundled
    /// machine with no launcher group to copy from (rare -- the seeded launchers
    /// file normally supplies a loopback group), so we derive it best-effort.
    private func loadMachineRegistry() {
        // The legacy launchers dotfile is only needed for the one-time
        // migration into machines.json. Seed it (write if absent) only on that
        // first run; once machines.json exists just read the dotfile if it
        // happens to be present, so a user who deletes it doesn't get it
        // silently recreated every launch (it's dead post-migration anyway).
        let machinesExist = FileManager.default.fileExists(atPath: MachinesFileLoader.defaultPath)
        let launchers: LauncherFile = machinesExist
            ? ((try? String(contentsOfFile: LauncherFileLoader.defaultPath, encoding: .utf8))
                .map { LauncherFile.parse($0) } ?? LauncherFile.parse(""))
            : LauncherFileLoader.loadOrSeed(seed: DefaultLaunchers.seedContent)
        let bundledUser = launchers.entries.first(where: { Self.isLoopbackHost($0.host) })?.user
            ?? launchers.entries.first?.user ?? ""
        self.registry = MachineRegistry.load(bundledImagePath: preferences.sparcDiskImagePath,
                                             bundledUser: bundledUser)
        // The launcher file is imported ONCE (MachinesFileLoader.loadOrMigrate, on
        // the first run when machines.json doesn't exist yet). After that the JSON
        // registry is authoritative and edited in-app via the Machine Editor -- we
        // deliberately no longer reconcile from the file on every launch, so in-app
        // edits aren't clobbered by a stale ~/.macxserver-launchers. See
        // MACHINE_MANAGER_REFACTOR.md / SHORTCUTS.md.
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "0.0.0.0", "::1"].contains(host.lowercased())
    }

    // MARK: - Machines list window

    /// Build the unified Machines window + model, wire every action (operate +
    /// edit) to the registry / lifecycle methods, and open it as the front door.
    /// In P1 only the bundled emulated VM has lifecycle controls; the operate
    /// closures ignore the machine id for those (they drive the one wired machine)
    /// and use it for launches.
    private func setupMachinesWindow() {
        let model = MachinesModel()
        wireMachines(model)
        self.machinesModel = model
        let controller = MachinesWindowController(model: model)
        self.machinesWindow = controller
        refreshMachines()
        controller.showWindow()
    }

    /// Wire the model's action closures. Operate actions drive the existing
    /// lifecycle/launch methods; edit actions (add/remove/clone/commit) mutate the
    /// registry and refresh every surface.
    private func wireMachines(_ model: MachinesModel) {
        // Operate (Overview page + master list) -- all per machine id now.
        model.onStart     = { [weak self] id in self?.startMachine(id) }
        model.onShutDown  = { [weak self] id in self?.shutDownMachine(id) }
        model.onForceQuit = { [weak self] id in self?.confirmForceQuit(id) }
        model.onBackup    = { [weak self] id in self?.backUpDiskImage(id) }
        model.onConsole   = { [weak self] id in self?.showConsoleWindow(id) }
        model.onLaunch    = { [weak self] id, name, verbose in
            self?.launchFromMachine(id, launcherName: name, verbose: verbose) }
        model.onSetHeliosSecret = { [weak self] id in self?.promptHeliosSecret(for: id) }
        model.onDnsAdmin  = { [weak self] id in self?.openDnsAdmin(machineID: id) }
        model.onFileTransfer = { [weak self] id in self?.openMachineFileTransfer(id) }
        // What a blank DISPLAY actually resolves to at launch time (this X
        // server's own address) -- the Settings field shows it as the
        // placeholder so "blank" reads as a value, not a mystery.
        model.defaultDisplay = { [weak self] in
            guard let self else { return ":0" }
            return "\(self.advertisedHost):\(self.displayNumber)"
        }

        // Edit (master toolbar + Settings tab).
        model.onAddNew = { [weak self] in
            guard let self, let registry = self.registry else { return nil }
            // Default to an external host: it's immediately usable with just a
            // host + user. Flipping the kind to emulated VM in the editor gets
            // the machine its sticky port block (registry.update assigns it).
            let m = Machine(name: "New Machine", kind: .externalHost,
                            host: "", user: "", transport: .helios)
            registry.add(m)
            self.afterMachineMutation()
            return m.id
        }
        model.onCommit = { [weak self] machine in
            guard let self, let registry = self.registry else { return }
            registry.update(machine)
            self.afterMachineMutation()
        }
        model.onRemove = { [weak self] id in
            guard let self, let registry = self.registry else { return }
            // Never remove a bundled fixture (one of the machines we ship) or a
            // machine with a live qemu process. The window also disables the button
            // in these cases; this is the belt-and-suspenders guard.
            if registry.machine(id)?.bundled == true || registry.runningMachineIDs.contains(id) { return }
            let name = registry.machine(id)?.name ?? "this machine"
            let alert = NSAlert()
            alert.messageText = "Remove \u{201c}\(name)\u{201d}?"
            alert.informativeText = "This removes the machine and its launchers from "
                + "macXserver. The disk image file, if any, is left on disk."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            registry.remove(id)
            // Drop the machine's per-machine windows with it -- a console or
            // DNS panel for a machine that no longer exists is a dangling
            // control surface. Its probe state goes too.
            self.probeResults.removeValue(forKey: id)
            self.consoles.removeValue(forKey: id)?.close()
            self.dnsAdminControllers.removeValue(forKey: id)?.close()
            // File-browser windows are keyed "<machine-id>/<launcher>" (one per
            // browsable launcher), so evict every key for this machine or its
            // windows linger holding the dead machine's host/port/user.
            let prefix = "\(id.uuidString)/"
            for key in self.fileBrowserControllers.keys where key.hasPrefix(prefix) {
                self.fileBrowserControllers.removeValue(forKey: key)?.close()
            }
            if self.machinesModel?.selection == id { self.machinesModel?.selection = nil }
            self.afterMachineMutation()
        }
        model.onClone = { [weak self] id in
            guard let self, let registry = self.registry,
                  let m = registry.machine(id) else { return nil }
            let clone = m.cloned()
            registry.add(clone)
            self.afterMachineMutation()
            return clone.id
        }
        model.onPickImage = {
            let panel = NSOpenPanel()
            panel.title = "Choose Disk Image"
            panel.prompt = "Choose"
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url.path
        }
        model.imageClaimant = { [weak self] path, excluding in
            self?.registry?.imageClaimant(imagePath: path, excluding: excluding)?.name
        }
        model.portsClaimant = { [weak self] ports, excluding in
            self?.registry?.portBlockClaimant(ports: ports, excluding: excluding)?.name
        }
    }

    /// Reopen (or focus) the Machines window -- from the status item / Machines menu.
    @MainActor
    @objc private func openMachinesWindow(_ sender: Any?) {
        machinesWindow?.showWindow()
    }

    /// Recompute the model from the registry + live controller state: the
    /// `machines` list (master + Settings) and the per-machine operate `rows`
    /// (Overview + master dot). Mirrors the Machines menu's gating exactly so the
    /// window and the menu agree.
    private func refreshMachines() {
        guard let registry, let model = machinesModel else { return }
        model.machines = registry.machines
        model.runningMachineIDs = registry.runningMachineIDs

        var rows: [UUID: MachineRow] = [:]
        for m in registry.machines {
            rows[m.id] = machineRow(for: m, registry: registry)
        }
        model.rows = rows
    }

    /// One machine's live operate-state. The controller is authoritative while
    /// its qemu is live; otherwise the state derives from the machine's own data
    /// (so a stopped machine whose config was just edited never shows a stale
    /// controller's view of the world).
    private func machineRow(for m: Machine, registry: MachineRegistry) -> MachineRow {
        let isEmulated = m.kind == .emulatedVM
        let ctrl = registry.controller(m.id)
        let live = ctrl.map { $0.engine.state == .running || $0.engine.state == .shuttingDown } ?? false
        let state: QemuEngine.State = live
            ? ctrl!.engine.state
            : (m.isInstalledEmulatedVM ? .stopped : .notInstalled)
        let ready = ctrl?.isReady ?? false

        // `progress` drives the Overview thermometer (same semantics as the
        // console's boot bar): grows through boot, pegs at 1.0 once ready,
        // recedes through shutdown, empty when stopped.
        let dot: MachineStatusDot
        let statusText: String
        var progress: Double? = nil
        if !isEmulated {
            // The helios prober refines an external box's dot; unknown =
            // never probed or not set up for helios.
            switch probeResults[m.id]?.reach ?? .unknown {
            case .unknown:      dot = .external;             statusText = "External"
            case .up:           dot = .externalUp;           statusText = "External \u{00b7} agent responding"
            case .unauthorized: dot = .externalUnauthorized; statusText = "External \u{00b7} agent refused the secret"
            case .down:         dot = .externalDown;         statusText = "External \u{00b7} not responding"
            }
        } else if !m.isInstalledEmulatedVM {
            dot = .notInstalled; statusText = "Not installed"
        } else if state == .running && ready {
            dot = .running; statusText = "Running"
            progress = 1.0
        } else if state == .running {
            dot = .booting; statusText = "Booting"
            progress = ctrl?.bootProgress
        } else if state == .shuttingDown {
            dot = .booting; statusText = "Shutting down"
            progress = ctrl?.bootProgress
        } else {
            dot = .stopped; statusText = "Stopped"
        }

        let subtitle = isEmulated
            ? (m.image.map { $0.lastPathComponent } ?? "no disk image")
            : "\(m.host) · external"

        let chips = m.launchers.map { l -> MachineLauncherChip in
            // Same gating as the Machines menu: an emulated guest must be up
            // and ready for ANY transport (telnet/ssh need the guest just as
            // much as helios -- a launch against a stopped VM only fails
            // slowly). External hosts stay enabled; we don't own their state.
            let enabled = !isEmulated || ready
            return MachineLauncherChip(id: l.name, name: l.name, enabled: enabled)
        }

        return MachineRow(
            id: m.id, name: m.name, isEmulated: isEmulated,
            subtitle: subtitle, statusText: statusText, dot: dot, progress: progress,
            systemLine: systemLine(for: m, ready: ready),
            showsLifecycle: isEmulated,
            canStart: (state == .stopped || state == .notInstalled),
            canShutDown: (state == .running && ready),
            canForceQuit: (state == .running || state == .shuttingDown),
            canBackup: (state == .stopped),
            canConsole: (consoles[m.id] != nil),
            // OS-sensitive admin verbs (the rule, Todd 2026-07-07): the box
            // must be answering over Helios AND we must know what OS it runs.
            // Emulated: ready covers reachability and boot implies a known
            // image OS. External: the prober's last hello + the user-set OS.
            canDnsAdmin: isEmulated
                ? (state == .running && ready)
                : (probeResults[m.id]?.reach == .up && m.os != nil),
            // Admin verbs gate on the box ANSWERING over Helios (the rule,
            // Todd 2026-07-07): emulated = ready (readiness IS the helios
            // liveness signal); external = the prober's last hello succeeded
            // (which, against the fail-closed agent, also proves the saved
            // secret is right). File Transfer is OS-agnostic so it doesn't
            // need the machine's OS, unlike canDnsAdmin.
            canFileTransfer: isEmulated
                ? (state == .running && ready)
                : probeResults[m.id]?.reach == .up,
            osIsDetected: !isEmulated && probeResults[m.id]?.sysinfo?.uname != nil,
            canSetHeliosSecret: !isEmulated,
            launchers: chips)
    }

    /// Open the machine's Admin Agents file browser (Overview → Admin Agents →
    /// File Transfer): a synthetic filebrowser launcher resolved against the
    /// machine, so host / helios port / user / secret all ride the exact same
    /// plumbing a `fileBrowser = true` launcher chip uses. Keyed per machine so
    /// repeated clicks focus the existing window.
    private func openMachineFileTransfer(_ machineID: UUID) {
        guard let machine = registry?.machine(machineID) else { return }
        var warnings: [String] = []
        guard let entry = machine.fileTransferEntry(warnings: &warnings) else { return }
        openFileBrowser(entry: entry, key: "\(machine.id.uuidString)/admin.file-transfer")
    }

    /// Launch (or open the file browser for) one of a machine's launchers, reusing
    /// the same paths the Launchers menu uses.
    private func launchFromMachine(_ machineID: UUID, launcherName: String,
                                   verbose: Bool = false) {
        guard let machine = registry?.machine(machineID),
              let ml = machine.launchers.first(where: { $0.name == launcherName }) else { return }
        var warnings: [String] = []
        guard let entry = machine.resolved(ml, warnings: &warnings) else { return }
        // Launchers are always commands now: legacy file-browser launchers are
        // dropped at decode (Admin Agents > File Transfer replaced them).
        launch(entry, os: machine.os, verbose: verbose)
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
        alert.informativeText = "The password this machine's Helios agent expects. "
            + "The app sends it whenever it talks to the agent: file transfer, DNS, "
            + "status. Leave blank to clear it. Kept in your macOS Keychain."
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
        // A changed secret changes reachability (unauthorized <-> up): a
        // stale dot here would look like the save didn't take.
        probeResults.removeValue(forKey: machineID)
        refreshMachines()
        probeAllSoon()
    }

    /// Refresh every machine surface after an add/edit/remove/clone: the window
    /// model (master list + Overview rows + Settings), the Machines menu, and the
    /// status dashboard. Config edits (name / OS / image) also reflect into any
    /// existing console window; the engine itself picks them up on the next start
    /// (a fresh controller is built per start).
    private func afterMachineMutation() {
        for m in registry?.machines ?? [] {
            consoles[m.id]?.setOSName(m.os?.displayName)
            consoles[m.id]?.setMachineName(m.name)
        }
        refreshMachines()
        if let m = machinesMenu { rebuildMachinesMenu(m) }
        updateStatusMenu()
        // Host/transport edits change what the prober should be watching.
        probeAllSoon()
    }

    // MARK: - Machines menu

    /// Rebuild the Machines menu from the registry: the list window, a submenu per
    /// machine, then add/edit. Per-item enablement is computed here, and the menu
    /// is rebuilt on every state change (refreshSparcMenu), so it stays current.
    @MainActor
    private func rebuildMachinesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let listItem = NSMenuItem(title: "Machines\u{2026}",
                                  action: #selector(openMachinesWindow(_:)), keyEquivalent: "")
        listItem.target = self
        menu.addItem(listItem)
        // Shared Folder is a global engine setting (one TFTP dir served to every
        // guest), so it lives at the menu's top level, not under a machine. It
        // moved here when the per-machine Config submenu retired (P2).
        let sharedFolder = NSMenuItem(title: "Shared Folder\u{2026}",
                                      action: #selector(openSparcConfig(_:)), keyEquivalent: "")
        sharedFolder.target = self
        sharedFolder.representedObject = SparcConfigSection.sharedFolder
        menu.addItem(sharedFolder)
        menu.addItem(.separator())

        for m in registry?.machines ?? [] {
            let header = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: m.name)
            sub.autoenablesItems = false
            buildMachineSubmenu(sub, machine: m)
            header.submenu = sub
            menu.addItem(header)
        }
    }

    /// Populate one machine's submenu: lifecycle verbs (every emulated VM, gated
    /// by its own state), or the Helios-secret item (external), then its launchers.
    @MainActor
    private func buildMachineSubmenu(_ sub: NSMenu, machine m: Machine) {
        let isEmulated = m.kind == .emulatedVM
        let ctrl = registry?.controller(m.id)
        let live = ctrl.map { $0.engine.state == .running || $0.engine.state == .shuttingDown } ?? false
        let state: QemuEngine.State = live
            ? ctrl!.engine.state
            : (m.isInstalledEmulatedVM ? .stopped : .notInstalled)
        let ready = ctrl?.isReady ?? false
        let idString = m.id.uuidString as NSString

        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = idString
            sub.addItem(item)
        }

        if isEmulated {
            // Same gating as the old SPARCstation submenu, per machine. Start
            // covers the not-installed case (it opens the install flow); Shut
            // Down needs the daemon up; Force Quit is the hard power-off.
            add("Start", #selector(startMachineMenu(_:)),
                enabled: state == .stopped || state == .notInstalled)
            add("Shut Down", #selector(shutDownMachineMenu(_:)),
                enabled: state == .running && ready)
            add("Force Quit\u{2026}", #selector(forceQuitMachineMenu(_:)),
                enabled: state == .running || state == .shuttingDown)
            sub.addItem(.separator())
            add("Show Console", #selector(showConsoleMenu(_:)), enabled: consoles[m.id] != nil)
            add("Back Up Disk Image\u{2026}", #selector(backUpDiskImageMenu(_:)), enabled: state == .stopped)

            // Admin (DNS) talks to the machine's daemon, so gate it on readiness.
            let adminItem = NSMenuItem(title: "Admin", action: nil, keyEquivalent: "")
            adminItem.isEnabled = ready
            let adminMenu = NSMenu(title: "Admin")
            adminMenu.autoenablesItems = false
            let dns = NSMenuItem(title: "DNS (/etc/resolv.conf)\u{2026}",
                                 action: #selector(openDnsAdmin(_:)), keyEquivalent: "")
            dns.target = self
            dns.isEnabled = ready
            dns.representedObject = idString
            adminMenu.addItem(dns)
            adminItem.submenu = adminMenu
            sub.addItem(adminItem)
        } else {
            add("Helios Secret\u{2026}", #selector(setHeliosSecretMenu(_:)), enabled: true)
        }

        if !m.launchers.isEmpty {
            sub.addItem(.separator())
            for l in m.launchers {
                let item = NSMenuItem(title: l.name,
                                      action: #selector(launchMachineLauncher(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(m.id.uuidString)/\(l.name)" as NSString
                // An emulated guest must be up and ready for ANY transport
                // (matches the Overview chips); external launchers stay enabled.
                item.isEnabled = !isEmulated || ready
                sub.addItem(item)
            }
        }
    }

    // MARK: - Machines menu actions (machine id in representedObject)

    /// The machine id a menu item carries. All the per-machine menu verbs route
    /// through this.
    private func machineID(from sender: Any?) -> UUID? {
        guard let idStr = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return UUID(uuidString: idStr)
    }

    @MainActor @objc private func startMachineMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { startMachine(id) }
    }

    @MainActor @objc private func shutDownMachineMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { shutDownMachine(id) }
    }

    @MainActor @objc private func forceQuitMachineMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { confirmForceQuit(id) }
    }

    @MainActor @objc private func showConsoleMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { showConsoleWindow(id) }
    }

    @MainActor @objc private func backUpDiskImageMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { backUpDiskImage(id) }
    }

    @MainActor
    @objc private func launchMachineLauncher(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let slash = key.firstIndex(of: "/"),
              let id = UUID(uuidString: String(key[..<slash])) else { return }
        launchFromMachine(id, launcherName: String(key[key.index(after: slash)...]))
    }

    @MainActor
    @objc private func setHeliosSecretMenu(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        promptHeliosSecret(for: id)
    }


    /// Resolve one machine's engine config: helper + firmware from the app
    /// bundle (or SPARCPLUG_ENGINE_DIR in dev), everything else -- image, memory,
    /// ports, MAC, OS profile -- from the machine itself. The shared folder
    /// (TFTP) is a global preference served to every guest. nil for an external
    /// host or an image-less VM.
    private func engineConfig(for machine: Machine) -> QemuEngineConfig? {
        // Create the shared dir if it's missing so slirp (read-only, won't
        // create it) has something to serve. Failure to create just means no
        // shared folder this run, not a failed launch.
        var tftpDir: String? = nil
        if preferences.sparcTftpEnabled {
            let dir = (preferences.sparcTftpDirectory as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            tftpDir = dir
        }
        return machine.makeEngineConfig(tftpDirectory: tftpDir)
    }

    /// Build a FRESH controller for one machine from its current config and wire
    /// its engine callbacks to that machine's console + the shared surfaces. A
    /// fresh controller per start (rather than one long-lived one) is what makes
    /// config edits -- image, memory, ports -- take effect on the next boot with
    /// no rebuild bookkeeping. Returns nil for a machine that can't run (no
    /// image / external host).
    @discardableResult
    private func buildController(for machine: Machine) -> MachineController? {
        guard let registry, let config = engineConfig(for: machine) else { return nil }
        let controller = MachineController(id: machine.id, config: config)
        wireEngine(controller.engine, machineID: machine.id)
        registry.setController(controller, for: machine.id)
        return controller
    }

    /// Route one engine's callbacks to its machine's console window (keyed
    /// lookup -- the window may not exist yet or may have been created later)
    /// and the shared surfaces (menus, list rows, status item). The closures
    /// fire on the main queue (QemuEngine dispatches them).
    private func wireEngine(_ engine: QemuEngine, machineID id: UUID) {
        engine.onConsoleData { [weak self] data in
            self?.consoles[id]?.feedConsoleData(data)
        }
        engine.onStateChange { [weak self] state in
            guard let self else { return }
            self.consoles[id]?.setState(state)
            // Keep the Shared Folder window's "restart to apply" note in sync:
            // the folder is read at engine launch, so it can't take effect
            // while ANY guest is up (they all serve the same dir).
            self.sparcConfigModel?.sparcEngineRunning =
                !(self.registry?.runningMachineIDs.isEmpty ?? true)
            // Anything other than steady .running (boot-in-progress counts as
            // .running too, but shutdown/stop don't) means the daemon isn't
            // answering -- drop readiness so Admin dims. onReady re-enables it.
            // Progress survives into .shuttingDown (the thermometer recedes
            // through it) and clears only when the run actually ends.
            if state != .running {
                self.registry?.controller(id)?.isReady = false
            }
            if state != .running && state != .shuttingDown {
                self.registry?.controller(id)?.bootProgress = nil
            }
            self.refreshSparcMenu()
        }
        engine.onCleanHalt { [weak self] in
            self?.consoles[id]?.markCleanHalt()
        }
        engine.onProgress { [weak self] value in
            self?.consoles[id]?.setProgress(value)
            self?.registry?.controller(id)?.bootProgress = value
            self?.refreshMachines()
        }
        engine.onReady { [weak self] in
            self?.consoles[id]?.markReady()
            // Daemon answered -- the guest is fully up. Unlock graceful Shut Down
            // and Admin now (not at process launch).
            self?.registry?.controller(id)?.isReady = true
            self?.refreshSparcMenu()
            // Fetch the fresh guest's sysinfo now instead of waiting out the
            // prober's next 3-minute tick.
            self?.probeAllSoon()
        }
        engine.onBootStalled { [weak self] reason in
            // Wedged guest -- make sure the user sees it and can Force Quit.
            self?.showConsoleWindow(id)
            self?.consoles[id]?.markBootStalled(reason)
        }
        engine.onShutdownUnavailable { [weak self] in
            // Graceful path couldn't reach the daemon -- surface Force Quit.
            self?.consoles[id]?.markShutdownUnavailable()
        }
        engine.onTerminated { [weak self] wasCleanHalt in
            self?.autoBackupAfterCleanShutdown(machineID: id, wasCleanHalt: wasCleanHalt)
        }
    }

    /// Returns false so the status-bar app keeps running with no X windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Status-bar app — keep running after the last X window closes so
        // we can accept a fresh client connection without relaunching.
        false
    }

    /// Quitting macXserver with machines still running is a real choice, not a
    /// footgun: detaching leaves the qemus running in the background (the serial
    /// consoles are on sockets, so there's no orphan CPU-spin), and macXserver
    /// will offer to reconnect to each next launch (VM_CONTROL.md Stage 3). The
    /// dialog offers **Quit and Detach** (leave them running) or **Go to Console**
    /// (shut them down cleanly first) plus Cancel. The only thing detaching skips
    /// is the clean guest halt; each VM keeps managing its own disk, so it's
    /// safe, but a clean shutdown is still tidier. Their per-boot secrets stay
    /// available in the image locks, so a detached guest remains reachable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let registry else { return .terminateNow }
        let running = registry.runningMachineIDs.compactMap { registry.machine($0) }
        guard !running.isEmpty else { return .terminateNow }

        let names = running.map(\.name).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = running.count == 1
            ? "\u{201C}\(names)\u{201D} is still running"
            : "\(running.count) machines are still running (\(names))"
        alert.informativeText = "You can quit and leave the guest(s) running in the background -- "
            + "macXserver will offer to reconnect the next time you launch -- or go to the console "
            + "to shut down cleanly first. Detaching is safe; each VM keeps managing its own disk."
        alert.addButton(withTitle: "Quit and Detach")   // first / default
        alert.addButton(withTitle: "Go to Console")      // second
        alert.addButton(withTitle: "Cancel")             // third
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Detach: let the app terminate. The qemus reparent to launchd and
            // keep running; each image lock persists (pid + secret + helios
            // port), so the next launch can reconnect and Claude-side tooling
            // can still reach the daemons.
            return .terminateNow
        case .alertSecondButtonReturn:
            for m in running { showConsoleWindow(m.id) }
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

        // Machine dashboard: a one-line summary + a dot per machine. Info rows
        // (click "Open Machine Manager" to act). Rebuilt on state change via
        // refreshSparcMenu, so "N running" stays current.
        if let snapshots = registry?.snapshot(), !snapshots.isEmpty {
            let running = snapshots.filter { $0.running == true }.count
            let header = NSMenuItem(title: "Machines: \(running) running", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for s in snapshots {
                let dot: String
                if s.kind == .externalHost { dot = "\u{25C7}" }        // ◇ external
                else if s.running == true && s.ready == true { dot = "\u{25CF}" }  // ● running+ready
                else if s.running == true { dot = "\u{25D0}" }         // ◐ booting
                else if !s.installed { dot = "\u{25CB}" }              // ○ not installed
                else { dot = "\u{25CB}" }                              // ○ stopped
                let row = NSMenuItem(title: "  \(dot)  \(s.name)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
            menu.addItem(.separator())
        }

        let openMgr = NSMenuItem(title: "Open Machine Manager\u{2026}",
                                 action: #selector(openMachinesWindow(_:)),
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

        // X11Server menu -- the X server as a quiet service: its live status and
        // the occasional control (Drop All Clients, moved here from the App menu).
        // The config (scale, clipboard, Motif frame) stays in Preferences.
        let serverMenuItem = NSMenuItem()
        let serverMenu = NSMenu(title: "X11Server")
        serverMenu.autoenablesItems = false
        let serverStatus = NSMenuItem(title: listenerStatus, action: nil, keyEquivalent: "")
        serverStatus.isEnabled = false
        serverMenu.addItem(serverStatus)
        self.serverStatusMenuItem = serverStatus
        serverMenu.addItem(.separator())
        // One-and-done: cancel every active client read source. Listener keeps
        // accepting new connections. Useful when a stuck client (orphan top-levels
        // from a WM-emulation bug, a wedged Sun ssh session) won't clean itself up.
        let drop = NSMenuItem(title: "Drop All Clients",
                              action: #selector(dropAllClients(_:)), keyEquivalent: "")
        drop.target = self
        serverMenu.addItem(drop)
        serverMenuItem.submenu = serverMenu
        main.addItem(serverMenuItem)

        // Machines menu -- rebuilt from the registry: the list window, a submenu
        // per machine (bundled VM lifecycle verbs, launchers for all, Helios
        // secret for external hosts), plus add/edit. Replaces the old fixed
        // SPARCstation menu and the flat Launchers menu.
        let machinesMenuItem = NSMenuItem()
        let mMenu = NSMenu(title: "Machines")
        self.machinesMenu = mMenu
        rebuildMachinesMenu(mMenu)
        machinesMenuItem.submenu = mMenu
        main.addItem(machinesMenuItem)

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
    /// note is correct the instant it opens. Any running guest counts: they all
    /// serve the same shared dir, read at their own launch.
    @MainActor
    private func ensureSparcConfigModel() -> SparcConfigModel {
        if let model = sparcConfigModel { return model }
        let running = !(registry?.runningMachineIDs.isEmpty ?? true)
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
        guard let id = machineID(from: sender) else { return }
        openDnsAdmin(machineID: id)
    }

    @MainActor
    private func openDnsAdmin(machineID id: UUID) {
        guard let m = registry?.machine(id) else { return }
        if dnsAdminControllers[id] == nil {
            // All three providers re-read the registry live, so the window
            // keeps working across a guest stop/start (per-boot secret) and
            // across host/user edits on an external machine. `heliosSecret`
            // resolves both kinds: loopback -> the owning engine's per-boot
            // secret (by port), external -> the Keychain secret.
            let hostFor: () -> String = { [weak self] in
                guard let m = self?.registry?.machine(id) else { return "127.0.0.1" }
                return m.kind == .emulatedVM ? "127.0.0.1" : m.host
            }
            dnsAdminControllers[id] = DnsAdminWindowController(
                machineName: m.name,
                secretProvider: { [weak self] in
                    guard let self, let m = self.registry?.machine(id) else { return nil }
                    return self.heliosSecret(host: hostFor(), user: m.user,
                                             port: m.resolvedPorts.helios)
                },
                hostProvider: hostFor,
                portProvider: { [weak self] in
                    self?.registry?.machine(id)?.resolvedPorts.helios ?? 2125
                })
        }
        dnsAdminControllers[id]?.showWindow()
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

    /// Keychain account under which an external machine's Helios daemon secret is
    /// stored. Keyed by user@host so it survives a machine rename / re-migration
    /// and is shared by every launcher + file-browser call to that box.
    private func heliosSecretAccount(host: String, user: String) -> String {
        "helios:\(user)@\(host)"
    }

    /// The Helios `auth` secret to present to a box's daemon. An emulated guest
    /// uses its per-boot `-prom-env` secret from its engine -- with several
    /// loopback guests up at once, the helios PORT is what identifies which
    /// machine (and so which secret) a call targets. An external host uses the
    /// secret the user saved in the Keychain (nil = none saved -- an open
    /// daemon still works, a secured one rejects until the user sets it).
    /// Supplying a secret to an open daemon is harmless, so this is safe
    /// against both.
    private func heliosSecret(host: String, user: String, port: UInt16) -> String? {
        let h = host.lowercased()
        if Self.isLoopbackHost(h) {
            guard let registry else { return nil }
            let owner = registry.machines.first {
                $0.kind == .emulatedVM && $0.resolvedPorts.helios == port
            }
            return owner.flatMap { registry.controller($0.id)?.engine.currentSecret }
        }
        return KeychainHelper.retrieve(account: heliosSecretAccount(host: host, user: user))
    }

    // MARK: - Helios prober (external reachability + guest sysinfo)
    //
    // "Has helios" gating is configuration; the prober is DISPLAY. Every ~3
    // minutes (plus immediately at launch, after any machine mutation, after a
    // secret change, and when a guest comes ready) it hellos each candidate
    // box off the main thread and refines the external dot (up / unauthorized
    // / down) plus the Overview's sysinfo line. Verbs never gate on probe
    // results -- a probe is at worst minutes stale, and failing at use with a
    // clear error beats a mysteriously dimmed button.

    /// One probe job, snapshotted on the main thread so the worker never
    /// touches the registry or the Keychain.
    private struct HeliosProbeJob {
        let id: UUID
        let host: String
        let port: UInt16
        let secret: String?
        let isEmulated: Bool
    }

    /// Start the recurring prober: an immediate pass, then every 3 minutes.
    /// Cheap when nothing qualifies -- no sockets are opened for machines that
    /// aren't helios-configured externals or ready emulated guests.
    private func startHeliosProber() {
        probeTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.probeAllSoon() }
        }
        probeTimer?.tolerance = 15
        probeAllSoon()
    }

    /// Schedule one coalesced probe pass on the next runloop turn (mutations
    /// arrive in flurries; one pass covers them all).
    private func probeAllSoon() {
        guard !probePassScheduled else { return }
        probePassScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.probePassScheduled = false
            self.runProbePass()
        }
    }

    private func probeJobs() -> [HeliosProbeJob] {
        guard let registry else { return [] }
        var jobs: [HeliosProbeJob] = []
        for m in registry.machines {
            if m.kind == .externalHost {
                guard !m.host.isEmpty else { continue }
                // Only boxes set up for helios. A transport-helios box with no
                // saved secret still gets probed: the fail-closed agent's
                // "unauthorized" answer is exactly the actionable signal.
                let secret = KeychainHelper.retrieve(
                    account: heliosSecretAccount(host: m.host, user: m.user))
                guard m.transport == .helios || secret != nil else { continue }
                jobs.append(HeliosProbeJob(id: m.id, host: m.host,
                                           port: m.resolvedPorts.helios,
                                           secret: secret, isEmulated: false))
            } else if registry.controller(m.id)?.isReady == true {
                // Ready emulated guest: refresh its sysinfo. Readiness already
                // proves liveness; the reach result never drives its dot.
                jobs.append(HeliosProbeJob(id: m.id, host: "127.0.0.1",
                                           port: m.resolvedPorts.helios,
                                           secret: registry.controller(m.id)?.engine.currentSecret,
                                           isEmulated: true))
            }
        }
        return jobs
    }

    private func runProbePass() {
        let jobs = probeJobs()
        guard !jobs.isEmpty else { return }
        probeQueue.async { [weak self] in
            var results: [(UUID, HeliosProbeResult)] = []
            for job in jobs {
                results.append((job.id, Self.probe(job)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, result) in results { self.probeResults[id] = result }
                self.adoptDetectedOSes(results)
                self.refreshMachines()
            }
        }
    }

    /// Blocking single-machine probe (runs on probeQueue): hello for
    /// liveness, then sysinfo best-effort. A protocolError on hello means the
    /// agent ANSWERED (it's alive) -- "unauthorized" is the config signal. An
    /// old agent's "unknown verb" on sysinfo just means no stats (pre-0.2.0).
    nonisolated private static func probe(_ job: HeliosProbeJob) -> HeliosProbeResult {
        let client = HeliosClient(host: job.host, port: job.port,
                                  timeout: 3, secret: job.secret)
        defer { client.close() }
        do {
            try client.connect()
            let hello = try client.hello()
            let sys = try? client.sysinfo()
            return HeliosProbeResult(reach: .up, hello: hello, sysinfo: sys, at: Date())
        } catch HeliosClient.HeliosError.protocolError(let message) {
            let reach: HeliosReachability =
                message.contains("unauthorized") ? .unauthorized : .up
            return HeliosProbeResult(reach: reach, hello: nil, sysinfo: nil, at: Date())
        } catch {
            return HeliosProbeResult(reach: .down, hello: nil, sysinfo: nil, at: Date())
        }
    }

    /// An external box that reports its own uname over sysinfo IS the source
    /// of truth for its OS (same doctrine as image detection on emulated
    /// VMs): adopt it into the registry, which auto-populates -- and, via
    /// `osIsDetected`, dims -- the Settings OS picker. A machine whose agent
    /// predates sysinfo keeps its manually-set OS untouched.
    private func adoptDetectedOSes(_ results: [(UUID, HeliosProbeResult)]) {
        guard let registry else { return }
        for (id, result) in results {
            guard let uname = result.sysinfo?.uname,
                  let detected = MachineOS.detect(unameSysname: uname.sysname,
                                                  release: uname.release),
                  var m = registry.machine(id),
                  m.kind == .externalHost, m.os != detected else { continue }
            m.os = detected
            registry.update(m)
            afterMachineMutation()
        }
    }

    /// The Overview's one-line guest summary from the machine's last sysinfo.
    /// Renders only what the agent reported (the fields-optional contract);
    /// suppressed entirely once the box stops answering -- stale facts read
    /// as current ones.
    private func systemLine(for m: Machine, ready: Bool) -> String? {
        guard let probe = probeResults[m.id], let sys = probe.sysinfo else { return nil }
        if m.kind == .emulatedVM && !ready { return nil }
        if m.kind == .externalHost && probe.reach != .up { return nil }
        var parts: [String] = []
        if let u = sys.uname { parts.append("\(u.sysname) \(u.release) \(u.machine)") }
        if let mem = sys.memMB { parts.append("\(Int(mem.rounded()))MB") }
        if let load = sys.load, !load.isEmpty { parts.append(String(format: "load %.2f", load[0])) }
        if let swap = sys.swap, swap.totalKB > 0 {
            parts.append("swap \(Int((swap.usedKB / swap.totalKB * 100).rounded()))%")
        }
        if let disks = sys.disks, let fullest = disks.max(by: { $0.usedPct < $1.usedPct }) {
            parts.append("\(fullest.mount) \(Int(fullest.usedPct))% full")
        }
        // mk48t08 clocks drift, and a qemu guest boots on whatever the RTC
        // hands it. Compare the guest clock against the Mac clock AT PROBE
        // TIME; two minutes of slack ignores probe latency and rounding.
        let drift = sys.time - probe.at.timeIntervalSince1970
        if abs(drift) > 120 {
            let minutes = Int((abs(drift) / 60).rounded())
            parts.append("clock \(drift > 0 ? "+" : "\u{2212}")\(minutes)m")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
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
            // Emulated guest → its per-boot engine secret (found by helios port);
            // external → the Keychain secret for that box (see heliosSecret).
            // Resolved live each call.
            let host = entry.host, user = entry.user, port = entry.port
            let config = HeliosFileBrowserConfig(
                host: entry.host, port: entry.port, user: entry.user,
                label: "\(entry.group): \(entry.user)",
                secretProvider: { [weak self] in
                    self?.heliosSecret(host: host, user: user, port: port) })
            fileBrowserControllers[key] = FileBrowserWindowController(config: config)
        }
        fileBrowserControllers[key]?.showWindow()
    }

    /// Launch one resolved entry (from a machine row / the Machines menu). Picks
    /// the auth path by transport: ssh/helios need none; telnet uses the machine's
    /// password, else the Keychain (prompting on first use). `os` is the owning
    /// machine's guest OS (drives the helios launcher's X bin dirs).
    @MainActor
    private func launch(_ entry: LauncherEntry, os: MachineOS?, verbose: Bool = false) {
        // ssh (keys-only) and helios (daemon, no auth) need no password: skip
        // the prompt and Keychain entirely. Any password field is ignored.
        if entry.transport == .ssh || entry.transport == .helios {
            executeLaunch(entry: entry, os: os, password: "", verbose: verbose)
            return
        }
        // Telnet path: the machine's password wins (dev convenience — skips
        // the prompt every launch). Otherwise fall back to the Keychain,
        // prompting and storing on first use.
        if let pw = entry.password, !pw.isEmpty {
            executeLaunch(entry: entry, os: os, password: pw, verbose: verbose)
            return
        }
        let account = "\(entry.user)@\(entry.host)"
        if let password = KeychainHelper.retrieve(account: account) {
            executeLaunch(entry: entry, os: os, password: password, verbose: verbose)
        } else {
            promptForPassword(entry: entry, os: os, account: account, verbose: verbose)
        }
    }

    private func promptForPassword(entry: LauncherEntry, os: MachineOS?, account: String,
                                   verbose: Bool) {
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
        executeLaunch(entry: entry, os: os, password: password, verbose: verbose)
    }

    private func executeLaunch(entry: LauncherEntry, os: MachineOS?, password: String,
                               verbose: Bool) {
        let display = entry.display ?? "\(advertisedHost):\(displayNumber)"
        let launcher: RemoteLauncher
        switch entry.transport {
        case .telnet:
            launcher = TelnetLauncher(entry: entry, password: password, displayString: display)
        case .ssh:
            launcher = SSHLauncher(entry: entry, displayString: display,
                                   xBinDirs: (os ?? .solaris26).xBinDirs)
        case .helios:
            // Same loopback-only rule as the file browser: an emulated guest's
            // per-launch secret goes only to its loopback hostfwd, not a real
            // Sun. The X bin dirs come from the owning machine's OS profile.
            launcher = HeliosLauncher(entry: entry, displayString: display,
                                      secret: heliosSecret(host: entry.host, user: entry.user,
                                                           port: entry.port),
                                      xBinDirs: (os ?? .solaris26).xBinDirs)
        }
        activeLauncher = launcher

        // The session transcript is ALWAYS captured (bounded), verbose or
        // not: a failed launch without it is undiagnosable ("timed out
        // waiting for shell prompt" -- waiting for WHAT, against WHAT
        // output?). Verbose (a launch-time gesture: right-click > Run with
        // Progress Window) additionally streams it to a progress window.
        let transcript = LaunchTranscript()
        var ctrl: LaunchProgressWindowController? = nil
        if verbose {
            let detail = "\(entry.transport.rawValue) \u{2022} "
                + "\(entry.user)@\(entry.host):\(entry.port) \u{2022} DISPLAY \(display)"
            ctrl = LaunchProgressWindowController(title: entry.name, detail: detail)
            progressController = ctrl
            ctrl?.showWindow()
        }
        launcher.onStatus { [weak ctrl] message in
            transcript.append("\u{2022} \(message)\n")
            ctrl?.appendStatusLine(message)
        }
        launcher.onText { [weak ctrl] text, bold in
            transcript.append(text)
            if bold { ctrl?.appendBoldText(text) }
            else { ctrl?.appendText(text) }
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
                    self?.showLaunchError("Launch failed for \(entry.name): \(error.localizedDescription)",
                                          transcript: transcript.tail())
                }
            }
        }
    }

    private func showLaunchError(_ message: String, transcript: String = "") {
        let alert = NSAlert()
        alert.messageText = "Launcher Error"
        alert.informativeText = transcript.isEmpty
            ? message
            : message + "\n\nSession transcript (what the machine sent):\n\(transcript)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Bounded rolling capture of one launch session, so a failure dialog can
    /// show what the machine actually sent. Callbacks arrive on the main
    /// queue (the launchers dispatch there), so no locking.
    private final class LaunchTranscript {
        private var text = ""
        func append(_ s: String) {
            text += s
            if text.count > 4000 { text = String(text.suffix(4000)) }
        }
        /// The last few lines, tidied for an alert.
        func tail(maxLines: Int = 14) -> String {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    // MARK: - Machine lifecycle (per machine id)

    /// The machine's console window, created on first use and reused for the
    /// machine's lifetime (it survives stop/start so the transcript persists).
    /// Every closure resolves the CURRENT controller through the registry at
    /// fire time, so a fresh controller per start needs no console re-wiring.
    @discardableResult
    private func console(for machine: Machine) -> SparcPlugConsoleWindowController {
        if let existing = consoles[machine.id] { return existing }
        let id = machine.id
        let console = SparcPlugConsoleWindowController(
            machineName: machine.name,
            onShutDown: { [weak self] in self?.registry?.controller(id)?.engine.shutDown() },
            onForceQuit: { [weak self] in self?.confirmForceQuit(id) },
            onInput: { [weak self] data in
                self?.registry?.controller(id)?.engine.sendConsole(data)
            },
            onLaunchXterm: { [weak self] in
                self?.registry?.controller(id)?.engine.launchXterm { result in
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
        console.setState(registry?.controller(id)?.engine.state ?? .stopped)
        console.setOSName(machine.os?.displayName)
        consoles[id] = console
        refreshSparcMenu()   // "Show Console" can undim now
        return console
    }

    /// Open (or focus) one machine's console window.
    private func showConsoleWindow(_ id: UUID) {
        guard let machine = registry?.machine(id) else { return }
        console(for: machine).showWindow()
    }

    /// Refresh every surface that reflects machine state: the Machines menu
    /// (rebuilt from the registry with fresh per-item enablement), the list
    /// window, and the status-item dashboard. Called from the engine callbacks
    /// (onStateChange, onReady) and when the console is created. Named for its
    /// history; it now drives all three surfaces, not just the old submenu.
    @MainActor
    private func refreshSparcMenu() {
        if let m = machinesMenu { rebuildMachinesMenu(m) }
        refreshMachines()
        updateStatusMenu()
    }

    /// Start one machine: route an image-less VM to the install flow, guard the
    /// (hand-edit-only) port conflict, then run the image-lock preflight and
    /// boot. Every path is per machine.
    @MainActor
    private func startMachine(_ id: UUID) {
        guard let registry, let machine = registry.machine(id),
              machine.kind == .emulatedVM else { return }
        let state = registry.controller(id)?.engine.state
        if state == .running || state == .shuttingDown { return }
        guard machine.image != nil else {
            presentInstallFlow(for: machine)     // no image yet -> install flow
            return
        }
        if let other = registry.portConflict(for: machine) {
            let alert = NSAlert()
            alert.messageText = "Port conflict with \u{201C}\(other.name)\u{201D}"
            alert.informativeText = "\u{201C}\(machine.name)\u{201D} and the running "
                + "\u{201C}\(other.name)\u{201D} share host ports (machines.json was probably "
                + "hand-edited). Give one of them its own ports in Settings, or stop "
                + "\u{201C}\(other.name)\u{201D} first."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        launchMachine(machine)
    }

    private func shutDownMachine(_ id: UUID) {
        // No console auto-pop (Todd's call 2026-07-06): the Overview row's
        // thermometer shows the shutdown receding; Console is a click away.
        registry?.controller(id)?.engine.shutDown()
    }

    @MainActor
    private func confirmForceQuit(_ id: UUID) {
        guard let machine = registry?.machine(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Force quit \u{201C}\(machine.name)\u{201D}?"
        alert.informativeText = "This pulls the power without a clean shutdown, like yanking the "
            + "cord. The guest will run a disk check on the next boot.\n\nIf it's wedged mid-boot, "
            + "try the console first -- it's a real terminal, so you can often recover by hand at "
            + "the ok prompt or in single-user. Force Quit only if you can't."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Show Console")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            registry?.controller(id)?.engine.kill()
        case .alertSecondButtonReturn:
            showConsoleWindow(id)
        default:
            break
        }
    }

    @MainActor
    private func backUpDiskImage(_ id: UUID) {
        // Only valid when stopped (the row/menu gating enforces it). Copy the
        // machine's qcow2 alongside itself with a dated name and reveal it in
        // Finder. Manual backups use the "backup" marker and are never
        // auto-pruned.
        guard let src = registry?.machine(id)?.image else { return }
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
    /// known good" copy of the machine's image, but only when the run ended via
    /// a verified clean halt (so we never snapshot a possibly-dirty image after
    /// a hard kill) and the machine's auto-backup setting is on (per-machine
    /// since P2 -- was the global `sparcplug.autoBackupOnShutdown`). Runs off
    /// the main thread: same-volume APFS makes this an instant clonefile, but a
    /// cross-volume image would be a full copy we don't want to block the UI on.
    private func autoBackupAfterCleanShutdown(machineID: UUID, wasCleanHalt: Bool) {
        guard wasCleanHalt, let machine = registry?.machine(machineID),
              machine.autoBackup, let src = machine.image else { return }
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


    /// Pre-flight the machine's image lock, then boot. The lock guards against
    /// opening the same qcow2 twice (corruption) — including across the two Macs
    /// that share an image via Dropbox. See ImageLock / PLUGIN_V1_PUNCHLIST L1.
    private func launchMachine(_ machine: Machine) {
        guard let image = machine.image else { return }
        switch ImageLockManager.evaluate(imageURL: image) {
        case .free:
            proceedLaunch(machine)
        case .staleSameHost:
            // Leftover lock from a crash on this Mac; the process is gone.
            ImageLockManager.forceRemove(imageURL: image)
            proceedLaunch(machine)
        case .localOrphan(let lock):
            presentLocalOrphanDialog(machine: machine, lock: lock, image: image)
        case .remoteLocked(let lock):
            presentRemoteLockedDialog(lock: lock, image: image)
        }
    }

    /// On launch, scan EVERY emulated machine's image for a still-alive qemu
    /// from a previous run (the Quit-and-Detach / Xcode-stop / crash orphan)
    /// and offer to reconnect -- the Design 2 flow (VM_CONTROL.md Stage 3).
    /// ONE dialog covers all of them (mirroring the quit dialog), and
    /// reconnecting never pops consoles -- the rows go live in the Machines
    /// window and the consoles reattach in the background (Todd's call
    /// 2026-07-06). A guest that isn't answering yet just sits in "Booting"
    /// until Helios answers or the readiness budget stalls it; stopping is a
    /// normal per-machine Shut Down / Force Quit once reconnected.
    private func checkForReconnectableOrphansOnLaunch() {
        guard let registry else { return }
        var orphans: [(machine: Machine, lock: ImageLock, image: URL)] = []
        for machine in registry.machines where machine.kind == .emulatedVM {
            guard let image = machine.image,
                  case .localOrphan(let lock) = ImageLockManager.evaluate(imageURL: image)
            else { continue }
            orphans.append((machine, lock, image))
        }
        guard !orphans.isEmpty else { return }
        presentReconnectPrompt(orphans)
    }

    @MainActor
    private func presentReconnectPrompt(_ orphans: [(machine: Machine, lock: ImageLock, image: URL)]) {
        let described = orphans.map { o in
            let since = o.lock.startedAt.isEmpty ? "" : " (started \(friendlyDate(o.lock.startedAt)))"
            return "\u{201C}\(o.machine.name)\u{201D}\(since)"
        }.joined(separator: ", ")
        let one = orphans.count == 1
        let alert = NSAlert()
        alert.messageText = one
            ? "\u{201C}\(orphans[0].machine.name)\u{201D} is still running from a previous session"
            : "\(orphans.count) machines are still running from a previous session"
        alert.informativeText = "Still running on this Mac: \(described). Reconnect to manage "
            + "\(one ? "it" : "them") -- the machines come live in the Machines window and each "
            + "console reattaches quietly -- or ignore and leave \(one ? "it" : "them") running."
        alert.addButton(withTitle: "Reconnect")   // first / default
        alert.addButton(withTitle: "Ignore")      // second
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for o in orphans {
            reconnectToOrphan(machine: o.machine, lock: o.lock, image: o.image)
        }
    }

    /// Adopt the orphan as this machine's engine. The engine callbacks (wired
    /// in `buildController`) then drive everything exactly as a booted session
    /// would -- including clean-halt -> auto-backup. The console is created but
    /// NOT shown (no auto-pop); since the serial socket replays no history, a
    /// reconnection banner with what the lock knows is injected so an opened
    /// console isn't a black void. If the orphan died between detection and
    /// here, clear the stale lock instead.
    @MainActor
    private func reconnectToOrphan(machine: Machine, lock: ImageLock, image: URL) {
        let win = console(for: machine)
        guard let controller = buildController(for: machine),
              controller.engine.attach(toOrphan: lock) else {
            ImageLockManager.forceRemove(imageURL: image)
            return
        }
        var lines = ["", "** reconnected to console **"]
        if !lock.startedAt.isEmpty {
            lines.append("   instance started \(friendlyDate(lock.startedAt))")
        }
        var facts = ["qemu pid \(lock.pid)"]
        if let port = lock.heliosPort { facts.append("helios port \(port)") }
        facts.append(image.lastPathComponent)
        lines.append("   " + facts.joined(separator: " \u{00B7} "))
        lines.append("")
        win.feedConsoleData(Data(lines.joined(separator: "\r\n").utf8))
    }

    /// Actually boot the machine's engine. Assumes the image is set and the
    /// lock is clear. A FRESH controller is built per start so the machine's
    /// current config (image / memory / ports / MAC) applies. The console
    /// window is CREATED (so it records the transcript from byte one and the
    /// Console buttons enable) but not shown -- no auto-pop on start/stop
    /// (Todd's call 2026-07-06); the Overview thermometer carries the boot.
    private func proceedLaunch(_ machine: Machine) {
        _ = console(for: machine)
        guard let controller = buildController(for: machine) else { return }
        do {
            try controller.engine.start()
        } catch {
            showLaunchError("Couldn't start \u{201C}\(machine.name)\u{201D}: \(error.localizedDescription)")
        }
        refreshSparcMenu()
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
    private func presentLocalOrphanDialog(machine: Machine, lock: ImageLock, image: URL) {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(machine.name)\u{201D} is already running"
        alert.informativeText =
            "A guest from a previous run (process \(lock.pid)) is still running on this "
            + "Mac and holding the disk image. Starting another would corrupt it.\n\nTry to shut "
            + "it down cleanly, or force quit it (which risks a disk check on the next boot)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try to Shut It Down")   // first
        alert.addButton(withTitle: "Force Quit")            // second
        alert.addButton(withTitle: "Show Me How")           // third
        alert.addButton(withTitle: "Cancel")                // fourth
        switch alert.runModal() {
        case .alertFirstButtonReturn:  attemptHeliosShutdown(machine: machine, lock: lock, image: image)
        case .alertSecondButtonReturn: forceQuitOrphan(machine: machine, lock: lock, image: image)
        case .alertThirdButtonReturn:  showManualShutdownInstructions(telnetPort: machine.resolvedPorts.telnet, os: machine.os)
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
    private func forceQuitOrphan(machine: Machine, lock: ImageLock, image: URL) {
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
                self?.proceedLaunch(machine)
            }
        }
    }

    /// Ask the orphan's Helios daemon to halt over its recorded hostfwd port,
    /// then poll for the pid to die behind a live progress panel. This is the C4
    /// replacement for the old telnet path: the daemon runs as root and answers
    /// on the hostfwd even for an orphan (the forwarded port belongs to that
    /// still-running qemu), so it sidesteps the root-over-telnet refusal that
    /// made the old path unreliable on 2.6. Success is measured by the pid
    /// dying, not the call's ACK (the daemon ACKs before the guest goes down).
    /// On a fast daemon failure the poll loop flips the panel to Force Quit /
    /// Show Me How / Cancel. See PLUGIN_V1_PUNCHLIST L2.
    private func attemptHeliosShutdown(machine: Machine, lock: ImageLock, image: URL) {
        orphanShutdownFailed = false
        // The orphan's daemon requires the secret it was launched with; the lock
        // records it (persisted at acquire time) along with the helios port.
        // Without a matching secret an authed daemon rejects the call.
        let secret = lock.secret
        let port = lock.heliosPort ?? machine.resolvedPorts.helios
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let client = HeliosClient(port: port, timeout: 8, secret: secret)
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
            onForceQuit: { [weak self] in self?.forceQuitFromProgress(machine: machine, lock: lock, image: image) },
            onShowManual: { [weak self] in self?.showManualFromProgress(telnetPort: machine.resolvedPorts.telnet, os: machine.os) },
            onCancel: { [weak self] in self?.cancelShutdownWait() })
        sparcShutdownProgress = progress
        progress.showWindow()

        pollOrphanDeath(machine: machine, lock: lock, image: image,
                        deadline: Date().addingTimeInterval(TimeInterval(total)))
    }

    private func pollOrphanDeath(machine: Machine, lock: ImageLock, image: URL, deadline: Date) {
        // The user cancelled or escalated; the panel is gone, so stop polling.
        guard sparcShutdownProgress != nil else { return }

        if !ImageLockManager.isProcessAlive(lock.pid) {
            ImageLockManager.forceRemove(imageURL: image)
            sparcShutdownProgress?.markSucceeded()
            // Let the green "Powered off" state register, then dismiss + boot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.sparcShutdownProgress?.close()
                self?.sparcShutdownProgress = nil
                self?.proceedLaunch(machine)
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
            self?.pollOrphanDeath(machine: machine, lock: lock, image: image, deadline: deadline)
        }
    }

    /// Force Quit chosen from the progress panel: tear the panel down, then run
    /// the verified SIGKILL path. The Helios shutdown call is one-shot and needs
    /// no cancellation -- the poll loop stops once the panel is gone.
    private func forceQuitFromProgress(machine: Machine, lock: ImageLock, image: URL) {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
        forceQuitOrphan(machine: machine, lock: lock, image: image)
    }

    /// Show Me How chosen from the progress panel: tear down and show the
    /// manual telnet steps.
    private func showManualFromProgress(telnetPort: UInt16, os: MachineOS? = nil) {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
        showManualShutdownInstructions(telnetPort: telnetPort, os: os)
    }

    /// Cancel chosen from the progress panel: stop waiting and leave the orphan
    /// running. Clearing `sparcShutdownProgress` also halts the poll loop.
    private func cancelShutdownWait() {
        sparcShutdownProgress?.close(); sparcShutdownProgress = nil
    }

    private func showManualShutdownInstructions(telnetPort: UInt16, os: MachineOS? = nil) {
        let alert = NSAlert()
        alert.messageText = "Shut down the running guest by hand"
        // The exact halt command is per-OS (init 5 on Solaris, halt on the
        // BSDs); show the guest's own when we know it (CODE_AUDIT §1).
        let haltCmd = os?.shutdownCommand ?? "init 5"
        var text = "In Terminal, connect to the running guest and halt it. Solaris 2.6 "
        text += "refuses a direct root telnet login, so log in as a normal user and "
        text += "then su to root:\n\n"
        text += "    telnet 127.0.0.1 \(telnetPort)\n"
        text += "    (log in as a user, then:)\n"
        text += "    su -\n"
        text += "    \(haltCmd)\n\n"
        if os == nil {
            text += "(On a BSD guest, use halt instead of init 5.) "
        }
        text += "Once it powers off, start the "
        text += "machine again. If telnet won\u{2019}t connect, use Force Quit instead (it risks "
        text += "a disk check on the next boot)."
        alert.informativeText = text
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

    /// No-image flow for a machine whose Start was pressed: a friendly
    /// hero-panel window (not the Settings tab, not a system error alert)
    /// explaining the bundled emulator and offering to pick an existing image
    /// or download a starter image. If the user dismisses, nothing changes and
    /// they'll see it again next Start. The image can also be set any time in
    /// the machine's Settings tab.
    private func presentInstallFlow(for machine: Machine) {
        installTargetID = machine.id
        if sparcWelcome == nil {
            sparcWelcome = SparcStationWelcomeWindowController(
                onChooseImage: { [weak self] in self?.chooseImageThenStart() },
                onDownload: { [weak self] in self?.downloadStarterImage() }
            )
        }
        sparcWelcome?.showWindow()
    }

    /// Pick an existing qcow2, attach it to the install-flow machine, and boot.
    private func chooseImageThenStart() {
        guard let registry, let id = installTargetID, var m = registry.machine(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Disk Image"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let claimant = registry.imageClaimant(imagePath: url.path, excluding: id) {
            showLaunchError("That image is already used by \u{201C}\(claimant.name)\u{201D} "
                            + "\u{2014} one machine per image.")
            return
        }
        m.imagePath = url.path
        registry.update(m)
        afterMachineMutation()
        startMachine(id)
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

    /// The Machines menu and its submenus compute enablement explicitly at build
    /// time (auto-enable off), so they don't route through here. Everything else
    /// (App-menu actions, standard responder-chain items) is always valid.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
