import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftXServerCore

// The view model behind the Helios file browser (the per-launcher "Files…"
// item). It browses a SPARCstation user's filesystem over the Helios daemon and
// moves files to/from the Mac. Same I/O shape as DnsAdminPanelModel: each op
// runs on a global queue with its own short-lived HeliosClient (the client is
// blocking + one-request-in-flight, never shared across threads) and hops back
// to the main actor; `busy` serializes the UI-driven ops so two can't overlap.
//
// Everything runs AS the launcher's `user`: the daemon (root) drops privileges
// per request, so the listing is the user's own view and an uploaded file lands
// owned by the user, not root. The drag-out download runs in Finder's
// file-promise callback (already off-main) with its own client, independent of
// `busy`.

/// Connection + identity for one browser window, taken from the launcher entry.
struct HeliosFileBrowserConfig {
    let host: String
    let port: UInt16
    let user: String
    let label: String
    /// Read live on each call so a stop/start (which rotates the per-launch
    /// secret) doesn't strand the window.
    let secretProvider: () -> String?
}

@MainActor
final class FileBrowserPanelModel: ObservableObject {

    @Published var path: String = ""
    @Published var entries: [DirEntry] = []
    @Published var busy = false
    @Published var banner = ""
    @Published var bannerIsError = false
    @Published var dropTargeted = false

    let config: HeliosFileBrowserConfig

    /// True once at least one successful listing has loaded, so the view can
    /// distinguish "still resolving home" from "an empty directory".
    @Published private(set) var hasLoaded = false

    init(config: HeliosFileBrowserConfig) {
        self.config = config
    }

    /// `..` is offered whenever we're not at the filesystem root.
    var canGoUp: Bool { path != "/" && !path.isEmpty }

    // MARK: - Navigation

    /// First load: resolve the user's home directory (the daemon sets HOME in
    /// the run-as environment), then list it. Falls back to "/" if the lookup
    /// comes back empty.
    func start() {
        guard !busy else { return }
        busy = true
        setBanner("Connecting to the SPARCstation\u{2026}", error: false)
        let cfg = config
        let secret = cfg.secretProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var home = "/"
            let client = HeliosClient(host: cfg.host, port: cfg.port, timeout: 30, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                let r = try client.runCommand("echo $HOME", user: cfg.user)
                let trimmed = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/") { home = trimmed }
            } catch {
                // fall through with home = "/"; the load below reports any error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.load(home)
            }
        }
    }

    /// List `newPath` and make it the current directory on success. A failure
    /// (permission denied, gone) leaves the current view intact and banners.
    func load(_ newPath: String) {
        guard !busy else { return }
        busy = true
        setBanner("Reading \(newPath)\u{2026}", error: false)
        let cfg = config
        let secret = cfg.secretProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[DirEntry], Error>
            let client = HeliosClient(host: cfg.host, port: cfg.port, timeout: 30, secret: secret)
            defer { client.close() }
            do {
                let list = try { () throws -> ListResult in
                    try client.connect()
                    return try client.listDir(newPath, user: cfg.user)
                }()
                outcome = .success(Self.sorted(list.entries))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let sorted):
                    self.path = newPath
                    self.entries = sorted
                    self.hasLoaded = true
                    self.setBanner("\(newPath) \u{2014} \(sorted.count) item\(sorted.count == 1 ? "" : "s")", error: false)
                case .failure(let error):
                    self.setBanner("Couldn\u{2019}t open \(newPath): \(Self.describe(error))", error: true)
                }
            }
        }
    }

    func enter(_ entry: DirEntry) {
        guard entry.type == "dir" else { return }
        load(Self.join(path, entry.name))
    }

    func goUp() {
        guard canGoUp else { return }
        load(Self.parent(of: path))
    }

    func reload() { load(path) }

    // MARK: - Drag OUT (download to Finder)

    /// Build the file-promise the view hands to Finder when a row is dragged
    /// out. The download runs lazily, off-main, when Finder asks for the bytes
    /// (its own short-lived client, so it never touches `busy` or the shared
    /// connection). A regular file only; directories aren't draggable in v1.
    func dragProvider(for entry: DirEntry) -> NSItemProvider? {
        guard entry.type == "file" else { return nil }
        let cfg = config
        let secret = cfg.secretProvider()
        let remotePath = Self.join(path, entry.name)
        let filename = entry.name

        let provider = NSItemProvider()
        provider.suggestedName = filename
        provider.registerFileRepresentation(forTypeIdentifier: "public.data",
                                             fileOptions: [],
                                             visibility: .all) { completion in
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("helios-files-\(UUID().uuidString)")
            let dest = tmpDir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let client = HeliosClient(host: cfg.host, port: cfg.port, timeout: 600, secret: secret)
                defer { client.close() }
                try client.connect()
                _ = try client.getFile(remotePath, toLocalURL: dest, user: cfg.user)
                completion(dest, true, nil)
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    // MARK: - Drag IN (upload from Finder)

    /// Handle a Finder drop: resolve each provider to a local file URL, then
    /// upload them all into the current directory over one connection and
    /// reload. Skips while busy so a drop can't race a navigation.
    func handleDrop(_ providers: [NSItemProvider]) {
        guard !busy else { return }
        busy = true
        setBanner("Receiving dropped file\(providers.count == 1 ? "" : "s")\u{2026}", error: false)

        // A Finder file drop delivers each URL as a Data representation under
        // public.file-url; decode it back to a URL (loadObject(ofClass: URL.self)
        // isn't supported -- URL isn't NSItemProviderReading).
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        let typeID = UTType.fileURL.identifier
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.uploadAll(urls)
        }
    }

    private enum OverwriteChoice { case replace, skipExisting, cancel }

    /// Upload `urls` into `path` (one client, sequential), then reload. `busy`
    /// is already set by handleDrop; this clears it. Unlike a download (where
    /// Finder prompts before replacing), the remote side has no UI, so we warn
    /// here before overwriting -- checking the names against the current listing
    /// already in memory, no extra round-trip.
    private func uploadAll(_ urls: [URL]) {
        guard !urls.isEmpty else {
            busy = false
            setBanner("Nothing to upload (no files in the drop).", error: true)
            return
        }

        // Pair each dropped file with the Solaris-safe name it'll land under, so
        // the conflict check and the upload both use the real on-box name.
        let targets = urls.map { (url: $0, name: SolarisFilename.sanitize($0.lastPathComponent)) }

        let existing = Set(entries.map { $0.name })
        let conflicts = targets.filter { existing.contains($0.name) }
        var toUpload = targets
        if !conflicts.isEmpty {
            switch confirmOverwrite(conflictNames: conflicts.map { $0.name },
                                    total: targets.count) {
            case .cancel:
                busy = false
                setBanner("Upload cancelled \u{2014} kept the existing file\(conflicts.count == 1 ? "" : "s").", error: false)
                return
            case .replace:
                break   // upload everything, overwriting in place
            case .skipExisting:
                toUpload = targets.filter { !existing.contains($0.name) }
                if toUpload.isEmpty {
                    busy = false
                    setBanner("Nothing to upload \u{2014} all \(conflicts.count) already exist.", error: false)
                    return
                }
            }
        }

        let cfg = config
        let secret = cfg.secretProvider()
        let destDir = path
        let items = toUpload
        let renamed = items.filter { $0.url.lastPathComponent != $0.name }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var uploaded = 0
            var failure: String?
            let client = HeliosClient(host: cfg.host, port: cfg.port, timeout: 600, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                for item in items {
                    let accessing = item.url.startAccessingSecurityScopedResource()
                    defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }
                    let remote = Self.join(destDir, item.name)
                    _ = try client.putFile(fromLocalURL: item.url, toRemotePath: remote, user: cfg.user)
                    uploaded += 1
                }
            } catch {
                failure = Self.describe(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let failure {
                    self.setBanner("Uploaded \(uploaded) of \(items.count); stopped on: \(failure)", error: true)
                } else if uploaded == 1 && renamed.count == 1 {
                    // Single renamed file: show the mapping so the new name isn't a surprise.
                    self.setBanner("Uploaded \u{201C}\(items[0].url.lastPathComponent)\u{201D} as \u{201C}\(items[0].name)\u{201D}.", error: false)
                } else {
                    var msg = "Uploaded \(uploaded) file\(uploaded == 1 ? "" : "s") to \(destDir)."
                    if !renamed.isEmpty { msg += " Renamed \(renamed.count) for Solaris." }
                    self.setBanner(msg, error: false)
                }
                self.reload()
            }
        }
    }

    /// Warn before an upload overwrites existing remote files. "Skip Existing" is
    /// offered only when some of the dropped files are new (otherwise it's the
    /// same as Cancel). Runs modally on the main thread (the caller is on main).
    private func confirmOverwrite(conflictNames: [String], total: Int) -> OverwriteChoice {
        let n = conflictNames.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        if n == 1 {
            alert.messageText = "\u{201C}\(conflictNames[0])\u{201D} already exists in this folder"
            alert.informativeText = "Uploading it replaces the copy on the SPARCstation (\(path))."
        } else {
            let shown = conflictNames.prefix(8).joined(separator: ", ")
            let more = n > 8 ? ", \u{2026}" : ""
            alert.messageText = "\(n) items already exist in this folder"
            alert.informativeText = "These already exist in \(path) and would be replaced on the "
                + "SPARCstation:\n\n\(shown)\(more)"
        }
        alert.addButton(withTitle: "Replace")                       // first
        let hasNew = total > n
        if hasNew { alert.addButton(withTitle: "Skip Existing") }   // second (only if some are new)
        alert.addButton(withTitle: "Cancel")                        // second or third
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn { return .replace }
        if hasNew && resp == .alertSecondButtonReturn { return .skipExisting }
        return .cancel
    }

    // MARK: - Helpers

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }

    // These four are pure (no actor state), and load()/uploadAll() call them
    // from a background queue, so they must be `nonisolated` -- otherwise they
    // inherit the class's @MainActor isolation and tripping them off-main is a
    // hard `_dispatch_assert_queue_fail` crash (Swift 5 mode doesn't flag the
    // call at compile time; it only blows up at runtime).

    /// Directories first, then files; each group alphabetical, case-insensitive.
    nonisolated static func sorted(_ entries: [DirEntry]) -> [DirEntry] {
        entries.sorted { a, b in
            let aDir = (a.type == "dir"), bDir = (b.type == "dir")
            if aDir != bDir { return aDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Join a directory path and a child name with exactly one slash, handling
    /// the root case ("/" + "x" == "/x", not "//x").
    nonisolated static func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        return dir + "/" + name
    }

    /// The parent directory path; the root is its own parent.
    nonisolated static func parent(of dir: String) -> String {
        guard dir != "/", let slash = dir.lastIndex(of: "/") else { return "/" }
        let parent = String(dir[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? HeliosClient.HeliosError)?.errorDescription ?? error.localizedDescription
    }
}
