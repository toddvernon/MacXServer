import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftXServerCore

// The Helios file browser pane (the per-launcher "Files…" window). One remote
// pane: a list of the current directory on the SPARCstation, folder/doc icons,
// double-click to enter a folder or ".." to go up. Drag a file row out to
// Finder to download it; drag files in from Finder to upload them here. All I/O
// runs AS the launcher's user (see FileBrowserPanelModel). View/model/banner
// shape mirrors DnsAdminPanelView.

struct FileBrowserPanelView: View {

    @StateObject private var model: FileBrowserPanelModel

    init(config: HeliosFileBrowserConfig) {
        _model = StateObject(wrappedValue: FileBrowserPanelModel(config: config))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            fileList
            bannerRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 460, minHeight: 380)
        .onAppear { if !model.hasLoaded { model.start() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.config.label)
                    .font(.headline)
                Text(model.path.isEmpty ? "\u{2026}" : model.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.head)
                    .lineLimit(1)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Go up one folder")
            .disabled(!model.canGoUp || model.busy)
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload this folder")
            .disabled(model.busy || model.path.isEmpty)
        }
    }

    // MARK: - File list

    private var fileList: some View {
        List {
            if model.canGoUp {
                Button {
                    model.goUp()
                } label: {
                    rowContent(icon: "arrow.turn.left.up", iconColor: .secondary,
                               name: "..", detail: "parent folder", dimmed: true)
                }
                .buttonStyle(.plain)
            }
            ForEach(model.entries, id: \.name) { entry in
                row(for: entry)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { dropHighlight }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            model.handleDrop(providers)
            return true
        }
    }

    private func row(for entry: DirEntry) -> some View {
        let isDir = entry.type == "dir"
        return rowContent(icon: iconName(for: entry),
                          iconColor: isDir ? .accentColor : .secondary,
                          name: entry.name,
                          detail: detail(for: entry),
                          dimmed: false)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.enter(entry) }
            // Only regular files carry a real promise; dragging a folder is a no-op.
            .onDrag { model.dragProvider(for: entry) ?? NSItemProvider() }
    }

    private func rowContent(icon: String, iconColor: Color,
                            name: String, detail: String, dimmed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(iconColor)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dimmed ? .secondary : .primary)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: model.dropTargeted ? 2 : 0)
            .allowsHitTesting(false)
    }

    // MARK: - Banner

    private var bannerRow: some View {
        HStack {
            Text(model.banner.isEmpty ? " " : model.banner)
                .font(.caption)
                .foregroundStyle(model.bannerIsError ? .red : .secondary)
                .lineLimit(2)
            Spacer()
            Text("drag a file out to download \u{2022} drop files here to upload")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Presentation helpers

    private func iconName(for entry: DirEntry) -> String {
        switch entry.type {
        case "dir":     return "folder.fill"
        case "symlink": return "arrow.up.forward.square"
        case "file":    return "doc"
        default:        return "questionmark.square.dashed"
        }
    }

    private func detail(for entry: DirEntry) -> String {
        switch entry.type {
        case "dir":     return ""
        case "symlink": return "link"
        default:        return Self.humanSize(entry.size)
        }
    }

    static func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[i])
    }
}
