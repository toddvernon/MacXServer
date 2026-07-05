import SwiftUI
import SwiftXServerCore

/// The Machines list window body: one row per machine, each with a status dot,
/// its lifecycle controls (bundled emulated VM only in P1), and its launcher
/// commands. This is the app's front door under the machine-manager reframe.
struct MachineListPanelView: View {
    @ObservedObject var model: MachineListModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            MachineRowView(row: row, model: model)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    private var header: some View {
        HStack {
            Text("Machines").font(.headline)
            Spacer()
            Button {
                model.onAddMachine?()
            } label: {
                Label("Add Machine", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No machines configured")
                .foregroundStyle(.secondary)
            Text("Add an emulated VM or an external host to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MachineRowView: View {
    let row: MachineRow
    @ObservedObject var model: MachineListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                StatusDotView(dot: row.dot, progress: row.progress)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 13, weight: .semibold))
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(row.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                lifecycleButtons
            }
            if !row.launchers.isEmpty {
                launcherChips
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var lifecycleButtons: some View {
        if row.showsLifecycle {
            HStack(spacing: 6) {
                if row.canShutDown || row.canForceQuit {
                    if row.canShutDown {
                        Button("Shut Down") { model.onShutDown?(row.id) }
                    }
                    if row.canForceQuit {
                        Button("Force Quit") { model.onForceQuit?(row.id) }
                    }
                } else {
                    Button("Start") { model.onStart?(row.id) }
                        .disabled(!row.canStart)
                }
                Button("Console") { model.onConsole?(row.id) }
                    .disabled(!row.canConsole)
                Button("Back Up") { model.onBackup?(row.id) }
                    .disabled(!row.canBackup)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var launcherChips: some View {
        // A simple wrapping row of launcher buttons.
        FlowLayout(spacing: 6) {
            ForEach(row.launchers) { chip in
                Button {
                    model.onLaunch?(row.id, chip.id)
                } label: {
                    Label(chip.name, systemImage: chip.isFileBrowser ? "folder" : "terminal")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!chip.enabled)
            }
        }
        .padding(.leading, 26)
    }
}

private struct StatusDotView: View {
    let dot: MachineStatusDot
    let progress: Double?

    var body: some View {
        ZStack {
            switch dot {
            case .running:
                Circle().fill(.green).frame(width: 10, height: 10)
            case .booting:
                Circle().fill(.yellow).frame(width: 10, height: 10)
            case .stopped:
                Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
            case .notInstalled:
                Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 10, height: 10)
            case .external:
                Circle().fill(.secondary).frame(width: 10, height: 10)
            }
        }
        .frame(width: 12, height: 12)
        .help(helpText)
    }

    private var helpText: String {
        switch dot {
        case .running: return "Running"
        case .booting: return "Booting"
        case .stopped: return "Stopped"
        case .notInstalled: return "Not installed"
        case .external: return "External host"
        }
    }
}

/// Minimal flow layout so launcher chips wrap to the next line. Avoids pulling in
/// any dependency; good enough for a handful of chips per machine.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
