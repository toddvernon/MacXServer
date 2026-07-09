import SwiftUI
import AppKit
import SwiftXServerCore

/// The right-hand detail form: edits a local `draft` of the selected machine.
/// There's no Save button -- the draft auto-commits at natural edit boundaries
/// (Return in any field, and on leaving the pane: switching machine/tab or
/// closing the window), so you can't lose an edit by forgetting to save. The
/// draft is still a value-copy (not a live binding into the registry) so a
/// half-finished or invalid edit -- empty name, empty external host, an image two
/// machines both claim -- simply doesn't commit and says why inline; navigating
/// away from an invalid edit drops it (a nameless machine can't exist). A bundled
/// fixture locks the fields that are its identity (kind, host, OS); its image is
/// frozen while it's running.
struct MachineDetailForm: View {
    @ObservedObject var model: MachinesModel
    /// The last-committed value, tracked so an auto-commit is a no-op when nothing
    /// changed (and so a re-commit after Return doesn't re-fire needlessly).
    @State private var committed: Machine
    @State private var draft: Machine
    /// Launcher being added/edited in the sheet, if any.
    @State private var launcherEdit: LauncherEditTarget?
    /// Launcher pending delete confirmation (the minus button asks first).
    @State private var launcherDelete: LauncherEditTarget?
    /// The guest-OS detection for the current image, run off-main at pick time (and
    /// on appear) for an image-backed emulated VM. nil until it has run.
    @State private var osDetection: GuestOSDetection?
    /// Set when an image was REFUSED because it doesn't match a bundled
    /// fixture's fixed OS (fool-proofing: you can't attach the NetBSD image to
    /// the Solaris machine). Cleared on the next pick.
    @State private var imageMismatchNote: String?
    /// "Show what I'm typing" for the telnet password field.
    @State private var revealPassword = false
    /// The ports editor's field text (telnet / ssh / helios). Kept as strings
    /// (not bindings into `draft.ports`) so a half-typed number doesn't have to
    /// be a valid port: blank = derive, and the triple only lands on the draft
    /// once every non-blank field parses (see `syncPortsDraft`).
    @State private var portTelnetText: String
    @State private var portSSHText: String
    @State private var portHeliosText: String

    init(machine: Machine, model: MachinesModel) {
        self.model = model
        // A bundled machine is managed over Helios, full stop -- snap a drifted
        // transport (hand-edited JSON) back so the locked picker shows the truth.
        var m = machine
        if m.bundled { m.transport = .helios }
        _committed = State(initialValue: machine)
        _draft = State(initialValue: m)
        // Seed the ports editor from the explicit override only -- derived
        // ports show as placeholders, so blank keeps meaning "the usual".
        _portTelnetText = State(initialValue: machine.ports.map { String($0.telnet) } ?? "")
        _portSSHText = State(initialValue: machine.ports.map { String($0.ssh) } ?? "")
        _portHeliosText = State(initialValue: machine.ports.map { String($0.helios) } ?? "")
    }

    /// A shipped bundled fixture: its kind/host/OS are load-bearing identity, so
    /// they're locked; you can still attach an image and edit launchers.
    private var bundled: Bool { draft.bundled }
    private var running: Bool { model.isRunning(draft.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                machineSection
                connectionSection
                loginSection
                launchersSection
                if draft.kind == .emulatedVM {
                    imageSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $launcherEdit) { target in
            LauncherEditorView(
                initial: target.launcher,
                machineTransport: draft.transport,
                // Sibling names, minus the launcher being edited: chips,
                // menu items, and launchFromMachine all key by name, so a
                // duplicate would shadow its twin on every run surface.
                takenNames: draft.launchers.enumerated()
                    .filter { $0.offset != target.index }
                    .map(\.element.name)
            ) { edited in
                apply(edited, to: target)
            }
        }
        .alert("Remove \u{201c}\(launcherDelete?.launcher.name ?? "")\u{201d}?",
               isPresented: Binding(get: { launcherDelete != nil },
                                    set: { if !$0 { launcherDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let target = launcherDelete, let i = target.index,
                   i < draft.launchers.count {
                    draft.launchers.remove(at: i)
                    commit()
                }
                launcherDelete = nil
            }
            Button("Cancel", role: .cancel) { launcherDelete = nil }
        } message: {
            Text("Removes the launcher from this machine. Nothing on the machine "
               + "itself is affected.")
        }
        // Re-detect whenever the image (or kind) changes -- i.e. at pick time.
        .task(id: "\(draft.kind.rawValue):\(draft.imagePath ?? "")") { await runOSDetection() }
        // Auto-commit: Return in any field, and on leaving the pane (switch
        // machine/tab, close window). No Save button -- see the type doc.
        .onSubmit { commit() }
        .onDisappear { commit() }
    }

    /// Query the assigned image for its guest OS (off the main thread) and, when
    /// confident, adopt it -- the image is the source of truth, so this corrects a
    /// config that drifted (e.g. migration's guessed `solaris26` on a SunOS image).
    /// On a BUNDLED fixture the OS is fixed identity, so the logic inverts: a
    /// confidently-detected MISMATCH refuses the image outright (fool-proofing --
    /// the wrong image can never attach to the wrong machine) instead of
    /// mutating the fixture. Non-emulated / image-less machines clear the
    /// detection and keep a free picker.
    @MainActor
    private func runOSDetection() async {
        guard draft.kind == .emulatedVM, let path = draft.imagePath, !path.isEmpty else {
            osDetection = nil
            return
        }
        imageMismatchNote = nil
        let result = await Task.detached { GuestOSDetector.detect(imagePath: path) }.value
        guard draft.imagePath == path else { return }   // path changed mid-scan
        osDetection = result
        if bundled {
            if let detected = result.os, let fixed = draft.os, detected != fixed {
                draft.imagePath = nil
                osDetection = nil
                imageMismatchNote = "That image contains \(detected.displayName), but this "
                    + "is the \(fixed.displayName) machine \u{2014} not attached. Use the "
                    + "\(detected.displayName) machine for it (or a new machine)."
                commit()   // persist the refusal so the bad path never lands
            }
        } else if let detected = result.os, draft.os != detected {
            draft.os = detected
        }
    }

    // MARK: Sections

    /// One titled section: the blue header sits at the left edge, the content
    /// is inset beneath it so the sections read as header + body (Todd's
    /// aesthetics pass 2026-07-06).
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(.leading, 16)
        }
    }

    /// What this machine IS: name, kind, OS. (Was "Identity"; renamed in the
    /// 2026-07-09 settings reorg -- see MACHINE_SETTINGS_AUDIT.md section 2.
    /// OS moved in from Connection: it's machine identity, driving boot
    /// config, halt command, port block, and X paths, nothing about
    /// connecting.)
    private var machineSection: some View {
        section("Machine") {
            LabeledField("Name") {
                TextField("Machine name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                helpNote("A name is required before the machine is saved.")
            }
            LabeledField("Kind") {
                // Bundled: the kind is load-bearing identity. Running (incl.
                // shutting down): flipping a live VM to external would strand
                // its lifecycle UI while qemu keeps running.
                Picker("", selection: $draft.kind) {
                    Text("Emulated VM").tag(MachineKind.emulatedVM)
                    Text("External host").tag(MachineKind.externalHost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(bundled || running)
            }
            fieldCaption("An emulated VM runs right here on your Mac. An external host "
                       + "is a real machine on your network that this app connects to.")
            if bundled {
                helpNote("This is a bundled machine that ships with the app. Its kind, "
                       + "host, and OS are fixed; attach a disk image here to run it.")
            }
            osField
        }
    }

    /// How the app REACHES the box: host, transport, ports, and (external
    /// only) the Helios secret -- a wrong secret is a connection failure, so
    /// it lives next to Host and Connect with.
    private var connectionSection: some View {
        section("Connection") {
            LabeledField("Host") {
                // An emulated VM is always dialed at loopback (its qemu's
                // hostfwds live there), so the field only opens up for
                // external hosts.
                TextField(draft.kind == .emulatedVM ? "127.0.0.1" : "hostname or IP",
                          text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.kind == .emulatedVM)
            }
            if draft.kind == .emulatedVM {
                fieldCaption("Emulated VMs are always reached through this Mac, so "
                           + "there's nothing to set.")
            }
            if draft.kind == .externalHost,
               draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                helpNote("A host is required before an external machine is saved.")
            }
            LabeledField("Connect with") {
                // A bundled machine's management plane is Helios by design (its
                // per-boot secret + hostfwd are wired for it), so the picker is
                // locked there. Explicit .leading: a bare frame(width:) centers
                // the narrow picker, drifting it right of the text fields above.
                Picker("", selection: $draft.transport) {
                    ForEach(LauncherTransport.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 140, alignment: .leading)
                .disabled(bundled)
            }
            fieldCaption("How the app logs in to run things. Telnet and SSH sign in "
                       + "like you would at a terminal; the Helios agent is our own "
                       + "helper, the smoothest option once it's installed on the "
                       + "machine.")
            portsField
            if draft.kind == .externalHost {
                heliosSecretField
            }
        }
    }

    /// The Helios secret entry point (moved from the Overview 2026-07-09: a
    /// credential is a setting, and the Overview slot it sat in belongs to
    /// lifecycle buttons). The value lives in the Keychain, not the draft, so
    /// this is a button that opens the existing dialog, not a field.
    private var heliosSecretField: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledField("Helios Secret") {
                Button("Set\u{2026}") { model.onSetHeliosSecret?(draft.id) }
            }
            fieldCaption("The password this machine's Helios agent expects. Kept in "
                       + "your macOS Keychain.")
        }
    }

    /// The ACCOUNT on the machine: user, and the telnet login mechanics
    /// (password + shell prompt) inside the section that owns them.
    private var loginSection: some View {
        section("Login") {
            LabeledField("User") {
                TextField("login user", text: $draft.user)
                    .textFieldStyle(.roundedBorder)
            }
            fieldCaption("The account on that machine. Apps you launch log in and "
                       + "run as this user.")
            // The telnet launcher needs to recognize "logged in, shell
            // ready". Built-in detection covers the classic sigils and the
            // fleet's bracket prompt; this override is for anything else.
            // Only shown when telnet is actually in play for this machine.
            if draft.transport == .telnet
                || draft.launchers.contains(where: { $0.transport == .telnet }) {
                passwordField
                LabeledField("Shell prompt") {
                    TextField("auto-detect ($ % # > or [\u{2026}])", text: Binding(
                        get: { draft.shellPrompt ?? "" },
                        set: { draft.shellPrompt = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                fieldCaption("How we recognize that a telnet login finished: text "
                           + "your shell prompt ends with. Leave blank and the app "
                           + "figures out the usual prompts itself.")
            }
        }
    }

    /// The telnet login password (its own property: keeps connectionSection
    /// type-checkable). Same field swap as SecretEntryField, in SwiftUI: dots
    /// by default, plain when "Show" is on, one shared binding.
    private var passwordBinding: Binding<String> {
        Binding(get: { draft.password ?? "" },
                set: { draft.password = $0.isEmpty ? nil : $0 })
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledField("Password") {
                HStack(spacing: 8) {
                    if revealPassword {
                        TextField("ask on first launch (Keychain)", text: passwordBinding)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("ask on first launch (Keychain)", text: passwordBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Show", isOn: $revealPassword)
                        .toggleStyle(.checkbox)
                }
                // Commit as-you-type (like the autoBackup toggle): a launch
                // from the Machines menu never blurs this field or tears the
                // form down, so waiting for Return/onDisappear meant the
                // registry could hold a different password than the dots
                // showed. No cross-field validation on it, so eager is safe.
                .onChange(of: draft.password) { commit() }
            }
            fieldCaption("Password for telnet logins. Leave it blank to be asked once "
                       + "and have it kept in the macOS Keychain; type it here only if "
                       + "you're fine with it sitting in machines.json as plain text.")
        }
    }

    // MARK: Ports editor (audit F1, 2026-07-09)

    /// What blank port fields resolve to: the machine's derived block (per-OS
    /// for emulated VMs, 23/22/2125 for externals). Computed off a ports-less
    /// copy so an explicit override never feeds back into its own placeholders.
    private var derivedPorts: ImagePorts {
        var m = draft
        m.ports = nil
        return m.resolvedPorts
    }

    /// True when some non-blank port field isn't a number in 1...65535.
    /// (Blank is always fine -- it means "derive".)
    private var portsTextInvalid: Bool {
        [portTelnetText, portSSHText, portHeliosText].contains { text in
            let t = text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && (UInt16(t) == nil || UInt16(t) == 0)
        }
    }

    /// The override the current field text describes: nil when all three are
    /// blank (back to derived), otherwise a full triple with blank fields
    /// filled from the derived block. Meaningless while `portsTextInvalid`.
    private var portsFromText: ImagePorts? {
        let d = derivedPorts
        let t = portTelnetText.trimmingCharacters(in: .whitespaces)
        let s = portSSHText.trimmingCharacters(in: .whitespaces)
        let h = portHeliosText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty && s.isEmpty && h.isEmpty { return nil }
        return ImagePorts(telnet: t.isEmpty ? d.telnet : UInt16(t) ?? d.telnet,
                          ssh: s.isEmpty ? d.ssh : UInt16(s) ?? d.ssh,
                          helios: h.isEmpty ? d.helios : UInt16(h) ?? d.helios)
    }

    /// Land the field text on the draft. A half-typed / invalid number leaves
    /// `draft.ports` alone (and `canCommit` blocks on it), so garbage never
    /// persists; blank-out clears the override back to derived.
    private func syncPortsDraft() {
        guard !portsTextInvalid else { return }
        draft.ports = portsFromText
    }

    /// The other emulated VM whose port block collides with this draft's, if
    /// any (blocks commit, same pattern as `imageClaimantName`). Emulated VMs
    /// only: they all share loopback; externals are dialed at their own host.
    private var portsClaimantName: String? {
        guard draft.kind == .emulatedVM else { return nil }
        return model.portsClaimant?(draft.resolvedPorts, draft.id)
    }

    private var portsField: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledField("Ports") {
                HStack(spacing: 10) {
                    portBox("telnet", $portTelnetText, placeholder: derivedPorts.telnet)
                    portBox("ssh", $portSSHText, placeholder: derivedPorts.ssh)
                    portBox("helios", $portHeliosText, placeholder: derivedPorts.helios)
                }
                // A live qemu's hostfwds are baked into its argv, same freeze
                // rule as the disk image.
                .disabled(running)
            }
            .onChange(of: portTelnetText) { syncPortsDraft() }
            .onChange(of: portSSHText) { syncPortsDraft() }
            .onChange(of: portHeliosText) { syncPortsDraft() }
            Group {
                if running {
                    helpNote("Stop the VM to change its ports.")
                } else if draft.kind == .emulatedVM {
                    helpNote("How this Mac reaches the guest. Assigned when the machine "
                           + "was created; override only to resolve a conflict.")
                } else {
                    helpNote("How this Mac reaches the machine's telnet, SSH, and Helios "
                           + "agent. Leave blank for the usual ports.")
                }
            }
            .padding(.leading, 96)   // align under the fields (label 84 + spacing 12)
            if portsTextInvalid {
                Label("Ports must be numbers between 1 and 65535.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 96)
            }
            if let other = portsClaimantName {
                Label("These ports collide with \u{201c}\(other)\u{201d} \u{2014} every "
                    + "machine needs its own.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 96)
            }
        }
    }

    private func portBox(_ label: String, _ text: Binding<String>,
                         placeholder: UInt16) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(String(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
        }
    }

    private var imageSection: some View {
        section("Disk image") {
            HStack(spacing: 8) {
                TextField("path to .qcow2", text: Binding(
                    get: { draft.imagePath ?? "" },
                    set: { draft.imagePath = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(running)
                Button("Choose\u{2026}") {
                    if let path = model.onPickImage?() { draft.imagePath = path }
                }
                .disabled(running)
                Button("Reveal in Finder") { revealImageInFinder() }
                    .disabled((draft.imagePath ?? "").isEmpty)
            }
            if running {
                helpNote("Stop the VM to change its disk image.")
            }
            if let other = imageClaimantName {
                Label("Also used by \u{201c}\(other)\u{201d} \u{2014} one machine per image.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let mismatch = imageMismatchNote {
                Label(mismatch, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Back up the disk image after each clean shutdown",
                   isOn: $draft.autoBackup)
                .onChange(of: draft.autoBackup) { commit() }
            helpNote("Keeps a dated \u{201C}last known good\u{201D} copy next to the image "
                   + "whenever this machine shuts down cleanly. Only the most recent few "
                   + "are kept; manual backups are never pruned.")
        }
    }

    // (The read-only Runtime section retired 2026-07-09: ports gained a real
    // editor above, and the ports + MAC facts moved to the Overview as a
    // quiet monospaced line under the system line -- Settings now holds only
    // things with an edit affordance.)

    /// Guest-OS administration over the Helios daemon. Editing needs the guest
    /// up and its daemon answering, so the button rides the same readiness gate
    /// as the Machines menu's Admin submenu.
    // (Machine DNS moved to the Overview's Admin Agents section 2026-07-07:
    // it's an operate verb on a live guest, not machine configuration.)

    private func revealImageInFinder() {
        guard let path = draft.imagePath, !path.isEmpty else { return }
        NSWorkspace.shared.selectFile((path as NSString).expandingTildeInPath,
                                      inFileViewerRootedAtPath: "")
    }

    /// The OS row. For an image-backed emulated VM the OS is *derived from the
    /// image* (queried at pick time), so it's shown locked to the detected value;
    /// when detection can't identify it (BYO / compressed / not-a-qcow2) it falls
    /// back to a free picker so the user can set it. External hosts + image-less
    /// VMs always use the free picker (no image to query).
    @ViewBuilder private var osField: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledField("OS") {
                if osLocked {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        // Helios-detected: read the LIVE registry value, not the
                        // draft -- the prober may have adopted the OS while this
                        // pane sat open on a stale value-copy.
                        Text((osDetectedOverHelios
                              ? model.machines.first(where: { $0.id == draft.id })?.os
                              : draft.os)?.displayName ?? "unspecified")
                    }
                } else {
                    Picker("", selection: $draft.os) {
                        Text("auto / unspecified").tag(MachineOS?.none)
                        ForEach(MachineOS.allCases, id: \.self) { os in
                            Text(os.displayName).tag(MachineOS?.some(os))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            if let caption = osCaption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 96)   // align under the field (label 84 + spacing 12)
            }
        }
    }

    /// True when an external machine's OS was learned from the box itself
    /// (the agent's sysinfo uname, via the prober). The box outranks a
    /// manual pick, same doctrine as image detection.
    private var osDetectedOverHelios: Bool {
        draft.kind == .externalHost && (model.row(draft.id)?.osIsDetected ?? false)
    }

    /// Lock the OS to the detected value only when we're confident (an image-backed
    /// emulated VM whose image identified a known OS, or an external host whose
    /// agent reported its uname over Helios).
    private var osLocked: Bool {
        // A bundled fixture's OS is its fixed identity; a RUNNING machine's OS
        // is what it booted with (it drives the port block, boot unit, and
        // halt command -- changing it mid-run would desync every port lookup);
        // otherwise it's locked once it's been derived from an attached image
        // or reported by the box's own agent.
        bundled || running
            || (draft.kind == .emulatedVM && draft.imagePath?.isEmpty == false && osDetection?.os != nil)
            || osDetectedOverHelios
    }

    /// Caption under the OS row: the image-detection explanation for an
    /// image-backed emulated VM, the Helios provenance for an external host
    /// that reported its own uname, or (free-picker state) what the field is
    /// even for.
    private var osCaption: String? {
        if osDetectedOverHelios {
            return "Detected from the machine over Helios."
        }
        if draft.kind == .emulatedVM, draft.imagePath?.isEmpty == false {
            return osDetection?.explanation ?? "Detecting the OS from the image\u{2026}"
        }
        if osLocked { return nil }
        return "What the machine runs. Set it if we couldn't detect it. It tells the "
             + "app where that system keeps its X programs and how to talk to it."
    }

    private var launchersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("X11 Launchers")
                Spacer()
                Button {
                    launcherEdit = LauncherEditTarget(index: nil,
                                                      launcher: MachineLauncher(name: ""))
                } label: { Label("Add Command", systemImage: "plus") }
                    .controlSize(.small)
            }
            // Same content inset as the other sections (see `section`).
            VStack(alignment: .leading, spacing: 10) {
                // DISPLAY renamed + moved here 2026-07-09: its only consumer
                // is launch resolution, so it's launcher config, not
                // connection config.
                LabeledField("Show windows on") {
                    // Placeholder = what blank actually resolves to at launch
                    // time (this X server's own address), so the default is
                    // visible and still editable.
                    TextField(model.defaultDisplay.map { "\($0()) (this server)" }
                                  ?? "auto (leave blank)",
                              text: Binding(
                        get: { draft.display ?? "" },
                        set: { draft.display = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                fieldCaption("Where launched apps put their windows. Blank means this "
                           + "X server (shown grayed). From inside an emulated VM this "
                           + "Mac is 10.0.2.2, so those machines use 10.0.2.2:0.")
                if draft.launchers.isEmpty {
                    helpNote("No launchers. Add an X-client command.")
                } else {
                    ForEach(Array(draft.launchers.enumerated()), id: \.offset) { idx, l in
                        launcherRow(idx: idx, launcher: l)
                        if idx < draft.launchers.count - 1 { Divider() }
                    }
                    helpNote("Right-click a launcher to watch the login play out in a "
                           + "progress window, handy when a launch hangs.")
                }
            }
            .padding(.leading, 16)
        }
    }

    private func launcherRow(idx: Int, launcher l: MachineLauncher) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name.isEmpty ? "(unnamed)" : l.name)
                Text(l.command ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                launcherEdit = LauncherEditTarget(index: idx, launcher: l)
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button {
                // Confirm first -- a stray click on the minus used to delete
                // instantly with no undo.
                launcherDelete = LauncherEditTarget(index: idx, launcher: l)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // Rows here are for editing; running lives on the Overview. The
        // exception is the debugging gesture: right-click > Run with Progress
        // Window streams this one launch's transcript live (verbose stopped
        // being persisted launcher config 2026-07-08). Runs the committed
        // launcher from the registry, so an uncommitted rename runs the old name.
        .contentShape(Rectangle())
        .contextMenu {
            Button("Run") { model.onLaunch?(draft.id, l.name, false) }
            Button("Run with Progress Window") { model.onLaunch?(draft.id, l.name, true) }
        }
    }

    // MARK: Commit + validation

    /// Persist the draft if it's changed and valid. Called at edit boundaries
    /// (Return / leaving the pane); an invalid or unchanged draft is a no-op.
    private func commit() {
        // The runtime-defining fields are frozen while the VM is live, but a
        // draft opened BEFORE the start can still carry edits to them (the
        // machine was started from the menu while this pane sat open). Drop
        // those back to the committed values so a Return can't swap the
        // image / OS / kind out from under a running qemu -- the
        // termination auto-backup reads the CURRENT image path, so a mid-run
        // image swap would back up a file that never ran.
        if running {
            draft.kind = committed.kind
            draft.os = committed.os
            draft.imagePath = committed.imagePath
            // Ports too: the live qemu's hostfwds were built from the
            // committed block, so a mid-run edit would desync every dial.
            draft.ports = committed.ports
        }
        // Same stale-draft protection for a Helios-detected OS: the prober may
        // have adopted the box's real OS into the registry while this pane sat
        // open on an older copy -- a Return must not write the stale os back.
        if draft.kind == .externalHost, model.row(draft.id)?.osIsDetected == true,
           let live = model.machines.first(where: { $0.id == draft.id }) {
            draft.os = live.os
        }
        // Fix up a colon-less DISPLAY override at the edit boundary (Todd,
        // 2026-07-08): "desktop.vernon.com" without a display number is never
        // valid X, and the failure is brutally silent -- the client dies at
        // connect under nohup >/dev/null after the launch already reported
        // success. Appending :0 here (not at resolve time) keeps the stored
        // config identical to what the field shows.
        if let d = draft.display?.trimmingCharacters(in: .whitespaces) {
            if d.isEmpty { draft.display = nil }
            else if !d.contains(":") { draft.display = "\(d):0" }
        }
        guard canCommit else { return }
        committed = draft
        // A selection change tears this form down via .id(), so commit() runs
        // from onDisappear INSIDE the view-update transaction; onCommit refreshes
        // the model's @Published machines/rows, which would trip "Publishing
        // changes from within view updates". Defer the publish one runloop turn.
        let machine = draft
        let model = self.model
        DispatchQueue.main.async { model.onCommit?(machine) }
    }

    private var canCommit: Bool {
        guard draft != committed else { return false }
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if draft.kind == .externalHost,
           draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if imageClaimantName != nil { return false }
        if portsTextInvalid || portsClaimantName != nil { return false }
        return true
    }

    /// The other emulated VM already using this image, if any (blocks Save).
    private var imageClaimantName: String? {
        guard draft.kind == .emulatedVM, let path = draft.imagePath, !path.isEmpty else { return nil }
        return model.imageClaimant?(path, draft.id)
    }

    private func apply(_ edited: MachineLauncher, to target: LauncherEditTarget) {
        if let i = target.index, i < draft.launchers.count {
            draft.launchers[i] = edited
        } else {
            draft.launchers.append(edited)
        }
        commit()   // a launcher edit is a deliberate action; persist it now
    }

    private func sectionHeader(_ text: String) -> some View {
        MachineSectionHeader(text)
    }

    private func helpNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A helpNote indented to sit under its field's control (label 84 +
    /// spacing 12), the always-visible caption style from the 2026-07-09
    /// settings pass -- promoted from hover-only .help tooltips, which were
    /// invisible until you knew to hover.
    private func fieldCaption(_ text: String) -> some View {
        helpNote(text).padding(.leading, 96)
    }
}

/// Plain-English transport names for the UI (the raw enum values are
/// protocol vocabulary; user-facing labels avoid it).
extension LauncherTransport {
    var displayName: String {
        switch self {
        case .telnet: return "Telnet"
        case .ssh:    return "SSH"
        case .helios: return "Helios agent"
        }
    }
}

/// Identifies which launcher the sheet is editing: an existing index, or nil for
/// a new one. Identifiable so `.sheet(item:)` can present it.
struct LauncherEditTarget: Identifiable {
    let id = UUID()
    let index: Int?
    let launcher: MachineLauncher
}

/// A label + control laid out as a left-aligned column, so the form's fields line
/// up. Boring on purpose.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// A modal sheet editing one launcher command. Returns the edited launcher via
/// `onSave`.
struct LauncherEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MachineLauncher
    /// The owning machine's transport, shown as the "inherit" default label.
    private let machineTransport: LauncherTransport
    /// The machine's OTHER launcher names. Every run surface (chips, menus,
    /// launchFromMachine) keys launchers by name, so a duplicate name makes
    /// its twin unreachable -- Done blocks on it (audit F9, 2026-07-09).
    private let takenNames: [String]
    private let onSave: (MachineLauncher) -> Void

    init(initial: MachineLauncher, machineTransport: LauncherTransport,
         takenNames: [String] = [],
         onSave: @escaping (MachineLauncher) -> Void) {
        _draft = State(initialValue: initial)
        self.machineTransport = machineTransport
        self.takenNames = takenNames
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Launcher").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("menu label", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Command").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("xterm -fg cyan -bg black",
                              text: Binding(get: { draft.command ?? "" },
                                            set: { draft.command = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("")
                    // The second sentence is the F10 asymmetry, documented at
                    // the one place you'd trip over it: the same command can
                    // behave differently per connection.
                    Text("Runs on the machine with its display already pointed at "
                       + "this server. Anything that opens an X window works. Over "
                       + "Telnet the command sees the login shell's own PATH; over "
                       + "SSH or the Helios agent the app adds the system's X "
                       + "program folders itself.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Connect with").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $draft.transport) {
                        Text("inherit (\(machineTransport.displayName))").tag(LauncherTransport?.none)
                        ForEach(LauncherTransport.allCases, id: \.self) { t in
                            Text(t.displayName).tag(LauncherTransport?.some(t))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 200, alignment: .leading)
                }
            }

            // (No per-launcher DISPLAY or file-browser flag anymore, 2026-07-07:
            // the machine's DISPLAY covers every launcher, and File Transfer is
            // automatic under Admin Agents whenever the box has helios. No
            // verbose toggle either, 2026-07-08: the progress window is a
            // launch gesture -- right-click > Run with Progress Window.)
            if nameTaken {
                Text("This machine already has a launcher named "
                   + "\u{201c}\(draft.name)\u{201d}. Give this one its own name.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Exact-match against siblings (names are the launcher key everywhere,
    /// so the comparison matches the lookups: case-sensitive, as-typed).
    private var nameTaken: Bool { takenNames.contains(draft.name) }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !nameTaken else { return false }
        return !(draft.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
