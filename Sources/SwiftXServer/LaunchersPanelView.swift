import SwiftUI
import AppKit
import SwiftXServerCore

struct LaunchersPanelView: View {

    @StateObject private var model: LaunchersPanelModel
    @State private var showingRevertConfirm = false

    init(path: String = LauncherFileLoader.defaultPath) {
        _model = StateObject(wrappedValue: LaunchersPanelModel(path: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CodeEditorView(
                text: $model.text,
                theme: .dark,
                makeHighlighter: { theme, font in
                    LauncherSyntaxHighlighter(theme: theme, baseFont: font)
                }
            )
            .frame(minHeight: 280)
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 600, minHeight: 420)
        .onAppear { model.loadFromDisk() }
        .alert("Revert to bundled defaults?", isPresented: $showingRevertConfirm) {
            Button("Revert", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This replaces \(model.path) with the bundled seed content (commented-out examples).")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Launchers")
                    .font(.title2)
                Text("One-click launch of X apps on remote machines via telnet. Passwords stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Revert to Defaults") { showingRevertConfirm = true }
            Spacer()
            Button("Reload from Disk") { model.loadFromDisk() }
            Button("Save") { model.saveToDisk() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
        }
    }

    private var bannerRow: some View {
        Text(model.banner.isEmpty ? " " : model.banner)
            .font(.caption)
            .foregroundStyle(model.bannerIsError ? .red : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class LaunchersPanelModel: ObservableObject {

    let path: String

    @Published var text: String = "" {
        didSet { if !suppressDirty { dirty = true } }
    }
    @Published var dirty: Bool = false
    @Published var banner: String = ""
    @Published var bannerIsError: Bool = false

    private var suppressDirty = false

    init(path: String) { self.path = path }

    func loadFromDisk() {
        let content: String
        if FileManager.default.fileExists(atPath: path) {
            do {
                content = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                setBanner("Could not read \(path): \(error.localizedDescription)", error: true)
                return
            }
        } else {
            content = DefaultLaunchers.seedContent
        }
        suppressDirty = true
        text = content
        suppressDirty = false
        dirty = false
        setBanner("", error: false)
    }

    func saveToDisk() {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            dirty = false
            NotificationCenter.default.post(name: .launchersFileDidChange, object: nil)
            setBanner("Saved. Launchers menu updated.", error: false)
        } catch {
            setBanner("Save failed: \(error.localizedDescription)", error: true)
        }
    }

    func revert() {
        do {
            try DefaultLaunchers.seedContent.write(toFile: path, atomically: true, encoding: .utf8)
            loadFromDisk()
            NotificationCenter.default.post(name: .launchersFileDidChange, object: nil)
            setBanner("Reverted to bundled defaults.", error: false)
        } catch {
            setBanner("Revert failed: \(error.localizedDescription)", error: true)
        }
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }
}
