import SwiftUI
import SwiftXServerCore

/// The unified Machines window: a master list of machines on the left, and a
/// per-machine detail pane on the right that switches between an **Overview** tab
/// (operate: status + lifecycle + run launchers) and a **Settings** tab (edit: the
/// config form). This is the app's front door under the machine-manager reframe.
/// Plain HSplitView (not NavigationSplitView) per the documented NSPanel gotcha.
struct MachinesWindowView: View {
    @ObservedObject var model: MachinesModel

    var body: some View {
        HSplitView {
            master
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: Master (machine list + add/remove/clone)

    private var master: some View {
        VStack(spacing: 0) {
            if model.machines.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.machines) { m in
                        MasterRow(machine: m,
                                  dot: model.row(m.id)?.dot ?? .stopped,
                                  bundled: model.isBundled(m.id))
                            .tag(m.id)
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            toolbar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No machines").foregroundStyle(.secondary)
            Text("Add one with +.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                if let id = model.onAddNew?() { model.selection = id }
            } label: { Image(systemName: "plus") }
                .help("Add a machine")

            Button {
                if let id = model.selection { model.onRemove?(id) }
            } label: { Image(systemName: "minus") }
                .help("Remove the selected machine")
                .disabled(!canRemoveSelection)

            Button {
                if let id = model.selection, let newID = model.onClone?(id) {
                    model.selection = newID
                }
            } label: { Image(systemName: "plus.square.on.square") }
                .help("Clone the selected machine (config + launchers, not the disk image)")
                .disabled(model.selection == nil)

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The bundled VM and any running machine can't be removed. (Stop it first;
    /// the bundled machine is load-bearing for the engine wiring.)
    private var canRemoveSelection: Bool {
        guard let id = model.selection else { return false }
        return !model.isBundled(id) && !model.isRunning(id)
    }

    // MARK: Detail (tabbed)

    @ViewBuilder private var detail: some View {
        if let machine = model.selectedMachine {
            MachineDetailContainer(machine: machine, model: model)
                .id(machine.id)     // reset the tab draft when the selection changes
        } else {
            VStack(spacing: 6) {
                Text("No machine selected").foregroundStyle(.secondary)
                Text("Select a machine, or add one with +.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One row in the master list: a status dot, the name, and a subtitle.
private struct MasterRow: View {
    let machine: Machine
    let dot: MachineStatusDot
    let bundled: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDotView(dot: dot, progress: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name.isEmpty ? "Untitled" : machine.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if bundled {
                Text("bundled").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch machine.kind {
        case .emulatedVM:   return machine.image?.lastPathComponent ?? "no disk image"
        case .externalHost: return machine.host.isEmpty ? "external" : "\(machine.host) · external"
        }
    }
}

/// The detail pane: a segmented Overview/Settings switcher over the two pages.
private struct MachineDetailContainer: View {
    let machine: Machine
    @ObservedObject var model: MachinesModel
    @State private var tab: DetailTab = .overview

    enum DetailTab: Hashable { case overview, settings }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(machine.name.isEmpty ? "Untitled" : machine.name)
                    .font(.headline).lineLimit(1)
                Spacer()
                Picker("", selection: $tab) {
                    Text("Overview").tag(DetailTab.overview)
                    Text("Settings").tag(DetailTab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .overview: MachineOverviewPage(row: model.row(machine.id), model: model)
            case .settings: MachineDetailForm(machine: machine, model: model)
            }
        }
    }
}

/// The Overview (operate) page: live status, lifecycle controls, and the machine's
/// launchers as buttons you click to *run*. Reads the computed `MachineRow` so it
/// gates exactly like the Machines menu.
private struct MachineOverviewPage: View {
    let row: MachineRow?
    @ObservedObject var model: MachinesModel

    var body: some View {
        ScrollView {
            if let row {
                VStack(alignment: .leading, spacing: 16) {
                    statusLine(row)
                    lifecycle(row)
                    launchers(row)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No status.").foregroundStyle(.secondary).padding(20)
            }
        }
    }

    private func statusLine(_ row: MachineRow) -> some View {
        HStack(spacing: 10) {
            StatusDotView(dot: row.dot, progress: row.progress)
            Text(row.statusText).font(.system(size: 15, weight: .medium))
            Spacer()
            Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private func lifecycle(_ row: MachineRow) -> some View {
        if row.showsLifecycle {
            HStack(spacing: 8) {
                if row.canShutDown || row.canForceQuit {
                    if row.canShutDown {
                        Button("Shut Down") { model.onShutDown?(row.id) }
                    }
                    if row.canForceQuit {
                        Button("Force Quit") { model.onForceQuit?(row.id) }
                    }
                } else {
                    Button("Start") { model.onStart?(row.id) }.disabled(!row.canStart)
                }
                Button("Console") { model.onConsole?(row.id) }.disabled(!row.canConsole)
                Button("Back Up") { model.onBackup?(row.id) }.disabled(!row.canBackup)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if row.canSetHeliosSecret {
            Button {
                model.onSetHeliosSecret?(row.id)
            } label: {
                Label("Helios Secret\u{2026}", systemImage: "key.fill")
            }
            .buttonStyle(.bordered)
            .help("Enter the Helios daemon secret for this host")
        }
    }

    @ViewBuilder private func launchers(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launchers").font(.headline)
            if row.launchers.isEmpty {
                Text("No launchers. Add them in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Click to run:").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(row.launchers) { chip in
                        Button {
                            model.onLaunch?(row.id, chip.id)
                        } label: {
                            Label(chip.name, systemImage: chip.isFileBrowser ? "folder" : "terminal")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!chip.enabled)
                    }
                }
            }
        }
    }
}

/// The colored state dot, shared by the master list and the Overview page.
struct StatusDotView: View {
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
struct FlowLayout: Layout {
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
