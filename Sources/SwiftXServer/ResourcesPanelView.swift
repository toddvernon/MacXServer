import SwiftUI
import AppKit
import SwiftXServerCore

// SwiftUI root for the resources editor panel. Layout follows the
// Covey hero-panel vocabulary: SF Symbol header, .title2 title,
// secondary caption, content area, action row at the bottom with the
// default action on the right. The editor itself (CodeEditorView) is
// the dark Xcode-style code editor described in THEMES.md.

struct ResourcesPanelView: View {

    @StateObject private var model: ResourcesPanelModel
    @State private var showingRevertConfirm = false

    init(path: String = ResourceFileLoader.defaultPath) {
        _model = StateObject(wrappedValue: ResourcesPanelModel(path: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            themeRow
            CodeEditorView(
                text: $model.text,
                theme: .dark,
                makeHighlighter: { theme, font in
                    ResourceSyntaxHighlighter(theme: theme, baseFont: font)
                }
            )
            .frame(minHeight: 320)
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { model.loadFromDisk() }
        .alert("Revert to bundled defaults?", isPresented: $showingRevertConfirm) {
            Button("Revert", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This replaces the contents of \(model.path) with the bundled seed content. Any edits you've made are lost.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "paintpalette")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resources")
                    .font(.title2)
                Text("Edit X resources and themes published as RESOURCE_MANAGER.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Theme picker

    private var themeRow: some View {
        HStack(spacing: 10) {
            Text("Active theme:")
                .foregroundStyle(.secondary)
            Picker("", selection: $model.activeTheme) {
                if model.themeNames.isEmpty {
                    Text("(no themes defined)").tag("")
                } else {
                    ForEach(model.themeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(model.themeNames.isEmpty)
            .frame(maxWidth: 220, alignment: .leading)
            Spacer()
        }
    }

    // MARK: - Action row

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

    // MARK: - Banner

    private var bannerRow: some View {
        Text(model.banner.isEmpty ? " " : model.banner)
            .font(.caption)
            .foregroundStyle(model.bannerIsError ? .red : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - View model

@MainActor
final class ResourcesPanelModel: ObservableObject {

    let path: String

    @Published var text: String = "" {
        didSet {
            // Any buffer change beyond the initial load is user-driven.
            if !suppressDirty { dirty = true }
            // Re-derive theme list from the live buffer so the picker
            // stays in sync if the user types a new [theme:X] section.
            refreshThemeMetadata()
        }
    }
    @Published var dirty: Bool = false
    @Published var banner: String = ""
    @Published var bannerIsError: Bool = false
    @Published var themeNames: [String] = []
    @Published var activeTheme: String = "" {
        didSet {
            // Triggered both by SwiftUI (user picked a different theme
            // in the dropdown) and by refreshThemeMetadata writing the
            // parsed value back into us. Only rewrite the buffer when
            // the new value really differs from what's already in the
            // file's [swiftx-config].theme line.
            if syncingFromBuffer { return }
            let newText = ResourcesPanelModel.replaceThemeLine(in: text, with: activeTheme)
            if newText != text {
                text = newText
            }
        }
    }

    // Internal flags to break feedback loops between the published
    // text, the published activeTheme, and the dirty flag.
    private var suppressDirty = false
    private var syncingFromBuffer = false

    init(path: String) {
        self.path = path
    }

    // MARK: - File I/O

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
            content = DefaultThemes.seedContent
        }
        suppressDirty = true
        text = content
        suppressDirty = false
        // Loaded-from-disk state is clean; revert/seed-on-first-open
        // both leave dirty=false too (user explicitly chose to load).
        dirty = false
        setBanner("", error: false)
    }

    func saveToDisk() {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            dirty = false
            setBanner("Saved. Restart Motif apps to see changes — toolkits cache resources at connect time.", error: false)
        } catch {
            setBanner("Save failed: \(error.localizedDescription)", error: true)
        }
    }

    func revert() {
        do {
            try DefaultThemes.seedContent.write(toFile: path, atomically: true, encoding: .utf8)
            loadFromDisk()
            setBanner("Reverted to bundled defaults.", error: false)
        } catch {
            setBanner("Revert failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Theme metadata

    private func refreshThemeMetadata() {
        let parsed = ResourceFile.parse(text)
        themeNames = parsed.themeNames
        let active = parsed.activeTheme
        if activeTheme != active {
            syncingFromBuffer = true
            activeTheme = active
            syncingFromBuffer = false
        }
        if !themeNames.isEmpty && !themeNames.contains(active) {
            setBanner("Active theme '\(active)' is not defined in the file.", error: true)
        }
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }

    // MARK: - Theme line rewrite

    /// Same byte-preserving rewrite the old AppKit controller used:
    /// find `theme:` inside `[swiftx-config]` and replace its value;
    /// if no theme line exists, insert one in the config section;
    /// if no config section, prepend one at the top.
    static func replaceThemeLine(in text: String, with newTheme: String) -> String {
        if newTheme.isEmpty { return text }
        var lines = text.components(separatedBy: "\n")
        var inConfigSection = false
        var sawConfigSection = false
        var configSectionLastLine = -1
        var changed = false

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inConfigSection = (trimmed == "[swiftx-config]")
                if inConfigSection { sawConfigSection = true }
                continue
            }
            if inConfigSection {
                configSectionLastLine = i
                if !changed, let colon = trimmed.firstIndex(of: ":") {
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    if key == "theme" {
                        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
                        lines[i] = "\(leading)theme: \(newTheme)"
                        changed = true
                    }
                }
            }
        }
        if changed { return lines.joined(separator: "\n") }

        if sawConfigSection, configSectionLastLine >= 0 {
            lines.insert("theme: \(newTheme)", at: configSectionLastLine + 1)
            return lines.joined(separator: "\n")
        }

        let prefix = ["[swiftx-config]", "theme: \(newTheme)", ""]
        return (prefix + lines).joined(separator: "\n")
    }
}
