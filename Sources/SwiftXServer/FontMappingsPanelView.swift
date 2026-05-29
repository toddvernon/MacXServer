import SwiftUI
import AppKit
import SwiftXServerCore
import SwiftXCaptureUI

// SwiftUI root for the font mappings editor panel. Parallels
// ResourcesPanelView — same hero-panel layout (SF Symbol + title +
// caption, dark editor with gutter, action row with default Save) — but
// for `~/.swiftx-fonts` instead of `~/.swiftx-resources`. See
// DefaultFontMappings for the file format.

struct FontMappingsPanelView: View {

    @StateObject private var model: FontMappingsPanelModel
    @State private var showingRevertConfirm = false

    init(path: String = FontMappingFileLoader.defaultPath) {
        _model = StateObject(wrappedValue: FontMappingsPanelModel(path: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CodeEditorView(
                text: $model.text,
                theme: .dark,
                makeHighlighter: { theme, font in
                    FontMappingSyntaxHighlighter(theme: theme, baseFont: font)
                }
            )
            .frame(minHeight: 320)
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 640, minHeight: 480)
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
            Image(systemName: "textformat")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Font Mappings")
                    .font(.title2)
                Text("Map XLFD family names to Mac fonts. Used by FontResolver when an X client requests a font.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
final class FontMappingsPanelModel: ObservableObject {

    let path: String

    @Published var text: String = "" {
        didSet { if !suppressDirty { dirty = true } }
    }
    @Published var dirty: Bool = false
    @Published var banner: String = ""
    @Published var bannerIsError: Bool = false

    private var suppressDirty = false

    init(path: String) {
        self.path = path
    }

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
            content = DefaultFontMappings.seedContent
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
            // Push the new mappings into FontResolver so newly-launched
            // sessions pick them up without a server restart. Existing
            // X clients cache font metrics at QueryFont time and won't
            // re-query, hence the "restart apps" note.
            FontResolver.installMappings()
            setBanner("Saved. Restart Motif/dt apps to see changes — clients cache font metrics at QueryFont time.", error: false)
        } catch {
            setBanner("Save failed: \(error.localizedDescription)", error: true)
        }
    }

    func revert() {
        do {
            try DefaultFontMappings.seedContent.write(toFile: path, atomically: true, encoding: .utf8)
            loadFromDisk()
            FontResolver.installMappings()
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
