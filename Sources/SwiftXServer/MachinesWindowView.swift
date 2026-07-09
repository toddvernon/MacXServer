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
                List(selection: deferredSelection) {
                    machineSection("Bundled Machines", model.bundledMachines)
                    machineSection("Virtual Machines", model.virtualMachines)
                    machineSection("External Machines", model.externalMachines)
                }
                .listStyle(.sidebar)
            }
            Divider()
            toolbar
        }
    }

    /// The AppKit-backed List writes its selection binding from inside the
    /// view-update pass on row clicks (worse NSPanel-hosted), which trips
    /// "Publishing changes from within view updates is not allowed". Deferring
    /// the @Published write one runloop turn moves the publish outside the
    /// update transaction; the get side stays live.
    private var deferredSelection: Binding<UUID?> {
        Binding(get: { model.selection },
                set: { newValue in
                    DispatchQueue.main.async { model.selection = newValue }
                })
    }

    /// One titled section of the master list, or nothing when it's empty (so a
    /// section header never appears over zero rows).
    @ViewBuilder private func machineSection(_ title: String, _ items: [Machine]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { m in
                    MasterRow(machine: m, dot: model.row(m.id)?.dot ?? .stopped)
                        .tag(m.id)
                }
            }
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

    /// Bundled fixtures (the machines we ship) and any running machine can't be
    /// removed. Your own virtual and external machines delete freely when stopped.
    private var canRemoveSelection: Bool {
        guard let m = model.selectedMachine else { return false }
        return !m.bundled && !model.isRunning(m.id)
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

    var body: some View {
        HStack(spacing: 8) {
            StatusDotView(dot: dot, progress: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name.isEmpty ? "Untitled" : machine.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
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

/// The detail pane: a segmented Overview/Settings/Launchers switcher over the
/// three pages (Launchers split out 2026-07-09: operate / configure / commands
/// have different edit cadences, so they get different tabs -- same reasoning
/// as Xcode's target-editor tabs).
private struct MachineDetailContainer: View {
    let machine: Machine
    @ObservedObject var model: MachinesModel
    @State private var tab: DetailTab = .overview

    enum DetailTab: Hashable { case overview, settings, launchers }

    /// A VM with no disk image can't run, so its Overview is a dead end — open
    /// straight to Settings where the image gets set.
    private var defaultTab: DetailTab {
        (machine.kind == .emulatedVM && machine.image == nil) ? .settings : .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // The machine name outranks the blue section headers (title3),
                // so it gets title2.
                Text(machine.name.isEmpty ? "Untitled" : machine.name)
                    .font(.title2.weight(.semibold)).lineLimit(1)
                Spacer()
                Picker("", selection: $tab) {
                    Text("Overview").tag(DetailTab.overview)
                    Text("Settings").tag(DetailTab.settings)
                    Text("Launchers").tag(DetailTab.launchers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .overview:
                MachineOverviewPage(row: model.row(machine.id), model: model,
                                    onEditLaunchers: { tab = .launchers })
            case .settings:
                MachineDetailForm(machine: machine, model: model)
            case .launchers:
                MachineLaunchersForm(machine: machine, model: model)
            }
        }
        // Pick the starting tab per machine. Driven from the body (not @State init)
        // because this window is NSPanel-hosted, where @State-on-.id() reset is
        // unreliable. Fires only when the selected machine changes, so a manual
        // Overview/Settings click afterward sticks.
        .onChange(of: machine.id, initial: true) { tab = defaultTab }
    }
}

/// The Overview (operate) page: live status, lifecycle controls, and the machine's
/// launchers as buttons you click to *run*. Reads the computed `MachineRow` so it
/// gates exactly like the Machines menu.
private struct MachineOverviewPage: View {
    let row: MachineRow?
    @ObservedObject var model: MachinesModel
    /// Hops the detail pane to the Settings tab (the launcher byline's
    /// Edit link).
    let onEditLaunchers: () -> Void

    var body: some View {
        ScrollView {
            if let row {
                VStack(alignment: .leading, spacing: 16) {
                    statusLine(row)
                    bootBar(row)
                    lifecycle(row)
                    launchers(row)
                    adminAgents(row)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No status.").foregroundStyle(.secondary).padding(20)
            }
        }
    }

    /// No dot here (the master list carries it); the thermometer below is the
    /// Overview's state color.
    private func statusLine(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(row.statusText).font(.system(size: 15, weight: .medium))
                Spacer()
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            // Guest facts from the agent's sysinfo (present once the box has
            // answered a probe): uname, load, swap, disk fullness, clock drift.
            if let line = row.systemLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            factsLine(row)
        }
    }

    /// The assigned ports (+ MAC for emulated VMs) as a quiet reference line.
    /// Moved here from the Settings tab's read-only Runtime section
    /// (2026-07-09): they pair with the live system line above, and Settings
    /// now holds only things with an edit affordance (the ports editor).
    @ViewBuilder private func factsLine(_ row: MachineRow) -> some View {
        if let m = model.machines.first(where: { $0.id == row.id }) {
            let p = m.resolvedPorts
            let ports = "telnet \(String(p.telnet)) \u{00B7} ssh \(String(p.ssh)) "
                      + "\u{00B7} helios \(String(p.helios))"
            Text(row.isEmulated ? "\(ports) \u{00B7} MAC \(m.resolvedMacAddress)" : ports)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .help(row.isEmulated
                      ? "Assigned to this machine when it was created and never change, "
                      + "so scripts and tooling can rely on them. Ports are this Mac's "
                      + "forwards into the guest; MAC is the guest's network address. "
                      + "Override the ports in Settings if two machines collide."
                      : "The ports this Mac uses to reach the machine's telnet, SSH, "
                      + "and Helios agent. Change them in Settings if the machine "
                      + "listens somewhere unusual.")
        }
    }

    /// The boot/shutdown thermometer, mirroring the console window's bar: grows
    /// yellow through boot (matching the booting dot), pegs full and flips green
    /// once the guest is ready, recedes through shutdown, sits empty when
    /// stopped. Emulated machines only (an external host has no lifecycle we
    /// own).
    @ViewBuilder private func bootBar(_ row: MachineRow) -> some View {
        if row.isEmulated {
            let ready = (row.dot == .running)
            let accent: Color = ready ? .green : .yellow
            let fraction = row.progress ?? 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.15))
                    Group {
                        if ready || fraction <= 0 {
                            Capsule().fill(accent)
                        } else {
                            // In motion (booting or shutting down): animated
                            // barber pole instead of flat yellow.
                            BarberPoleFill(accent: accent)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .animation(.easeInOut(duration: 0.45), value: row.progress)
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
        }
        // (No else: an external host has no lifecycle we own, so its row shows
        // nothing -- which is truthful. The Helios Secret entry point moved to
        // Settings -> Connection 2026-07-09: a credential is a setting, and it
        // was only ever here because the lifecycle slot happened to be empty.)
    }

    @ViewBuilder private func launchers(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionHeader("X11 Launchers")
            // Content inset under the header, matching the Settings tab.
            VStack(alignment: .leading, spacing: 8) {
                if row.launchers.isEmpty {
                    editInLaunchersLine(prefix: "No launchers.")
                } else {
                    editInLaunchersLine(prefix: "Click to run.")
                    FlowLayout(spacing: 6) {
                        ForEach(row.launchers) { chip in
                            Button {
                                model.onLaunch?(row.id, chip.id, false)
                            } label: {
                                Label(chip.name, systemImage: "terminal")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!chip.enabled)
                            // Verbose is a launch gesture, not launcher config:
                            // right-click streams this one launch's transcript
                            // to a live progress window.
                            .contextMenu {
                                Button("Run with Progress Window") {
                                    model.onLaunch?(row.id, chip.id, true)
                                }
                                .disabled(!chip.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 16)
        }
    }

    /// Verbs that ride the box's Helios agent (File Transfer, DNS; more to
    /// come). File Transfer gates on `canFileTransfer` ("has helios" per the
    /// MachineRow doc: emulated = up and ready, external = a saved secret);
    /// DNS gates on `canDnsAdmin` (emulated, running and ready).
    private func adminAgents(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionHeader("Helios Admin Agents")
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6) {
                    Button {
                        model.onFileTransfer?(row.id)
                    } label: {
                        Label("File Transfer", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!row.canFileTransfer)
                    .help(row.canFileTransfer
                          ? "Browse and move files over the Helios agent"
                          : (row.isEmulated
                             ? "Available once the machine is running and ready"
                             : "Available once the machine answers a Helios check "
                             + "(set its Helios Secret in Settings if you haven't)"))

                    Button {
                        model.onDnsAdmin?(row.id)
                    } label: {
                        Label("DNS", systemImage: "network")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!row.canDnsAdmin)
                    .help(row.canDnsAdmin
                          ? "Edit the machine's DNS configuration (/etc/resolv.conf)"
                          : (row.isEmulated
                             ? "Available once the machine is running and ready"
                             : "Available once the machine answers a Helios check "
                             + "(set its Helios Secret in Settings if you haven't)"))
                }
            }
            .padding(.leading, 16)
        }
    }

    /// "<prefix> Edit in Launchers." with Edit as a blue link that hops the
    /// pane to the Launchers tab.
    private func editInLaunchersLine(prefix: String) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
            Button("Edit") { onEditLaunchers() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Text("in Launchers.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Section header shared by the Overview and Settings pages: larger than body
/// text, a darker blue than the system accent, with breathing room above so
/// the sections read at a glance (Todd's calls 2026-07-06 -- the .headline
/// versions disappeared into the form, plain .blue was too bright).
struct MachineSectionHeader: View {
    /// Dark enough to read as a label on light backgrounds, still legible in
    /// dark mode.
    static let color = Color(red: 0.08, green: 0.28, blue: 0.62)

    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Self.color)
            .padding(.top, 10)
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
            case .externalUp:
                Circle().fill(.green).frame(width: 10, height: 10)
            case .externalUnauthorized:
                Circle().fill(.orange).frame(width: 10, height: 10)
            case .externalDown:
                Circle().strokeBorder(.red, lineWidth: 1.5).frame(width: 10, height: 10)
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
        case .externalUp: return "External host, agent responding"
        case .externalUnauthorized: return "External host, agent refused the saved secret"
        case .externalDown: return "External host, not responding"
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
