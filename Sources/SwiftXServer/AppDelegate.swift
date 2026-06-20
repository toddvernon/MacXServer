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
    private var fontMappingsController: FontMappingsWindowController?
    private var launchersController: LaunchersWindowController?
    /// Open capture-viewer windows. The viewer supports multiple windows so
    /// several captures can be compared; each removes itself here on close.
    private var captureViewers: [CaptureViewerWindowController] = []
    private var currentLauncherFile: LauncherFile?
    private var launchersMenu: NSMenu?
    private var activeLauncher: RemoteLauncher?
    private var progressController: LaunchProgressWindowController?

    /// The bundled SPARCstation engine controller, and its console window.
    /// Created once at launch; the engine doesn't run until "Run SPARCstation".
    private var qemuEngine: QemuEngine?
    private var sparcConsole: SparcPlugConsoleWindowController?
    private var sparcWelcome: SparcStationWelcomeWindowController?
    /// Retains a best-effort telnet "shut down the orphan" attempt for its
    /// lifetime; cleared when the attempt resolves.
    private var sparcTelnetShutdown: TelnetLauncher?

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
        installStatusItem()
        installMainMenu()
        setupSparcEngine()
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
                guard let self = self, self.qemuEngine?.state != .running else { return }
                self.rebuildSparcEngine()
            }
        }
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
        let engine = QemuEngine(config: makeSparcConfig())
        engine.onConsole { [weak self] text in
            self?.sparcConsole?.appendConsole(text)
        }
        engine.onStateChange { [weak self] state in
            self?.sparcConsole?.setState(state)
            // Keep the Preferences "restart to apply" note in sync if the
            // window is open. Running or shutting-down both mean a shared-
            // folder change can't take effect until the next clean start.
            self?.prefsController?.setSparcEngineRunning(
                state == .running || state == .shuttingDown)
        }
        engine.onCleanHalt { [weak self] in
            self?.sparcConsole?.markCleanHalt()
        }
        engine.onProgress { [weak self] value in
            self?.sparcConsole?.setProgress(value)
        }
        engine.onTerminated { [weak self] wasCleanHalt in
            self?.autoBackupAfterCleanShutdown(wasCleanHalt: wasCleanHalt)
        }
        self.qemuEngine = engine
        self.sparcConsole?.setState(engine.state)
    }

    /// Returns false so the status-bar app keeps running with no X windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Status-bar app — keep running after the last X window closes so
        // we can accept a fresh client connection without relaunching.
        false
    }

    /// Don't let the user quit macXserver out from under a running
    /// SPARCstation -- that would either orphan qemu or pull the power on
    /// Solaris (fsck on next boot). Refuse the quit and point them at the
    /// console, where they can Shut Down cleanly, then quit again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = qemuEngine,
              engine.state == .running || engine.state == .shuttingDown else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Shut down the SPARCstation first"
        alert.informativeText = "The SPARCstation is still running. Shut it down from its console "
            + "so Solaris can sync its disk, then quit macXserver. Quitting now could leave the "
            + "disk image needing a repair on next boot."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Go to Console")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            ensureSparcConsole()
            sparcConsole?.showWindow()
        }
        return .terminateCancel
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
        // no separate Install item. Start is enabled whenever not running;
        // Stop when running.
        let sparcMenuItem = NSMenuItem()
        let sparcMenu = NSMenu(title: "SPARCstation")
        let start = NSMenuItem(title: "Start SPARCstation",
                               action: #selector(startSparcStation(_:)), keyEquivalent: "")
        start.target = self
        sparcMenu.addItem(start)
        let shutDown = NSMenuItem(title: "Shut Down SPARCstation",
                                  action: #selector(shutDownSparcStation(_:)), keyEquivalent: "")
        shutDown.target = self
        sparcMenu.addItem(shutDown)
        sparcMenu.addItem(.separator())
        let showConsole = NSMenuItem(title: "Show Console",
                                     action: #selector(showSparcConsole(_:)), keyEquivalent: "")
        showConsole.target = self
        sparcMenu.addItem(showConsole)
        let backup = NSMenuItem(title: "Back Up Disk Image\u{2026}",
                                action: #selector(backUpDiskImage(_:)), keyEquivalent: "")
        backup.target = self
        sparcMenu.addItem(backup)
        sparcMenuItem.submenu = sparcMenu
        main.addItem(sparcMenuItem)

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
        // Seed the "restart to apply" note with the current engine state
        // before showing, so it's correct the instant the window appears.
        let state = qemuEngine?.state
        prefsController?.setSparcEngineRunning(state == .running || state == .shuttingDown)
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
        let item = NSMenuItem(title: entry.name,
                              action: #selector(launchRemoteApp(_:)),
                              keyEquivalent: "")
        item.target = self
        // group/name disambiguates same-named items across hosts
        // ("xterm cyan" can live under both u5 and ss2).
        item.representedObject = "\(entry.group)/\(entry.name)" as NSString
        return item
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
        // ssh path is keys-only: no password prompt, no Keychain lookup.
        // The launcher's password field (if set) is ignored for ssh entries.
        if entry.transport == .ssh {
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
                onShutDown: { [weak self] in self?.qemuEngine?.shutDown() },
                onForceQuit: { [weak self] in self?.confirmForceQuit() }
            )
            console.setState(qemuEngine?.state ?? .stopped)
            sparcConsole = console
        }
    }

    @MainActor
    @objc private func startSparcStation(_ sender: Any?) {
        guard let engine = qemuEngine else { return }
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
        qemuEngine?.shutDown()
    }

    @MainActor
    private func confirmForceQuit() {
        let alert = NSAlert()
        alert.messageText = "Force quit the SPARCstation?"
        alert.informativeText = "This pulls the power without a clean shutdown, like yanking the "
            + "cord. Solaris will run fsck on the next boot. Use this only if a graceful shut down "
            + "won't complete."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            qemuEngine?.kill()
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

    /// Actually boot the engine and bring up the console. Assumes the image is
    /// set and the lock is clear.
    private func proceedSparcLaunch() {
        ensureSparcConsole()
        sparcConsole?.showWindow()
        do {
            try qemuEngine?.start()
        } catch {
            showLaunchError("Couldn't start SPARCstation: \(error.localizedDescription)")
        }
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
        case .alertFirstButtonReturn:  attemptTelnetShutdown(lock: lock, image: image)
        case .alertSecondButtonReturn: forceQuitOrphan(lock: lock, image: image)
        case .alertThirdButtonReturn:  showManualShutdownInstructions()
        default: break
        }
    }

    /// SIGKILL the orphan, but only after re-verifying it's still our qemu
    /// (so a recycled pid is never killed). Then clear the lock and boot.
    private func forceQuitOrphan(lock: ImageLock, image: URL) {
        if ImageLockManager.isProcessAlive(lock.pid),
           ImageLockManager.processIsOurQemu(lock.pid) {
            kill(lock.pid, SIGKILL)
        }
        // Give it a beat to die, then clear the (now-stale) lock and launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            ImageLockManager.forceRemove(imageURL: image)
            self?.proceedSparcLaunch()
        }
    }

    /// Best-effort: telnet the orphan over the 2123 hostfwd and send `init 5`,
    /// then poll for the pid to die. No guarantee — root-over-telnet may be
    /// refused, etc. On timeout, fall back to manual instructions.
    private func attemptTelnetShutdown(lock: ImageLock, image: URL) {
        let entry = LauncherEntry(
            name: "SPARCstation shutdown", group: "", host: "127.0.0.1",
            command: "/usr/sbin/init 5", user: "root",
            port: QemuEngine.telnetHostPort, verbose: false,
            shellPrompt: "#", password: nil, transport: .telnet, display: "")
        let launcher = TelnetLauncher(entry: entry, password: "", displayString: "")
        sparcTelnetShutdown = launcher
        // Success is measured by the pid dying, not the launcher's result
        // (after `init 5` there's no shell prompt to return to).
        launcher.launch { _ in }
        pollOrphanDeath(lock: lock, image: image, deadline: Date().addingTimeInterval(35))
    }

    private func pollOrphanDeath(lock: ImageLock, image: URL, deadline: Date) {
        if !ImageLockManager.isProcessAlive(lock.pid) {
            sparcTelnetShutdown?.cancel(); sparcTelnetShutdown = nil
            ImageLockManager.forceRemove(imageURL: image)
            proceedSparcLaunch()
            return
        }
        if Date() >= deadline {
            sparcTelnetShutdown?.cancel(); sparcTelnetShutdown = nil
            showManualShutdownInstructions()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.pollOrphanDeath(lock: lock, image: image, deadline: deadline)
        }
    }

    private func showManualShutdownInstructions() {
        let alert = NSAlert()
        alert.messageText = "Shut down the running SPARCstation by hand"
        alert.informativeText =
            "In Terminal, connect to the running guest and halt it:\n\n"
            + "    telnet 127.0.0.1 \(QemuEngine.telnetHostPort)\n"
            + "    (log in, then as root:)\n"
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
    /// Stop only while running. Other items fall through to enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state = qemuEngine?.state ?? .notInstalled
        switch item.action {
        case #selector(startSparcStation(_:)):    return state == .stopped || state == .notInstalled
        case #selector(shutDownSparcStation(_:)): return state == .running
        case #selector(showSparcConsole(_:)):     return sparcConsole != nil
        case #selector(backUpDiskImage(_:)):      return state == .stopped
        default: return true
        }
    }
}

extension Notification.Name {
    static let launchersFileDidChange = Notification.Name("SwiftXLaunchersFileDidChange")
}
