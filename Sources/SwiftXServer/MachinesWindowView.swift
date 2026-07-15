import SwiftUI
import SwiftXServerCore

/// The unified Machines window: a master list of machines on the left, and a
/// per-machine detail pane on the right that switches between an **Overview** tab
/// (operate: status + lifecycle + run launchers) and a **Settings** tab (edit: the
/// config form). This is the app's front door under the machine-manager reframe.
/// Plain HSplitView (not NavigationSplitView) per the documented NSPanel gotcha.
struct MachinesWindowView: View {
    @ObservedObject var model: MachinesModel
    /// The Add Machine wizard sheet (the + button's one and only add path).
    @State private var showingAddWizard = false

    var body: some View {
        HSplitView {
            master
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $showingAddWizard) {
            AddMachineWizardView(model: model)
        }
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
                    MasterRow(machine: m, dot: model.row(m.id)?.dot ?? .stopped,
                              stateWord: model.row(m.id)?.stateWord)
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
                showingAddWizard = true
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

/// One row in the master list: a status dot, the name, and a subtitle that
/// ends with the dot's meaning in a word or two -- the colors stay, but
/// nobody should have to decode them (Todd, 2026-07-10).
private struct MasterRow: View {
    let machine: Machine
    let dot: MachineStatusDot
    let stateWord: String?

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
        let base: String
        switch machine.kind {
        case .emulatedVM:   base = machine.image?.lastPathComponent ?? "no disk image"
        case .externalHost: base = machine.host.isEmpty ? "external" : machine.host
        }
        guard let stateWord else { return base }
        return "\(base) \u{00b7} \(stateWord)"
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
    /// The header name field's text. The header OWNS the name (single writer,
    /// same pattern as the Overview owning the active user since 2026-07-15) --
    /// the Settings form has no Name row and adopts the live name at commit.
    @State private var nameText: String = ""
    @FocusState private var nameFocused: Bool

    enum DetailTab: Hashable { case overview, settings, launchers }

    /// An imageless VM with a known OS opens to Overview — its Download… button
    /// is the fool-proof install path. An imageless VM whose OS is also unset
    /// (nothing to download) opens to Settings, where both get fixed; so does
    /// an external host with no address yet (the host field is the one thing a
    /// fresh external machine needs before anything works).
    private var defaultTab: DetailTab {
        if machine.kind == .emulatedVM && machine.image == nil && machine.os == nil {
            return .settings
        }
        if machine.kind == .externalHost
            && machine.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return .settings
        }
        return .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // The machine name outranks the blue section headers (title3),
                // so it gets title2. The active user rides along in the
                // header -- identity is host + account (Todd, 2026-07-13).
                // The name is edited right here (plain-style field, standard
                // inline-rename look): it commits on Return / focus loss, and
                // an empty or unchanged edit snaps back to the live name.
                TextField("Machine name", text: $nameText)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    // Hug the text like the Text() this replaced, so the
                    // "(user)" suffix stays right next to the name.
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                if !machine.user.isEmpty {
                    Text("(\(machine.user))")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .onChange(of: machine.id, initial: true) {
            tab = defaultTab
            nameText = machine.name
        }
    }

    /// Persist a header rename. Empty or unchanged text snaps the field back to
    /// the live name instead (a nameless machine can't exist).
    private func commitName() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != machine.name else {
            nameText = machine.name
            return
        }
        nameText = trimmed
        var m = machine
        m.name = trimmed
        // Deferred a runloop turn: focus-loss commits fire inside view updates,
        // and onCommit republishes the model (same reason as the detail forms).
        let model = self.model
        DispatchQueue.main.async { model.onCommit?(m) }
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
    /// The Change Login sheet (the agent-less tier of Change…; see
    /// MachineRow.canChangeLogin).
    @State private var showingChangeLogin = false

    var body: some View {
        ScrollView {
            if let row {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isFirstRun && row.canDownload {
                        firstRunBubble(row)
                    }
                    identitySection(row)
                    machineSection(row)
                    launchers(row)
                    adminAgents(row)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showingChangeLogin) {
                    ChangeLoginSheet(machineName: row.name,
                                     currentUser: row.activeUser,
                                     machineID: row.id,
                                     usesSSHKey: row.changeLoginUsesSSHKey,
                                     model: model)
                }
            } else {
                Text("No status.").foregroundStyle(.secondary).padding(20)
            }
        }
    }

    /// The first-run "just getting started" prompt over an imageless machine.
    /// The Download button below is rendered blue (prominent) while this shows,
    /// so the eye lands on the next thing to do (FIRST_RUN_EXPERIENCE.md).
    private func firstRunBubble(_ row: MachineRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Just getting started?")
                    .font(.headline)
                Text("Download a starter image and launch a SPARCstation. "
                     + "It becomes this machine\u{2019}s disk, then you\u{2019}ll "
                     + "add a login and it boots.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor.opacity(0.25)))
    }

    /// Identity leads the page: the active user is the most consequential
    /// per-machine fact (every launcher logs in as it), so it sits first even
    /// though it's technically a setting (Todd, 2026-07-13). Change… routes
    /// through the Users panel -- the ONE mechanism for switching, with its
    /// password proof (DECISIONS 2026-07-11) -- never a second path.
    private func identitySection(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionHeader("Active User")
            identityLine(row)
                .padding(.leading, 16)
        }
    }

    /// The user field + Change… button; the section header above carries the
    /// "Active User" label. Change… is tiered (2026-07-14): agent answering →
    /// the Users panel (hash-proof Set Active); no agent on an external box →
    /// the Change Login sheet (proof = a live telnet login); otherwise dead
    /// with the reason in the tooltip.
    private func identityLine(_ row: MachineRow) -> some View {
        HStack(spacing: 10) {
            // Label at the Target Machine status-line size, value in a
            // field-look box that's read-only (Todd, 2026-07-15) -- it
            // changes through Change…, never by typing here. Dots only when
            // a password is actually on file -- existence, never length.
            let value = row.activeUser.isEmpty ? "none set" : row.activeUser
            let dots = row.hasStoredPassword
                ? " / \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
                : ""
            Text("User:")
                .font(.system(size: 15, weight: .medium))
            Text("\(value)\(dots)")
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(minWidth: 180, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor)))
            Button("Change\u{2026}") {
                if row.canManageUsers {
                    model.onManageUsers?(row.id)
                } else {
                    showingChangeLogin = true
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!row.canManageUsers && !row.canChangeLogin)
            .help(changeHelp(row))
            Spacer()
        }
    }

    /// Why Change… does what it does (or won't), one tier at a time.
    private func changeHelp(_ row: MachineRow) -> String {
        if row.canManageUsers {
            return "Switch the account launchers log in as (asks for the "
                 + "account's password)"
        }
        if row.canChangeLogin {
            return row.changeLoginUsesSSHKey
                ? "Change the login launchers use (verified with your ssh key)"
                : "Change the login launchers use (verified by signing in "
                + "to the machine)"
        }
        if row.isEmulated {
            return "Start the machine to change users"
        }
        if row.dot == .externalUnauthorized {
            return "The machine's agent refused the saved secret \u{2014} fix "
                 + "it in Settings, then manage users here"
        }
        if row.dot == .externalUp {
            // Agent answering but canManageUsers still false = OS unknown
            // (sysinfo usually fills it on the next probe).
            return "Available once the machine's OS is known"
        }
        return "Available once the machine is reachable"
    }

    /// The target machine itself: live status, boot thermometer, and lifecycle
    /// verbs under one header.
    private func machineSection(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionHeader("Target Machine")
            VStack(alignment: .leading, spacing: 16) {
                statusLine(row)
                bootBar(row)
                lifecycle(row)
            }
            .padding(.leading, 16)
        }
        // ~20% more air before the header (Todd, 2026-07-15); same on the
        // two sections below.
        .padding(.top, 5)
    }

    /// No dot here (the master list carries it); the thermometer below is the
    /// Overview's state color.
    private func statusLine(_ row: MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // Named so the state reads as a sentence: "NetBSD Running".
                Text("\(row.name) \(row.statusText)")
                    .font(.system(size: 15, weight: .medium))
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
                if row.isDownloading {
                    // The thermometer above carries the phase; the only verb
                    // that makes sense mid-download is stopping it.
                    Button("Cancel Download") { model.onCancelDownload?(row.id) }
                } else if row.canShutDown || row.canForceQuit {
                    if row.canShutDown {
                        Button("Shut Down") { model.onShutDown?(row.id) }
                    }
                    if row.canForceQuit {
                        Button("Force Quit") { model.onForceQuit?(row.id) }
                    }
                } else {
                    Button("Start") { model.onStart?(row.id) }.disabled(!row.canStart)
                    if row.canDownload {
                        // Imageless + known OS: fetch the curated image; it
                        // becomes this machine's disk (IMAGE_DOWNLOAD_PLAN.md).
                        // Blue (prominent) during first run -- it's the next
                        // thing to do.
                        downloadButton(row)
                    }
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

    /// Download Image button -- prominent (blue) during first run so it reads
    /// as the next step; plain bordered afterward (adding a second machine's
    /// image is a routine action, not a call to action).
    @ViewBuilder private func downloadButton(_ row: MachineRow) -> some View {
        let button = Button("Download Image\u{2026}") { model.onDownload?(row.id) }
            .help("Download the curated starter image for this machine's "
                  + "guest OS and attach it as its disk")
        if model.isFirstRun {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
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
                    // Why anything above is dimmed, in words (nil when
                    // nothing is).
                    if let note = row.launcherNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 16)
        }
        .padding(.top, 5)
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

                    Button {
                        model.onManageUsers?(row.id)
                    } label: {
                        Label("Users", systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!row.canManageUsers)
                    .help(row.canManageUsers
                          ? "Add or remove login accounts on the machine"
                          : (row.isEmulated
                             ? "Available once the machine is running and ready"
                             : "Available once the machine answers a Helios check "
                             + "and its OS is known (set both in Settings)"))

                    Button {
                        model.onSyncClock?(row.id)
                    } label: {
                        Label("Sync Clock", systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!row.canSyncClock)
                    .help(row.canSyncClock
                          ? "Check the machine's clock and set it from this Mac"
                          : (row.isEmulated
                             ? "Available once the machine is running and ready"
                             : "Available once the machine answers a Helios check "
                             + "and its OS is known (set both in Settings)"))
                }
            }
            .padding(.leading, 16)
        }
        .padding(.top, 5)
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

/// The agent-less tier of the Overview's Change… (2026-07-14): a machine with
/// no Helios agent can't offer the Users panel, but the active user still has
/// to be changeable where the fact lives. Same doctrine as Set Active --
/// prove you know the account's password before anything is adopted -- with
/// the box's own telnet login as the proof (model.onVerifyLogin runs the
/// probe and adopts on success). Nothing on the machine changes either way.
private struct ChangeLoginSheet: View {
    let machineName: String
    let currentUser: String
    let machineID: UUID
    /// ssh machines prove with the key (BatchMode), so there's no password
    /// field -- nothing launcher-side ever uses one.
    let usesSSHKey: Bool
    @ObservedObject var model: MachinesModel

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    /// The last proof failure, shown inline. When the proof couldn't run at
    /// all (box off the network) it also unlocks the save-without-checking
    /// block below the error.
    @State private var failure: VerifyLoginFailure?

    private var canSubmit: Bool {
        !username.isEmpty && (usesSSHKey || !password.isEmpty) && !busy
    }

    /// True after a proof that couldn't run (box unreachable): the Change
    /// button relabels to "Change Without Checking" and adopts as-is.
    private var unverifiedMode: Bool { failure?.canSaveUnverified == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the login").font(.title3.weight(.semibold))
            Text("Launchers will sign in to \(machineName) as this account "
                 + "from now on. "
                 + (usesSSHKey
                    ? "It\u{2019}s checked with your ssh key before anything "
                    + "changes."
                    : "It\u{2019}s checked by actually logging in before "
                    + "anything changes."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if !usesSSHKey {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let failure {
                Text(failure.message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.canSaveUnverified {
                    // The escape hatch's warning; the Change button below
                    // relabels to "Change Without Checking" rather than a
                    // third button appearing (Todd, 2026-07-15). Explicit
                    // and warned, never a silent fallback -- the clock
                    // panel's Force Set shape.
                    Text("You can save this login without checking it. "
                         + "It\u{2019}ll be used as-is the next time the "
                         + "machine is on the network; if it\u{2019}s "
                         + "wrong, launchers will fail to sign in until "
                         + "it\u{2019}s corrected here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Signing in\u{2026}")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                // One affirmative button, two meanings: normally it runs the
                // proof; after an unreachable failure it relabels and adopts
                // as-is (the check can't run, and a second affirmative
                // button just read as a duplicate).
                Button(unverifiedMode ? "Change Without Checking" : "Change") {
                    if unverifiedMode {
                        model.onAdoptLoginUnverified?(machineID, username,
                                                      password)
                        dismiss()
                    } else {
                        submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { username = currentUser }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        failure = nil
        model.onVerifyLogin?(machineID, username, password) { result in
            busy = false
            if let result {
                // Stay on the sheet; wrong password is the retry case, and
                // an unreachable box reveals the save-without-checking block.
                failure = result
            } else {
                dismiss()
            }
        }
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
            case .externalNoAgent:
                // Alive (the box answered the connect with a refusal) but
                // unmanaged: green outline, not green fill.
                Circle().strokeBorder(.green, lineWidth: 1.5).frame(width: 10, height: 10)
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
        case .external: return "External host, checking"
        case .externalUp: return "External host, Helios agent answering"
        case .externalUnauthorized: return "External host, agent answered but denied the request"
        case .externalNoAgent: return "External host, up but no Helios agent on its port"
        case .externalDown: return "External host, unreachable"
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
