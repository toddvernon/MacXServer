import SwiftUI
import AppKit
import SwiftXServerCore

// Backing model for the SPARCstation "Config" windows (Disk Image, Shared
// Folder, Claude Development). These settings used to live in a single
// Preferences tab; they're now broken out into their own menu-driven windows
// under SPARCstation > Config. All writes still flow through the shared,
// UserDefaults-backed Preferences object, so the values are the same ones the
// engine reads at launch -- this just owns the SPARCstation slice of them.
//
// One model instance is shared by all three Config windows (held by the
// AppDelegate), so whichever windows are open stay consistent.

@MainActor
final class SparcConfigModel: ObservableObject {

    private let prefs: Preferences

    /// Live mirror of whether the engine is running (or shutting down). The
    /// Shared Folder window uses it to show a "restart to apply" note, since
    /// the shared folder is only read when the engine launches. Pushed in by
    /// the AppDelegate's engine-state observer.
    @Published var sparcEngineRunning: Bool

    @Published var sparcDiskImagePath: String {
        didSet {
            if sparcDiskImagePath != prefs.sparcDiskImagePath {
                prefs.sparcDiskImagePath = sparcDiskImagePath
            }
        }
    }

    @Published var sparcAutoBackupOnShutdown: Bool {
        didSet {
            if sparcAutoBackupOnShutdown != prefs.sparcAutoBackupOnShutdown {
                prefs.sparcAutoBackupOnShutdown = sparcAutoBackupOnShutdown
            }
        }
    }

    @Published var sparcClaudeDevelopment: Bool {
        didSet {
            if sparcClaudeDevelopment != prefs.sparcClaudeDevelopment {
                prefs.sparcClaudeDevelopment = sparcClaudeDevelopment
            }
        }
    }

    @Published var sparcTftpEnabled: Bool {
        didSet {
            if sparcTftpEnabled != prefs.sparcTftpEnabled {
                prefs.sparcTftpEnabled = sparcTftpEnabled
                // Create the folder the moment the feature is enabled so
                // "Reveal in Finder" works immediately and slirp has a dir to
                // serve on the next Run.
                if sparcTftpEnabled { ensureSparcTftpDirectoryExists() }
            }
        }
    }

    @Published var sparcTftpDirectory: String {
        didSet {
            if sparcTftpDirectory != prefs.sparcTftpDirectory {
                prefs.sparcTftpDirectory = sparcTftpDirectory
            }
        }
    }

    init(preferences: Preferences, engineRunning: Bool) {
        self.prefs = preferences
        self.sparcEngineRunning = engineRunning
        self.sparcDiskImagePath = preferences.sparcDiskImagePath
        self.sparcAutoBackupOnShutdown = preferences.sparcAutoBackupOnShutdown
        self.sparcClaudeDevelopment = preferences.sparcClaudeDevelopment
        self.sparcTftpEnabled = preferences.sparcTftpEnabled
        self.sparcTftpDirectory = preferences.sparcTftpDirectory
    }

    // MARK: - Disk image

    /// Pick a Solaris disk image with an open panel and store its path.
    func chooseSparcDiskImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Solaris Disk Image"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !sparcDiskImagePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: sparcDiskImagePath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sparcDiskImagePath = url.path
    }

    /// Reveal the selected disk image in Finder.
    func revealSparcDiskImage() {
        guard !sparcDiskImagePath.isEmpty else { return }
        NSWorkspace.shared.selectFile(sparcDiskImagePath, inFileViewerRootedAtPath: "")
    }

    // MARK: - Shared folder (TFTP)

    /// Pick the shared (TFTP) folder with an open panel.
    func chooseSparcTftpDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Shared Folder"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        let current = (sparcTftpDirectory as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sparcTftpDirectory = url.path
        ensureSparcTftpDirectoryExists()
    }

    /// Reveal the shared folder in Finder, creating it first so the reveal
    /// always succeeds (same pattern as the captures folder).
    func revealSparcTftpDirectory() {
        ensureSparcTftpDirectoryExists()
        let path = (sparcTftpDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// `mkdir -p` the shared folder. Best-effort: slirp serves it read-only
    /// and won't create it, so we create it on enable / choose / reveal.
    func ensureSparcTftpDirectoryExists() {
        let path = (sparcTftpDirectory as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }
}
