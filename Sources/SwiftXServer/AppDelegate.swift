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
    /// Open capture-viewer windows. The viewer supports multiple windows so
    /// several captures can be compared; each removes itself here on close.
    private var captureViewers: [CaptureViewerWindowController] = []
    private var activeLauncher: RemoteLauncher?
    /// In-flight Change Login probes, retained until they complete (the
    /// launcher's connection handlers hold it weakly, same as activeLauncher).
    /// Keyed by machine so a second submit can't stack a probe on a probe.
    private var loginProbes: [UUID: RemoteLauncher] = [:]
    /// The Add Machine wizard's in-flight login proof. Separate from
    /// loginProbes because the machine it's probing doesn't exist in the
    /// registry yet (there's no id to key by).
    private var wizardProbe: RemoteLauncher?
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
    /// Per-machine Users-admin windows, keyed by machine id.
    private var usersAdminControllers: [UUID: UsersWindowController] = [:]
    /// Per-machine Clock-admin windows, keyed by machine id.
    private var clockAdminControllers: [UUID: ClockWindowController] = [:]
    private var sparcWelcome: SparcStationWelcomeWindowController?
    /// The machine the welcome/install flow was opened for (Start pressed on an
    /// image-less VM); chooseImageThenStart attaches the picked image to it.
    private var installTargetID: UUID?
    /// In-flight curated-image downloads, keyed by machine id: the Task (for
    /// Cancel) and the latest phase (the row's thermometer + status text).
    /// One download per machine at a time; entries clear on finish/failure.
    private var imageDownloadTasks: [UUID: Task<Void, Never>] = [:]
    private var imageDownloadPhases: [UUID: ImageDownloadPhase] = [:]
    /// First-run deferred login: credentials collected in the "one more thing"
    /// step, held until the machine boots to ready, then applied by the
    /// UserAdmin pipeline (FIRST_RUN_EXPERIENCE.md). Keyed by machine id.
    private var pendingFirstLogin: [UUID: (user: String, password: String, dns: String?)] = [:]
    /// Machines whose first-run login is being applied right now (guest ready,
    /// UserAdmin running). Drives the row's "creating your login" state.
    private var applyingLogin: Set<UUID> = []
    /// The first-login window controller (one at a time; first run is serial).
    private var firstLoginWindow: FirstLoginWindowController?
    /// The unified Machines window (the front door) + its observable model. Built
    /// at launch. `refreshMachines` mirrors the registry + live controller state
    /// into the model (both the `machines` list for the master/Settings and the
    /// per-machine `rows` for the Overview), the same source the Machines menu
    /// reads, so window and menu never disagree.
    private var machinesWindow: MachinesWindowController?
    private var machinesModel: MachinesModel?

    // MARK: Helios prober state (see "Helios prober" section)

    /// What the last probe learned about a machine. The TCP layer is an
    /// aliveness oracle independent of helios configuration (Todd's model,
    /// 2026-07-10), so the states split along what physically happened:
    /// `up` = completed hello (alive, agent, authenticated); `unauthorized` =
    /// the agent ANSWERED but denied the request (alive, agent present, auth
    /// is the only problem); `noAgent` = connect REFUSED -- the host sent an
    /// RST, so the box is alive but nothing listens on the helios port
    /// ("not configured for helios" is a property of a living machine);
    /// `unreachable` = timeout / no-route / resolve failure -- the box is
    /// off, gone, or we're not on its network.
    enum HeliosReachability { case unknown, up, unauthorized, noAgent, unreachable }
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
    /// Concurrent queue for the blocking socket work (HeliosClient is sync). A
    /// pass fans every job out at once, so its wall-clock is ~one client timeout
    /// instead of the sum across hosts -- a dead box no longer holds up the
    /// results for the live ones behind it.
    private let probeQueue = DispatchQueue(label: "macxserver.helios.prober",
                                           qos: .utility, attributes: .concurrent)
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
    /// run. Bundled fixtures now seed user-less (the first-run flow fills the
    /// login), so there's no longer a bundledUser to derive.
    private func loadMachineRegistry() {
        self.registry = MachineRegistry.load(bundledImagePath: preferences.sparcDiskImagePath)
        // The launcher file is imported ONCE (MachinesFileLoader.loadOrMigrate, on
        // the first run when machines.json doesn't exist yet). After that the JSON
        // registry is authoritative and edited in-app via the Machine Editor -- we
        // deliberately no longer reconcile from the file on every launch, so in-app
        // edits aren't clobbered by a stale ~/.macxserver-launchers. See
        // MACHINE_MANAGER_REFACTOR.md / SHORTCUTS.md.
    }

    /// One loopback list for the whole app: MachinesFile's (it drives
    /// migration's emulated-vs-external inference; a second copy here had
    /// already started to drift).
    private static func isLoopbackHost(_ host: String) -> Bool {
        MachinesFile.isLoopback(host)
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
        model.onDownload  = { [weak self] id in self?.downloadCuratedImage(for: id) }
        model.onCancelDownload = { [weak self] id in
            self?.imageDownloadTasks[id]?.cancel()
        }
        // The starter-install wizard (DECISIONS 2026-07-16): the hero pane's
        // one path from imageless fixture to running machine.
        model.onInstallStarter = { [weak self] id, dir, user, password, dns in
            self?.beginStarterInstall(machineID: id, imagesDir: dir,
                                      username: user, password: password,
                                      dnsServer: dns)
        }
        model.onPickImagesDirectory = { [weak self] in self?.pickImagesDirectory() }
        model.imagesDirectory = { [weak self] in
            self?.effectiveImagesDirectory().path
                ?? ImageDownloader.defaultImagesDirectory.path
        }
        model.onChooseExistingImage = { [weak self] id in
            self?.chooseImageThenStart(for: id)
        }
        model.onLaunch    = { [weak self] id, name, verbose in
            self?.launchFromMachine(id, launcherName: name, verbose: verbose) }
        model.onSetHeliosSecret = { [weak self] id in self?.promptHeliosSecret(for: id) }
        model.onDnsAdmin  = { [weak self] id in self?.openDnsAdmin(machineID: id) }
        model.onFileTransfer = { [weak self] id in self?.openMachineFileTransfer(id) }
        model.onManageUsers = { [weak self] id in self?.openUsersAdmin(machineID: id) }
        model.onSyncClock = { [weak self] id in self?.openClockAdmin(machineID: id) }
        model.onVerifyLogin = { [weak self] id, user, password, completion in
            self?.verifyAndAdoptLogin(machineID: id, user: user,
                                      password: password, completion: completion)
        }
        // The sheet's explicit escape hatch after an unreachable proof: adopt
        // as-is. ssh machines never use a password (keys only), so nothing
        // credential-shaped is stored for them.
        model.onAdoptLoginUnverified = { [weak self] id, user, password in
            guard let self, let m = self.registry?.machine(id) else { return }
            let pw = (m.transport == .ssh || password.isEmpty) ? nil : password
            self.adoptMachineLogin(machineID: id, user: user, password: pw)
        }
        // What a blank DISPLAY actually resolves to at launch time (this X
        // server's own address) -- the Settings field shows it as the
        // placeholder so "blank" reads as a value, not a mystery.
        model.defaultDisplay = { [weak self] in
            guard let self else { return ":0" }
            return "\(self.advertisedHost):\(self.displayNumber)"
        }

        // Edit (master toolbar + Settings tab). Adding runs through the Add
        // Machine wizard (2026-07-15): nothing reaches the registry until its
        // Create, so a cancelled add leaves no half-configured "New Machine".
        model.onWizardCreate = { [weak self] machine, telnetPassword in
            guard let self, let registry = self.registry else { return nil }
            registry.add(machine)
            // A telnet password the wizard collected goes to the same
            // Keychain slot adoptMachineLogin fills -- the one launchers
            // actually read. Never into machines.json.
            if let pw = telnetPassword, !pw.isEmpty, !machine.user.isEmpty {
                let account = "\(machine.user)@\(machine.host):\(machine.resolvedPorts.telnet)"
                try? KeychainHelper.store(account: account, password: pw)
            }
            self.afterMachineMutation()
            return machine.id
        }
        model.onProbeLoginEndpoint = { [weak self] host, transport, user, password, completion in
            guard let self else { return }
            guard self.wizardProbe == nil else {
                completion(VerifyLoginFailure(
                    message: "A login check is already running.",
                    canSaveUnverified: false), nil)
                return
            }
            // The machine isn't in the registry yet, so ports are the
            // external-host defaults (the wizard doesn't expose overrides).
            let endpoint = Machine(name: "wizard-probe", kind: .externalHost,
                                   host: host, user: user, transport: transport)
            let probe: RemoteLauncher = transport == .ssh
                ? SSHLauncher.loginProbe(host: host,
                                         port: endpoint.resolvedPorts.ssh,
                                         user: user)
                : TelnetLauncher.loginProbe(host: host,
                                            port: endpoint.resolvedPorts.telnet,
                                            user: user, password: password,
                                            shellPrompt: nil)
            self.wizardProbe = probe
            probe.launch { [weak self] (result: Result<Void, Error>) in
                self?.wizardProbe = nil
                switch result {
                case .success:
                    // Proof only -- the wizard adopts at Create, not here.
                    // A telnet settle-path success carries the probe's best
                    // guess at the unrecognized prompt (nil from ssh probes).
                    completion(nil, (probe as? TelnetLauncher)?.suspectedShellPrompt)
                case .failure(let error):
                    completion(Self.loginProbeFailure(error, user: user), nil)
                }
            }
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
            self.usersAdminControllers.removeValue(forKey: id)?.close()
            self.clockAdminControllers.removeValue(forKey: id)?.close()
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
        model.hasHeliosSecret = { [weak self] id in
            guard let self, let m = self.registry?.machine(id) else { return false }
            return self.savedHeliosSecret(host: m.host, user: m.user) != nil
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
        /// The dot decoded in a word or two, carried everywhere the color
        /// shows (Todd 2026-07-10: colors stay, but words ride along).
        let stateWord: String?
        var progress: Double? = nil
        let reach = isEmulated ? nil : (probeResults[m.id]?.reach ?? .unknown)
        if let reach {
            // Every external with a host is probed now; the states mirror
            // what the TCP layer + agent actually said (see HeliosReachability).
            let hasSecret = savedHeliosSecret(host: m.host, user: m.user) != nil
            switch reach {
            case .unknown:
                dot = .external; stateWord = nil
                statusText = "External \u{00b7} checking\u{2026}"
            case .up:
                dot = .externalUp; stateWord = "reachable"
                statusText = "External \u{00b7} agent answering"
            case .unauthorized:
                dot = .externalUnauthorized
                stateWord = hasSecret ? "wrong secret" : "needs secret"
                statusText = hasSecret
                    ? "External \u{00b7} agent refused the saved secret"
                    : "External \u{00b7} agent present, set its secret in Settings"
            case .noAgent:
                dot = .externalNoAgent; stateWord = "no agent"
                statusText = "External \u{00b7} up, no Helios agent"
            case .unreachable:
                dot = .externalDown; stateWord = "unreachable"
                statusText = "External \u{00b7} unreachable"
            }
        } else if let phase = imageDownloadPhases[m.id] {
            // A curated-image download is in flight: the thermometer does
            // download duty (yellow, per IMAGE_DOWNLOAD_PLAN.md). The
            // fixed-cost phases (verify/decompress/install) report 1.0, which
            // renders as the moving barber pole — activity, not a stall.
            dot = .booting; statusText = phase.label; stateWord = "downloading"
            if case .downloading(let f) = phase { progress = f }
            else { progress = 1.0 }
        } else if !m.isInstalledEmulatedVM {
            dot = .notInstalled; statusText = "Not installed"; stateWord = "no image"
        } else if applyingLogin.contains(m.id) {
            // First-run: guest is ready, the add-user pipeline is running.
            // Keep the thermometer pegged + moving so it reads as the last
            // step of boot, not a stall.
            dot = .booting; statusText = "Creating your login\u{2026}"
            stateWord = "finishing setup"; progress = 1.0
        } else if state == .running && ready {
            dot = .running; statusText = "Running"; stateWord = "running"
            progress = 1.0
        } else if state == .running {
            dot = .booting; statusText = "Booting"; stateWord = "booting"
            progress = ctrl?.bootProgress
        } else if state == .shuttingDown {
            dot = .booting; statusText = "Shutting down"; stateWord = "stopping"
            progress = ctrl?.bootProgress
        } else {
            dot = .stopped; statusText = "Stopped"; stateWord = "stopped"
        }

        let subtitle = isEmulated
            ? (m.image.map { $0.lastPathComponent } ?? "no disk image")
            : "\(m.host) · external"

        let chips = m.launchers.map { l -> MachineLauncherChip in
            MachineLauncherChip(id: l.name, name: l.name,
                                enabled: launcherEnabled(machine: m, launcher: l,
                                                         isEmulated: isEmulated,
                                                         ready: ready, reach: reach))
        }
        // Why anything is dimmed, in words under the chips (nil = nothing
        // dimmed). Kept in step with launcherEnabled's cases.
        let launcherNote: String?
        if chips.isEmpty || chips.allSatisfy(\.enabled) {
            launcherNote = nil
        } else if isEmulated {
            launcherNote = "Launchers run once the machine is up and ready."
        } else if reach == .unreachable {
            launcherNote = "The machine isn't reachable from here, so launchers "
                         + "are disabled."
        } else {
            launcherNote = "Dimmed launchers connect with the Helios agent, which "
                         + "isn't answering. Telnet and SSH launchers still work."
        }

        return MachineRow(
            id: m.id, name: m.name, isEmulated: isEmulated,
            subtitle: subtitle, statusText: statusText, stateWord: stateWord,
            dot: dot, progress: progress, activeUser: m.user,
            hasStoredPassword: machineHasStoredPassword(m),
            launcherNote: launcherNote,
            systemLine: systemLine(for: m, ready: ready),
            showsLifecycle: isEmulated,
            canStart: (state == .stopped || state == .notInstalled)
                && imageDownloadPhases[m.id] == nil,
            canShutDown: (state == .running && ready),
            canForceQuit: (state == .running || state == .shuttingDown),
            canBackup: (state == .stopped),
            canConsole: (consoles[m.id] != nil),
            // Download…: an imageless emulated VM whose OS is known (the OS
            // keys the catalog, so a wrong image can't reach a wrong machine).
            canDownload: isEmulated && !m.isInstalledEmulatedVM && m.os != nil
                && imageDownloadPhases[m.id] == nil,
            isDownloading: imageDownloadPhases[m.id] != nil,
            // DNS gates on the box answering over Helios, same as File
            // Transfer. (The os != nil condition dropped 2026-07-09, audit
            // F4: the DNS panel writes a constant /etc/resolv.conf and never
            // consults the OS. The 2026-07-07 "OS-sensitive verbs" doctrine
            // still holds for verbs that ARE OS-sensitive; this one isn't.)
            canDnsAdmin: isEmulated
                ? (state == .running && ready)
                : probeResults[m.id]?.reach == .up,
            // Admin verbs gate on the box ANSWERING over Helios (the rule,
            // Todd 2026-07-07): emulated = ready (readiness IS the helios
            // liveness signal); external = the prober's last hello succeeded
            // (which, against the fail-closed agent, also proves the saved
            // secret is right). File Transfer is OS-agnostic so it doesn't
            // need the machine's OS, unlike canDnsAdmin.
            canFileTransfer: isEmulated
                ? (state == .running && ready)
                : probeResults[m.id]?.reach == .up,
            // Users is File Transfer's gate PLUS a known OS (UserAdmin's
            // per-OS record mechanics need it). An external box gets its OS
            // from sysinfo uname; an emulated VM from image detection.
            canManageUsers: (m.os != nil) && (isEmulated
                ? (state == .running && ready)
                : probeResults[m.id]?.reach == .up),
            // The agent-less tier of Change… (2026-07-14): any external box
            // the Users panel can't serve gets the Change Login sheet --
            // proof is the box's own login channel (telnet password or ssh
            // key by transport), not the panel's hash check. That includes
            // "unreachable": the helios dot can't see a firewall-DROP box (a
            // Linux host dropping 2125 reads down while sshd answers; the
            // nuc), so the login attempt is its own truth. Never while the
            // panel tier is available, never for emulated VMs (our guests
            // all run the agent -- "not ready" means wait), and never for
            // unauthorized (an agent EXISTS; fix the secret rather than
            // side-step the panel).
            canChangeLogin: !isEmulated
                && !((m.os != nil) && probeResults[m.id]?.reach == .up)
                && probeResults[m.id]?.reach != .unauthorized,
            changeLoginUsesSSHKey: m.transport == .ssh,
            // Clock shares Users' gate: OS-sensitive (per-OS date grammar +
            // the 4.1.4 year-safety probe) and needs the box answering.
            canSyncClock: (m.os != nil) && (isEmulated
                ? (state == .running && ready)
                : probeResults[m.id]?.reach == .up),
            osIsDetected: !isEmulated && probeResults[m.id]?.sysinfo?.uname != nil,
            canSetHeliosSecret: !isEmulated,
            launchers: chips)
    }

    /// One rule for whether a launcher is runnable right now, shared by the
    /// Overview chips and the Machines menu so they can never disagree.
    /// Emulated: the guest must be up and ready for ANY transport (a launch
    /// against a stopped VM only fails slowly). External (2026-07-10, Todd's
    /// model): dim only on KNOWLEDGE of failure -- the box is confirmed
    /// unreachable (no transport can work), or this launcher's effective
    /// transport is helios and the agent isn't answering (a helios launch
    /// against an absent/denying agent is a guaranteed failure). Telnet/SSH
    /// launchers stay live on any alive box -- a REFUSED helios connect is
    /// positive proof the box is up. Unknown (first probe pending) stays
    /// optimistic.
    private func launcherEnabled(machine m: Machine, launcher l: MachineLauncher,
                                 isEmulated: Bool, ready: Bool,
                                 reach: HeliosReachability?) -> Bool {
        if isEmulated { return ready }
        switch reach ?? .unknown {
        case .unreachable: return false
        case .up, .unknown: return true
        case .unauthorized, .noAgent:
            return (l.transport ?? m.transport) != .helios
        }
    }

    /// Open the machine's file browser (Overview → Helios Admin Agents →
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
        let account = heliosSecretAccount(host: m.host)
        let alert = NSAlert()
        alert.messageText = "Helios secret for \(m.host)"
        alert.informativeText = "The password this machine's Helios agent expects. "
            + "The app sends it whenever it talks to the agent: file transfer, DNS, "
            + "status. Leave blank to clear it. Kept in your macOS Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = SecretEntryField()
        // savedHeliosSecret (not a bare retrieve) so a legacy user@host-keyed
        // entry prefills here and migrates forward.
        field.value = savedHeliosSecret(host: m.host, user: m.user) ?? ""
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
        menu.addItem(.separator())

        // Dynamic launch surface (2026-07-10): only machines the app can (or
        // suspects it can) reach get a submenu. An emulated VM must be running and
        // ready; an external host must not be confirmed unreachable (up / unknown /
        // agent-down all still show -- a live box you can telnet into). Stopped VMs
        // and dead hosts drop off; start or add machines from the Machines window.
        let shown = (registry?.machines ?? []).filter { machineReachableForMenu($0) }
        for m in shown {
            let header = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: m.name)
            sub.autoenablesItems = false
            buildMachineSubmenu(sub, machine: m)
            header.submenu = sub
            menu.addItem(header)
        }
        // Non-empty registry but nothing reachable: say so rather than show a
        // menu that looks broken (just the list item + a separator).
        if shown.isEmpty && !(registry?.machines.isEmpty ?? true) {
            let none = NSMenuItem(title: "No machines reachable", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    /// Whether a machine earns a spot in the Machines menu (the live-launch
    /// surface). Emulated: running and ready. External: anything the prober
    /// hasn't confirmed dead (up / unknown / unauthorized / noAgent) -- a box you
    /// can reach some way. Mirrors the reach model behind `launcherEnabled`.
    @MainActor
    private func machineReachableForMenu(_ m: Machine) -> Bool {
        if m.kind == .emulatedVM {
            let ctrl = registry?.controller(m.id)
            return ctrl?.engine.state == .running && (ctrl?.isReady ?? false)
        }
        return (probeResults[m.id]?.reach ?? .unknown) != .unreachable
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

        // Admin verbs mirror the Overview's Helios Admin Agents section exactly
        // (audit F5, 2026-07-09: the menu and window used to disagree -- a
        // menu-first user couldn't find File Transfer at all). Gates match
        // machineRow: emulated = running and ready; external = the prober's
        // last hello succeeded. DNS is not OS-gated (audit F4).
        let canAdmin = isEmulated ? ready : (probeResults[m.id]?.reach == .up)

        func addAdminSubmenu() {
            let adminItem = NSMenuItem(title: "Admin", action: nil, keyEquivalent: "")
            adminItem.isEnabled = canAdmin
            let adminMenu = NSMenu(title: "Admin")
            adminMenu.autoenablesItems = false
            let transfer = NSMenuItem(title: "File Transfer\u{2026}",
                                      action: #selector(fileTransferMenu(_:)), keyEquivalent: "")
            transfer.target = self
            transfer.isEnabled = canAdmin
            transfer.representedObject = idString
            adminMenu.addItem(transfer)
            let dns = NSMenuItem(title: "DNS (/etc/resolv.conf)\u{2026}",
                                 action: #selector(openDnsAdmin(_:)), keyEquivalent: "")
            dns.target = self
            dns.isEnabled = canAdmin
            dns.representedObject = idString
            adminMenu.addItem(dns)
            // Users is OS-sensitive: needs the box answering AND its OS known.
            let users = NSMenuItem(title: "Users\u{2026}",
                                   action: #selector(openUsersAdmin(_:)), keyEquivalent: "")
            users.target = self
            users.isEnabled = canAdmin && (m.os != nil)
            users.representedObject = idString
            adminMenu.addItem(users)
            adminItem.submenu = adminMenu
            sub.addItem(adminItem)
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
            addAdminSubmenu()
        } else {
            // (No Helios Secret item anymore: the entry point moved to
            // Settings -> Connection 2026-07-09, and the menu mirrors the
            // Overview's operate verbs, not Settings.)
            addAdminSubmenu()
        }

        if !m.launchers.isEmpty {
            sub.addItem(.separator())
            let reach = isEmulated ? nil : (probeResults[m.id]?.reach ?? .unknown)
            for l in m.launchers {
                let item = NSMenuItem(title: l.name,
                                      action: #selector(launchMachineLauncher(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(m.id.uuidString)/\(l.name)" as NSString
                // Same rule as the Overview chips (launcherEnabled): menu and
                // window can never disagree.
                item.isEnabled = launcherEnabled(machine: m, launcher: l,
                                                 isEmulated: isEmulated,
                                                 ready: ready, reach: reach)
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
    @objc private func fileTransferMenu(_ sender: NSMenuItem) {
        if let id = machineID(from: sender) { openMachineFileTransfer(id) }
    }
    // (setHeliosSecretMenu retired 2026-07-09: the menu item moved out with
    // the Overview button; the entry point is Settings -> Connection, wired
    // through model.onSetHeliosSecret.)


    /// Resolve one machine's engine config: helper + firmware from the app
    /// bundle (or SPARCPLUG_ENGINE_DIR in dev), everything else -- image, memory,
    /// ports, MAC, OS profile -- from the machine itself. nil for an external
    /// host or an image-less VM.
    private func engineConfig(for machine: Machine) -> QemuEngineConfig? {
        return machine.makeEngineConfig()
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
            // First-run deferred login: the guest is finally answering, so
            // apply the account collected in the "one more thing" step.
            self?.applyPendingFirstLogin(machineID: id)
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

        // App menu (the bold one, always titled with the process name). Kept to
        // the macOS-standard minimum: About / Preferences / Hide / Quit. The
        // server config editors and capture actions that used to live here moved
        // to the X11Server menu where they belong (2026-07-10 menu reorg).
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

        // Machines menu -- the meat of the app, so it sits in the "File" slot
        // right after the app menu. Rebuilt from the registry: the list window, a
        // submenu per machine (bundled VM lifecycle verbs, launchers for all,
        // Helios secret for external hosts), plus add/edit.
        let machinesMenuItem = NSMenuItem()
        let mMenu = NSMenu(title: "Machines")
        self.machinesMenu = mMenu
        rebuildMachinesMenu(mMenu)
        machinesMenuItem.submenu = mMenu
        main.addItem(machinesMenuItem)

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

        // X11Server menu -- everything scoped to the X server itself: its live
        // status, the occasional control (Drop All Clients), the config editors
        // (Resources, Font Mappings), and the capture actions in their own
        // submenu (captures are recordings of the X protocol stream). The
        // Preferences-tab config (scale, clipboard, Motif frame) stays in Prefs.
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

        serverMenu.addItem(.separator())
        let resources = NSMenuItem(title: "Edit Resources\u{2026}",
                                   action: #selector(openResources(_:)),
                                   keyEquivalent: "")
        resources.target = self
        serverMenu.addItem(resources)
        let fonts = NSMenuItem(title: "Edit Font Mappings\u{2026}",
                               action: #selector(openFontMappings(_:)),
                               keyEquivalent: "")
        fonts.target = self
        serverMenu.addItem(fonts)

        // Capture submenu -- the toggle lives in Preferences (Capture tab); these
        // are pure actions on the captures folder.
        serverMenu.addItem(.separator())
        let captureItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu(title: "Capture")
        let openCapture = NSMenuItem(title: "Open Capture\u{2026}",
                                     action: #selector(openCapture(_:)),
                                     keyEquivalent: "")
        openCapture.target = self
        captureMenu.addItem(openCapture)
        let revealCaptures = NSMenuItem(title: "Reveal Captures Folder",
                                        action: #selector(revealCapturesFolder(_:)),
                                        keyEquivalent: "")
        revealCaptures.target = self
        captureMenu.addItem(revealCaptures)
        let discardCaptures = NSMenuItem(title: "Discard All Captures\u{2026}",
                                         action: #selector(discardAllCaptures(_:)),
                                         keyEquivalent: "")
        discardCaptures.target = self
        captureMenu.addItem(discardCaptures)
        captureItem.submenu = captureMenu
        serverMenu.addItem(captureItem)

        serverMenuItem.submenu = serverMenu
        main.addItem(serverMenuItem)

        // No Window menu: the X clients aren't documents and the standard window
        // list added nothing here. Killed in the 2026-07-10 reorg along with the
        // now-orphaned Minimize/Close/Bring-All-to-Front items.

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

    @objc private func openUsersAdmin(_ sender: Any?) {
        guard let id = machineID(from: sender) else { return }
        openUsersAdmin(machineID: id)
    }

    /// Open (or focus) the Users admin panel for a machine. Same live-provider
    /// shape as DNS admin, plus an OS provider (UserAdmin is per-OS) and the
    /// "use for launchers" hook that adopts a freshly-added account as the
    /// machine's login.
    @MainActor
    private func openUsersAdmin(machineID id: UUID) {
        guard let m = registry?.machine(id) else { return }
        if usersAdminControllers[id] == nil {
            let hostFor: () -> String = { [weak self] in
                guard let m = self?.registry?.machine(id) else { return "127.0.0.1" }
                return m.kind == .emulatedVM ? "127.0.0.1" : m.host
            }
            usersAdminControllers[id] = UsersWindowController(
                machineName: m.name,
                osProvider: { [weak self] in self?.registry?.machine(id)?.os },
                secretProvider: { [weak self] in
                    guard let self, let m = self.registry?.machine(id) else { return nil }
                    return self.heliosSecret(host: hostFor(), user: m.user,
                                             port: m.resolvedPorts.helios)
                },
                hostProvider: hostFor,
                portProvider: { [weak self] in
                    self?.registry?.machine(id)?.resolvedPorts.helios ?? 2125
                },
                activeUserProvider: { [weak self] in
                    self?.registry?.machine(id)?.user ?? ""
                },
                onSetActiveUser: { [weak self] user, password in
                    self?.adoptMachineLogin(machineID: id, user: user, password: password)
                })
        }
        usersAdminControllers[id]?.showWindow()
    }

    /// Open (or focus) the Clock admin panel for a machine. Same live-provider
    /// shape as Users admin (the panel is per-OS: date grammar and the 4.1.4
    /// year-safety gate live in ClockAdmin).
    @MainActor
    private func openClockAdmin(machineID id: UUID) {
        guard let m = registry?.machine(id) else { return }
        if clockAdminControllers[id] == nil {
            let hostFor: () -> String = { [weak self] in
                guard let m = self?.registry?.machine(id) else { return "127.0.0.1" }
                return m.kind == .emulatedVM ? "127.0.0.1" : m.host
            }
            clockAdminControllers[id] = ClockWindowController(
                machineName: m.name,
                osProvider: { [weak self] in self?.registry?.machine(id)?.os },
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
        clockAdminControllers[id]?.showWindow()
    }

    /// Whether the machine's active user has a password on file: the
    /// cleartext machines.json field, or the telnet Keychain slot
    /// adoptMachineLogin writes (same account format). Existence only --
    /// the value never reaches the row.
    private func machineHasStoredPassword(_ m: Machine) -> Bool {
        guard !m.user.isEmpty else { return false }
        if m.password?.isEmpty == false { return true }
        let account = "\(m.user)@\(m.host):\(m.resolvedPorts.telnet)"
        return KeychainHelper.retrieve(account: account) != nil
    }

    /// Adopt a guest account as the machine's ACTIVE USER: set `machine.user`
    /// and stash the password in the telnet Keychain slot (the per-machine
    /// `user@host:telnetPort` key launchers read). Shared by the Users panel
    /// (the add-sheet checkbox and the password-verified Set Active flow) and
    /// the first-run flow.
    @MainActor
    private func adoptMachineLogin(machineID id: UUID, user: String, password: String?) {
        guard let registry, var m = registry.machine(id) else { return }
        m.user = user
        // password nil = the ssh-key Change Login path: there IS no password
        // (BatchMode proved the key), so leave every credential untouched --
        // storing an empty string would clobber a real telnet password for
        // some other account on the same host.
        if let password {
            // A cleartext machines.json password outranks the Keychain at
            // launch (Machine.resolved injects it), so a machine carrying one
            // must have it follow the switch -- otherwise launchers keep
            // sending the OLD account's password as the new user. Machines
            // without one stay Keychain-only.
            if m.password?.isEmpty == false { m.password = password }
            let account = "\(user)@\(m.host):\(m.resolvedPorts.telnet)"
            try? KeychainHelper.store(account: account, password: password)
        }
        registry.update(m)
        afterMachineMutation()
    }

    /// The agent-less tier of the Overview's Change… (2026-07-14): prove the
    /// typed login against the box's own channel -- transport ssh = a
    /// BatchMode key check (no password; the exact trust level ssh launchers
    /// run at), anything else = a live telnet login (TelnetLauncher probe
    /// mode: reaches a shell, runs nothing, exits) -- then adopt via
    /// adoptMachineLogin. Same "prove it" doctrine as the Users panel; the
    /// proof channel is the box's login instead of the agent's hash check.
    /// Completion is called on the main actor with nil on success, else a
    /// VerifyLoginFailure for the sheet's inline error -- split into "the box
    /// rejected it" (authoritative no) vs "the proof couldn't run" (box off
    /// the network), because only the second earns the save-without-checking
    /// offer.
    @MainActor
    private func verifyAndAdoptLogin(machineID id: UUID, user: String,
                                     password: String,
                                     completion: @escaping (VerifyLoginFailure?) -> Void) {
        guard let m = registry?.machine(id) else {
            completion(VerifyLoginFailure(message: "The machine is gone.",
                                          canSaveUnverified: false))
            return
        }
        guard loginProbes[id] == nil else {
            completion(VerifyLoginFailure(
                message: "A login check is already running for this machine.",
                canSaveUnverified: false))
            return
        }
        let host = m.kind == .emulatedVM ? "127.0.0.1" : m.host
        let usesSSH = m.transport == .ssh
        let probe: RemoteLauncher = usesSSH
            ? SSHLauncher.loginProbe(host: host, port: m.resolvedPorts.ssh,
                                     user: user)
            : TelnetLauncher.loginProbe(host: host,
                                        port: m.resolvedPorts.telnet,
                                        user: user, password: password,
                                        shellPrompt: m.shellPrompt)
        loginProbes[id] = probe
        probe.launch { [weak self] (result: Result<Void, Error>) in
            // Both launchers complete on the main queue already.
            self?.loginProbes[id] = nil
            switch result {
            case .success:
                // ssh proved a key, not a password -- adopt the user and
                // leave every stored credential alone.
                self?.adoptMachineLogin(machineID: id, user: user,
                                        password: usesSSH ? nil : password)
                completion(nil)
            case .failure(let error):
                completion(Self.loginProbeFailure(error, user: user))
            }
        }
    }

    /// Map a login-probe error to what the sheet should say and offer. The
    /// dividing line is whether the box ANSWERED: an authentication rejection
    /// is authoritative (no escape hatch -- retype and retry), while anything
    /// that kept the proof from running at all (name didn't resolve, nothing
    /// answering, connection died) gets a plain-English "why you're seeing
    /// this" instead of raw NWError text, plus the save-without-checking
    /// offer -- a box that's off the network shouldn't make its login
    /// permanently uneditable.
    private static func loginProbeFailure(_ error: Error,
                                          user: String) -> VerifyLoginFailure {
        switch error {
        case TelnetLaunchError.authenticationFailed:
            return VerifyLoginFailure(
                message: "That user and password didn\u{2019}t log in.",
                canSaveUnverified: false)
        case SSHLaunchError.authenticationFailed:
            return VerifyLoginFailure(
                message: "Your ssh key didn\u{2019}t log in as "
                       + "\u{201C}\(user)\u{201D}.",
                canSaveUnverified: false)
        case TelnetLaunchError.connectionFailed:
            // One plain sentence for every can't-connect shape (Todd's
            // wording, 2026-07-15) -- the sub-cause (DNS, refused, timeout)
            // wasn't earning its words in a dialog.
            return VerifyLoginFailure(
                message: "The machine isn\u{2019}t reachable right now to "
                       + "validate the username and password.",
                canSaveUnverified: true)
        default:
            // Telnet prompt timeouts, ssh connection exits, spawn failures:
            // the conversation never finished, so the login was neither
            // proven nor disproven -- the hatch stays available.
            return VerifyLoginFailure(
                message: "The login couldn\u{2019}t be checked: "
                       + error.localizedDescription,
                canSaveUnverified: true)
        }
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

    /// Keychain account under which an external machine's Helios daemon secret
    /// is stored. Keyed by HOST alone (2026-07-09): the agent's secret is a
    /// per-box fact -- one daemon, one secret, whichever login telnet/ssh/
    /// run-as uses -- so editing the User field must not detach it. (It did
    /// when the key was user@host: the lookup came back empty, the prober
    /// helloed with no auth, and the dot read "refused the secret" for what
    /// was really an app-side key miss.)
    private func heliosSecretAccount(host: String) -> String {
        "helios:\(host.lowercased())"
    }

    /// Retrieve an external box's saved secret, migrating a legacy
    /// user@host-keyed entry forward once: copy it under the host key and use
    /// it; the old entry is left alone (same pattern as the telnet password
    /// key migration).
    private func savedHeliosSecret(host: String, user: String) -> String? {
        let account = heliosSecretAccount(host: host)
        if let s = KeychainHelper.retrieve(account: account) { return s }
        if let legacy = KeychainHelper.retrieve(account: "helios:\(user)@\(host)") {
            try? KeychainHelper.store(account: account, password: legacy)
            return legacy
        }
        return nil
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
        return savedHeliosSecret(host: host, user: user)
    }

    // MARK: - Helios prober (external reachability + guest sysinfo)
    //
    // The prober is the ALIVENESS ORACLE for external boxes (2026-07-10):
    // every ~3 minutes (plus immediately at launch, after any machine
    // mutation, after a secret change, and when a guest comes ready) it
    // hellos every external with a host and classifies what the TCP layer +
    // agent actually said (up / unauthorized / noAgent / unreachable).
    // Gating doctrine: admin verbs need `up` (they ride the agent);
    // launcher chips dim only on KNOWLEDGE of failure -- a confirmed
    // unreachable box, or a helios-transport launcher without an answering
    // agent (see launcherEnabled). Telnet/SSH launchers on an alive box
    // never gate on probe staleness: real machines run for months, and
    // failing at use with a clear error beats a mysteriously dimmed button.

    /// One probe job, snapshotted on the main thread so the worker never
    /// touches the registry or the Keychain.
    private struct HeliosProbeJob {
        let id: UUID
        let host: String
        let port: UInt16
        let secret: String?
        let isEmulated: Bool
    }

    /// Thread-safe sink for a parallel probe pass: the concurrent workers each
    /// `add` their result under the lock, then the completion `drain`s the batch.
    /// A reference type so there's no captured `var` for the concurrency checker
    /// to flag -- the mutation rides through the lock, not a shared inout.
    /// `@unchecked Sendable` is honest here: every access goes through `lock`.
    private final class ProbeResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [(UUID, HeliosProbeResult)] = []
        func add(_ id: UUID, _ result: HeliosProbeResult) {
            lock.lock()
            results.append((id, result))
            lock.unlock()
        }
        func drain() -> [(UUID, HeliosProbeResult)] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
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
                // EVERY external with a host is probed, secret or not
                // (2026-07-10, superseding the one-day secret-saved rule): the
                // probe is the aliveness oracle, not just a helios check. A
                // secretless box still classifies -- refused = alive without
                // an agent, denied = alive with an agent awaiting a secret,
                // timeout = not there. Display maps those honestly; nothing
                // gates a launch on them except a confirmed unreachable.
                let secret = savedHeliosSecret(host: m.host, user: m.user)
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
        // Fan the probes out concurrently (probeQueue is concurrent): each blocks
        // its own thread for up to the client timeout. The collector's internal
        // lock makes the appends safe; group.notify posts the whole batch once,
        // on main, when the slowest probe returns.
        let group = DispatchGroup()
        let collector = ProbeResultCollector()
        for job in jobs {
            group.enter()
            probeQueue.async {
                collector.add(job.id, Self.probe(job))
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let results = collector.drain()
            for (id, result) in results { self.probeResults[id] = result }
            self.adoptDetectedOSes(results)
            // refreshSparcMenu (not just refreshMachines): a probe can change
            // which external hosts are reachable, and the Machines menu now
            // shows only reachable machines, so the menu must rebuild too.
            self.refreshSparcMenu()
        }
    }

    /// Blocking single-machine probe (runs on probeQueue): hello for
    /// liveness, then sysinfo best-effort. A protocolError on hello means the
    /// agent ANSWERED (it's alive) -- "unauthorized" is the config signal. A
    /// REFUSED connect means the host is alive with no agent listening. Only
    /// timeout / no-route / resolve failure count as unreachable. An old
    /// agent's "unknown verb" on sysinfo just means no stats (pre-0.2.0).
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
        } catch HeliosClient.HeliosError.connectionRefused {
            return HeliosProbeResult(reach: .noAgent, hello: nil, sysinfo: nil, at: Date())
        } catch {
            return HeliosProbeResult(reach: .unreachable, hello: nil, sysinfo: nil, at: Date())
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
        // Keyed by user@host:port (2026-07-09, audit F6): every emulated VM is
        // host 127.0.0.1, so the old user@host key made all loopback VMs with
        // the same user share ONE stored password -- first-launch prompt for
        // VM A silently became VM B's password. The telnet port is
        // per-machine, so it disambiguates.
        let account = "\(entry.user)@\(entry.host):\(entry.port)"
        if let password = KeychainHelper.retrieve(account: account) {
            executeLaunch(entry: entry, os: os, password: password, verbose: verbose)
        } else if let legacy = KeychainHelper.retrieve(account: "\(entry.user)@\(entry.host)") {
            // One-shot migration from the old key: copy it forward under the
            // new key and use it. The old entry is left alone -- lookalike
            // user@host items may belong to other apps, not ours to delete.
            try? KeychainHelper.store(account: account, password: legacy)
            executeLaunch(entry: entry, os: os, password: legacy, verbose: verbose)
        } else {
            promptForPassword(entry: entry, os: os, account: account, verbose: verbose)
        }
    }

    private func promptForPassword(entry: LauncherEntry, os: MachineOS?, account: String,
                                   verbose: Bool) {
        let alert = NSAlert()
        // The Keychain account string carries a port suffix now; the title
        // stays human ("user on host"), not the storage key.
        alert.messageText = "Password for \(entry.user) on \(entry.host)"
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
        // Rebuilt per presentation (cheap): the copy names the target
        // machine's guest OS, which differs per fixture.
        sparcWelcome = SparcStationWelcomeWindowController(
            osName: machine.os?.displayName,
            onChooseImage: { [weak self] in self?.chooseImageThenStart() },
            onDownload: { [weak self] in self?.downloadStarterImage() }
        )
        sparcWelcome?.showWindow()
    }

    /// The hero pane's existing-image path: same semantics, explicit target.
    func chooseImageThenStart(for id: UUID) {
        installTargetID = id
        chooseImageThenStart()
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

    /// The welcome window's Download button: the same curated-download flow as
    /// the Overview's Download… button, targeting the machine whose Start
    /// opened the window.
    private func downloadStarterImage() {
        guard let id = installTargetID else { return }
        downloadCuratedImage(for: id)
    }

    /// The curated-image download flow (IMAGE_DOWNLOAD_PLAN.md): fetch the
    /// catalog on click (never in the background), confirm with the real
    /// sizes, then run the verify-everything pipeline with progress on the
    /// machine's row. The user makes zero choices — the machine's OS keys the
    /// catalog and the filename derives from the machine's identity, so a
    /// wrong image can't reach a wrong machine by construction.
    private func downloadCuratedImage(for id: UUID) {
        guard let registry, let m = registry.machine(id),
              m.kind == .emulatedVM, m.image == nil, let os = m.os,
              imageDownloadTasks[id] == nil else { return }
        Task { @MainActor in
            let catalog: ImageCatalog
            do {
                catalog = try await ImageCatalog.fetch()
            } catch {
                self.showLaunchError("Couldn't fetch the image catalog from "
                    + "\(ImageCatalog.catalogURL.host ?? "the server"): "
                    + error.localizedDescription)
                return
            }
            guard let entry = catalog.entry(for: os) else {
                self.showLaunchError("The catalog doesn't carry a "
                    + "\(os.displayName) image. Attach one you already have "
                    + "via the machine's Settings tab.")
                return
            }
            self.confirmAndRunImageDownload(machineID: id, entry: entry)
        }
    }

    /// Confirm sheet (real sizes from the catalog), then the pipeline. The
    /// wizard path skips this -- its summary step IS the confirm -- and calls
    /// runImageDownload directly.
    private func confirmAndRunImageDownload(machineID: UUID,
                                            entry: ImageCatalog.Entry) {
        guard let registry, let m = registry.machine(machineID),
              let os = m.os else { return }
        let fmt = ByteCountFormatter()
        let alert = NSAlert()
        alert.messageText = "Download the \(os.displayName) starter image?"
        var info = "Downloads \(fmt.string(fromByteCount: entry.sizeGz)) from "
            + "\(entry.url.host ?? "the catalog host") "
            + "(\(fmt.string(fromByteCount: entry.size)) on disk). "
            + "It becomes \u{201C}\(m.name)\u{201D}\u{2019}s disk."
        if let notes = entry.notes, !notes.isEmpty {
            info = notes + "\n\n" + info
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runImageDownload(machineID: machineID, entry: entry)
    }

    /// The verify-everything download pipeline with progress on the machine's
    /// row. The destination directory is the images-directory preference (or
    /// the App Support default); the FILENAME is never user-chosen: bundled
    /// fixtures get the canonical `<os>-boot.qcow2`, user machines
    /// `<os>-<shortid>.qcow2`. Disk-space preflight and the three
    /// verifications live in ImageDownloader. At completion: a wizard install
    /// (pending login stashed) boots straight away; a legacy path with no
    /// user yet gets the "one more thing" panel.
    private func runImageDownload(machineID: UUID, entry: ImageCatalog.Entry) {
        guard let registry, let m = registry.machine(machineID),
              let os = m.os else { return }
        let destination = effectiveImagesDirectory()
            .appendingPathComponent(ImageDownloader.imageFilename(
                os: os, machineID: m.id, bundled: m.bundled))

        imageDownloadPhases[machineID] = .downloading(fraction: 0)
        refreshMachines()
        imageDownloadTasks[machineID] = Task { @MainActor in
            do {
                try await ImageDownloader.install(
                    entry: entry, destination: destination, expectedOS: os,
                    onPhase: { [weak self] phase in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.imageDownloadPhases[machineID] != nil
                            else { return }
                            self.imageDownloadPhases[machineID] = phase
                            self.refreshMachines()
                        }
                    })
                // Installed and triple-verified: attach it to the machine.
                // The row flips to Stopped; Start goes live.
                if var updated = self.registry?.machine(machineID) {
                    updated.imagePath = destination.path
                    self.registry?.update(updated)
                }
                self.finishImageDownload(machineID)
                self.afterMachineMutation()
                if self.pendingFirstLogin[machineID] != nil {
                    // Wizard install: the login (and optional DNS) was
                    // collected up front. Boot now; onReady applies it.
                    self.startMachine(machineID)
                } else if let m = self.registry?.machine(machineID),
                          m.user.isEmpty {
                    // Legacy paths (welcome window, + wizard's download
                    // fork): the "one more thing -- add a user" moment.
                    self.presentFirstLoginStep(for: machineID)
                }
            } catch ImageDownloadError.cancelled {
                // A cancelled install must not leave credentials armed for
                // some unrelated later boot.
                self.pendingFirstLogin[machineID] = nil
                self.finishImageDownload(machineID)
            } catch {
                self.pendingFirstLogin[machineID] = nil
                self.finishImageDownload(machineID)
                self.showLaunchError("Image download failed: "
                    + error.localizedDescription)
            }
        }
    }

    /// Clear a finished/failed/cancelled download's state and refresh the row.
    private func finishImageDownload(_ id: UUID) {
        imageDownloadTasks[id] = nil
        imageDownloadPhases[id] = nil
        refreshMachines()
    }

    // MARK: - Starter-install wizard (DECISIONS 2026-07-16)

    /// Where downloaded images land: the preference if set, else the App
    /// Support default. One global directory; filenames stay derived.
    private func effectiveImagesDirectory() -> URL {
        let pref = Preferences().imagesDirectoryPath
        guard !pref.isEmpty else { return ImageDownloader.defaultImagesDirectory }
        return URL(fileURLWithPath: (pref as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    /// The wizard's location step: a directories-only open panel.
    private func pickImagesDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Images Folder"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// The install wizard's commit: persist the images-directory choice,
    /// stash the deferred login (+ optional DNS), and kick the curated
    /// download. The pipeline's completion boots the machine; `onReady`
    /// applies the account. Catalog/entry failures clear the stash --
    /// credentials must never outlive the install that collected them.
    @MainActor
    private func beginStarterInstall(machineID id: UUID, imagesDir: String,
                                     username: String, password: String,
                                     dnsServer: String?) {
        guard let registry, let m = registry.machine(id),
              m.kind == .emulatedVM, m.image == nil, let os = m.os,
              imageDownloadTasks[id] == nil else { return }
        // The directory choice persists as the one global preference, and
        // only when it differs from the default (an untouched prefill stays
        // "default" so the default can move in a future version).
        let chosen = (imagesDir as NSString).expandingTildeInPath
        let prefs = Preferences()
        if chosen == ImageDownloader.defaultImagesDirectory.path {
            prefs.imagesDirectoryPath = ""
        } else {
            prefs.imagesDirectoryPath = chosen
        }
        pendingFirstLogin[id] = (user: username, password: password, dns: dnsServer)
        Task { @MainActor in
            let catalog: ImageCatalog
            do {
                catalog = try await ImageCatalog.fetch()
            } catch {
                self.pendingFirstLogin[id] = nil
                self.showLaunchError("Couldn't fetch the image catalog from "
                    + "\(ImageCatalog.catalogURL.host ?? "the server"): "
                    + error.localizedDescription)
                return
            }
            guard let entry = catalog.entry(for: os) else {
                self.pendingFirstLogin[id] = nil
                self.showLaunchError("The catalog doesn't carry a "
                    + "\(os.displayName) image. Attach one you already have "
                    + "via \u{201C}Use a disk image I already have\u{201D}.")
                return
            }
            self.runImageDownload(machineID: id, entry: entry)
        }
    }

    // MARK: - First-run login (FIRST_RUN_EXPERIENCE.md)

    /// The "one more thing -- add a user" step. Collects a username + password,
    /// then boots the machine and defers the UserAdmin pipeline to `onReady`.
    /// Skipping leaves the machine user-less; the empty-user state re-offers
    /// this on the next boot (invitation, not a gate).
    @MainActor
    func presentFirstLoginStep(for machineID: UUID) {
        guard let m = registry?.machine(machineID) else { return }
        // Suggest the Mac's short login name, lowercased + cleaned to the
        // username rules, so Enter-through works for the common case.
        let suggested = String(NSUserName().lowercased()
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }
            .prefix(8))
        firstLoginWindow = FirstLoginWindowController(
            machineName: m.name,
            suggestedUsername: suggested,
            onCreate: { [weak self] user, password in
                self?.beginFirstLogin(machineID: machineID, user: user,
                                      password: password)
            },
            onSkip: { /* user-less; re-offered on next ready */ })
        firstLoginWindow?.showWindow()
    }

    /// Stash the pending credentials and boot. The account is created at
    /// `onReady` (the daemon must answer before /etc/passwd can be touched).
    @MainActor
    private func beginFirstLogin(machineID: UUID, user: String, password: String) {
        pendingFirstLogin[machineID] = (user: user, password: password, dns: nil)
        startMachine(machineID)
    }

    /// Fired from `onReady`: if a login is pending for this machine, run the
    /// UserAdmin add-user pipeline over its now-live daemon, then adopt the
    /// account as the machine's launcher login. Runs off-main (HeliosClient is
    /// blocking); the row shows "creating your login" while it does.
    @MainActor
    private func applyPendingFirstLogin(machineID id: UUID) {
        guard let creds = pendingFirstLogin[id],
              let m = registry?.machine(id), let os = m.os else { return }
        pendingFirstLogin[id] = nil
        applyingLogin.insert(id)
        refreshMachines()

        let host = "127.0.0.1"
        let port = m.resolvedPorts.helios
        let secret = heliosSecret(host: host, user: m.user, port: port)
        let hash = UserAdmin.desHash(password: creds.password)
        let req = UserAdmin.AddRequest(name: creds.user, hash: hash)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Void, Error>
            // The wizard's optional DNS choice rides the same ready window.
            // Its failure is deliberately soft: the login is the product of
            // this pipeline, DNS is a preference -- report, don't fail.
            var dnsFailure: String?
            let client = HeliosClient(host: host, port: port, timeout: 60, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.hello()
                _ = try UserAdmin.addUser(req, os: os, transport: client)
                if let dns = creds.dns, !dns.isEmpty {
                    do {
                        let payload = Data("nameserver \(dns)\n".utf8)
                        _ = try client.writeFile("/etc/resolv.conf", data: payload)
                    } catch {
                        dnsFailure = Self.describeUserAdminError(error)
                    }
                }
                outcome = .success(())
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyingLogin.remove(id)
                switch outcome {
                case .success:
                    // Adopt the new account as the machine's launcher login
                    // (sets machine.user + telnet Keychain). Launchers go live.
                    self.adoptMachineLogin(machineID: id, user: creds.user,
                                           password: creds.password)
                    if let dnsFailure {
                        let alert = NSAlert()
                        alert.messageText = "DNS wasn\u{2019}t set"
                        alert.informativeText = "Your login was created and the "
                            + "machine is running, but writing the DNS server "
                            + "failed: \(dnsFailure)\n\nIt can be set from the "
                            + "DNS panel (Overview \u{2192} DNS)."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                case .failure(let error):
                    self.refreshMachines()
                    // The guest is up; only the account write failed. Offer the
                    // Users panel as the retry path.
                    let alert = NSAlert()
                    alert.messageText = "Couldn\u{2019}t create the login"
                    alert.informativeText = "The machine is running, but adding "
                        + "\u{201C}\(creds.user)\u{201D} failed: "
                        + Self.describeUserAdminError(error)
                        + "\n\nYou can try again from the Users panel "
                        + "(Overview \u{2192} Users)."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    nonisolated private static func describeUserAdminError(_ error: Error) -> String {
        if let e = error as? UserAdminError { return e.errorDescription ?? "\(e)" }
        if let e = error as? HeliosClient.HeliosError { return e.errorDescription ?? "\(e)" }
        return error.localizedDescription
    }

    /// The Machines menu and its submenus compute enablement explicitly at build
    /// time (auto-enable off), so they don't route through here. Everything else
    /// (App-menu actions, standard responder-chain items) is always valid.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
