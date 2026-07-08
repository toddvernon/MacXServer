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

    init(machine: Machine, model: MachinesModel) {
        self.model = model
        // A bundled machine is managed over Helios, full stop -- snap a drifted
        // transport (hand-edited JSON) back so the locked picker shows the truth.
        var m = machine
        if m.bundled { m.transport = .helios }
        _committed = State(initialValue: machine)
        _draft = State(initialValue: m)
    }

    /// A shipped bundled fixture: its kind/host/OS are load-bearing identity, so
    /// they're locked; you can still attach an image and edit launchers.
    private var bundled: Bool { draft.bundled }
    private var running: Bool { model.isRunning(draft.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identitySection
                connectionSection
                if draft.kind == .emulatedVM {
                    imageSection
                    runtimeSection
                }
                launchersSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $launcherEdit) { target in
            LauncherEditorView(
                initial: target.launcher,
                machineTransport: draft.transport
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

    private var identitySection: some View {
        section("Identity") {
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
            if bundled {
                helpNote("This is a bundled machine that ships with the app. Its kind, "
                       + "host, and OS are fixed; attach a disk image here to run it.")
            }
        }
    }

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
            if draft.kind == .externalHost,
               draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                helpNote("A host is required before an external machine is saved.")
            }
            LabeledField("User") {
                TextField("login user", text: $draft.user)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Transport") {
                // A bundled machine's management plane is Helios by design (its
                // per-boot secret + hostfwd are wired for it), so the picker is
                // locked there. Explicit .leading: a bare frame(width:) centers
                // the narrow picker, drifting it right of the text fields above.
                Picker("", selection: $draft.transport) {
                    ForEach(LauncherTransport.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 140, alignment: .leading)
                .disabled(bundled)
            }
            osField
            // The telnet launcher needs to recognize "logged in, shell
            // ready". Built-in detection covers the classic sigils and the
            // fleet's bracket prompt; this override is for anything else.
            // Only shown when telnet is actually in play for this machine.
            if draft.transport == .telnet
                || draft.launchers.contains(where: { $0.transport == .telnet }) {
                LabeledField("Prompt") {
                    TextField("auto-detect ($ % # > or [\u{2026}])", text: Binding(
                        get: { draft.shellPrompt ?? "" },
                        set: { draft.shellPrompt = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                        .help("Substring that marks this account's shell prompt for "
                            + "telnet launches (e.g. \u{201c}tvernon]\u{201d}). Blank = "
                            + "automatic detection.")
                }
                passwordField
            }
            LabeledField("DISPLAY") {
                // Placeholder = what blank actually resolves to at launch time
                // (this X server's own address), so the default is visible and
                // still editable. A slirp guest usually wants 10.0.2.2:0.
                TextField(model.defaultDisplay.map { "\($0()) (this server)" }
                              ?? "auto (leave blank)",
                          text: Binding(
                    get: { draft.display ?? "" },
                    set: { draft.display = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .help("The DISPLAY handed to launched clients. Blank = this X "
                        + "server's own address (shown). A slirp guest usually "
                        + "wants 10.0.2.2:0.")
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
            .help("Login password for telnet launches on this machine, "
                + "stored in machines.json. Blank = ask on first launch "
                + "and remember in the macOS Keychain.")
            // Commit as-you-type (like the autoBackup toggle): a launch
            // from the Machines menu never blurs this field or tears the
            // form down, so waiting for Return/onDisappear meant the
            // registry could hold a different password than the dots
            // showed. No cross-field validation on it, so eager is safe.
            .onChange(of: draft.password) { commit() }
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

    /// The machine's assigned runtime identity: the Mac-side host ports the
    /// tooling dials (sticky -- assigned once by the registry, never move for
    /// the life of the machine) and the guest MAC (derived from the machine's
    /// id; stable across boots, unique per machine). Read-only by design.
    private var runtimeSection: some View {
        let p = draft.resolvedPorts
        return section("Runtime") {
            LabeledField("Ports") {
                Text("telnet \(String(p.telnet)) \u{00B7} ssh \(String(p.ssh)) \u{00B7} helios \(String(p.helios))")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledField("MAC") {
                Text(draft.resolvedMacAddress)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            helpNote("Assigned to this machine when it was created and never change, "
                   + "so scripts and tooling can rely on them. Ports are this Mac's "
                   + "forwards into the guest (telnet/ssh/helios).")
        }
    }

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
                              : draft.os)?.rawValue ?? "unspecified")
                    }
                } else {
                    Picker("", selection: $draft.os) {
                        Text("auto / unspecified").tag(MachineOS?.none)
                        ForEach(MachineOS.allCases, id: \.self) { os in
                            Text(os.rawValue).tag(MachineOS?.some(os))
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
    /// image-backed emulated VM, or the Helios provenance for an external
    /// host that reported its own uname.
    private var osCaption: String? {
        if osDetectedOverHelios {
            return "Detected from the machine over Helios."
        }
        guard draft.kind == .emulatedVM, draft.imagePath?.isEmpty == false else { return nil }
        return osDetection?.explanation ?? "Detecting the OS from the image\u{2026}"
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
                if draft.launchers.isEmpty {
                    helpNote("No launchers. Add an X-client command.")
                } else {
                    ForEach(Array(draft.launchers.enumerated()), id: \.offset) { idx, l in
                        launcherRow(idx: idx, launcher: l)
                        if idx < draft.launchers.count - 1 { Divider() }
                    }
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
    private let onSave: (MachineLauncher) -> Void

    init(initial: MachineLauncher, machineTransport: LauncherTransport,
         onSave: @escaping (MachineLauncher) -> Void) {
        _draft = State(initialValue: initial)
        self.machineTransport = machineTransport
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
                    Text("Transport").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $draft.transport) {
                        Text("inherit (\(machineTransport.rawValue))").tag(LauncherTransport?.none)
                        ForEach(LauncherTransport.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(LauncherTransport?.some(t))
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

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !(draft.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
