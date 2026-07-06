import SwiftUI
import AppKit
import SwiftXServerCore

// Backing model for the engine-global Config windows -- since P2, just the
// Shared Folder (the per-machine Disk Image editor lives in the Machines
// window's Settings tab; the Claude Development secret-file toggle is retired,
// the image lock carries the secret). Writes flow through the shared,
// UserDefaults-backed Preferences object, so the values are the same ones the
// engine reads at launch.

@MainActor
final class SparcConfigModel: ObservableObject {

    private let prefs: Preferences

    /// Live mirror of whether ANY machine is running (or shutting down). The
    /// Shared Folder window uses it to show a "restart to apply" note, since
    /// the shared folder is only read when an engine launches. Pushed in by
    /// the AppDelegate's engine-state observers.
    @Published var sparcEngineRunning: Bool

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
        self.sparcTftpEnabled = preferences.sparcTftpEnabled
        self.sparcTftpDirectory = preferences.sparcTftpDirectory
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
