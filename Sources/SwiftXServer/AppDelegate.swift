import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {

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
    private var activeLauncher: TelnetLauncher?
    private var progressController: LaunchProgressWindowController?

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

    /// Builds the delegate and its `Preferences` instance.
    override init() {
        self.preferences = Preferences()
        super.init()
    }

    /// Thread-safe handle to the clipboard preferences for the listener thread.
    nonisolated var sharedPreferences: ClipboardPreferencesProvider { preferences }

    // MARK: - NSApplicationDelegate

    /// Installs the status-bar item and main menu, and starts watching the
    /// launchers file for changes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(launchersFileChanged(_:)),
            name: .launchersFileDidChange, object: nil
        )
    }

    /// Returns false so the status-bar app keeps running with no X windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Status-bar app — keep running after the last X window closes so
        // we can accept a fresh client connection without relaunching.
        false
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
        prefsController?.showWindow()
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
        // An explicit password in the launcher file wins (dev convenience —
        // skips the prompt every launch). Otherwise fall back to the Keychain,
        // prompting and storing on first use.
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
        let display = "\(advertisedHost):\(displayNumber)"
        let launcher = TelnetLauncher(entry: entry, password: password, displayString: display)
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
}

extension Notification.Name {
    static let launchersFileDidChange = Notification.Name("SwiftXLaunchersFileDidChange")
}
