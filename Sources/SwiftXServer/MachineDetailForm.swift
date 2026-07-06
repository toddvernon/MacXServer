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
    /// The guest-OS detection for the current image, run off-main at pick time (and
    /// on appear) for an image-backed emulated VM. nil until it has run.
    @State private var osDetection: GuestOSDetection?

    init(machine: Machine, model: MachinesModel) {
        self.model = model
        _committed = State(initialValue: machine)
        _draft = State(initialValue: machine)
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
                if draft.kind == .emulatedVM { imageSection }
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
    /// Non-emulated / image-less machines clear the detection and keep a free picker.
    @MainActor
    private func runOSDetection() async {
        guard draft.kind == .emulatedVM, let path = draft.imagePath, !path.isEmpty else {
            osDetection = nil
            return
        }
        let result = await Task.detached { GuestOSDetector.detect(imagePath: path) }.value
        guard draft.imagePath == path else { return }   // path changed mid-scan
        osDetection = result
        if let detected = result.os, draft.os != detected { draft.os = detected }
    }

    // MARK: Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Identity")
            LabeledField("Name") {
                TextField("Machine name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                helpNote("A name is required before the machine is saved.")
            }
            LabeledField("Kind") {
                Picker("", selection: $draft.kind) {
                    Text("Emulated VM").tag(MachineKind.emulatedVM)
                    Text("External host").tag(MachineKind.externalHost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(bundled)     // the bundled VM's kind is load-bearing
            }
            if bundled {
                helpNote("This is a bundled machine that ships with the app. Its kind, "
                       + "host, and OS are fixed; attach a disk image here to run it.")
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Connection")
            LabeledField("Host") {
                TextField(draft.kind == .emulatedVM ? "127.0.0.1" : "hostname or IP",
                          text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .disabled(bundled)
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
                Picker("", selection: $draft.transport) {
                    ForEach(LauncherTransport.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            osField
            LabeledField("DISPLAY") {
                TextField("auto (leave blank)", text: Binding(
                    get: { draft.display ?? "" },
                    set: { draft.display = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .help("Override the DISPLAY handed to launched clients. A slirp "
                        + "guest usually wants 10.0.2.2:0.")
            }
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Disk image")
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
            LabeledField("Memory") {
                HStack(spacing: 6) {
                    TextField("128", value: $draft.memoryMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(running)
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            Toggle("Back up the disk image after each clean shutdown",
                   isOn: $draft.autoBackup)
                .onChange(of: draft.autoBackup) { commit() }
            helpNote("Keeps a dated \u{201C}last known good\u{201D} copy next to the image "
                   + "whenever this machine shuts down cleanly. Only the most recent few "
                   + "are kept; manual backups are never pruned.")
            helpNote(runtimeCaption)
        }
    }

    /// The machine's assigned runtime identity (host ports + guest MAC), shown
    /// so the user can see what the tooling should dial. Read-only: ports are
    /// sticky-assigned by the registry, the MAC derives from the machine's id.
    private var runtimeCaption: String {
        let p = draft.resolvedPorts
        return "Ports: telnet \(p.telnet) \u{00B7} ssh \(p.ssh) \u{00B7} helios \(p.helios)"
            + "   MAC: \(draft.resolvedMacAddress)"
    }

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
                        Text(draft.os?.rawValue ?? "unspecified")
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

    /// Lock the OS to the detected value only when we're confident (an image-backed
    /// emulated VM whose image identified a known OS).
    private var osLocked: Bool {
        // A bundled fixture's OS is its fixed identity; otherwise it's locked once
        // it's been derived from an attached image.
        bundled
            || (draft.kind == .emulatedVM && draft.imagePath?.isEmpty == false && osDetection?.os != nil)
    }

    /// Caption under the OS row, only for an image-backed emulated VM (the derived
    /// case): the detection explanation, or a "detecting…" placeholder while it runs.
    private var osCaption: String? {
        guard draft.kind == .emulatedVM, draft.imagePath?.isEmpty == false else { return nil }
        return osDetection?.explanation ?? "Detecting the OS from the image\u{2026}"
    }

    private var launchersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Launchers")
                Spacer()
                Button {
                    launcherEdit = LauncherEditTarget(index: nil,
                                                      launcher: MachineLauncher(name: ""))
                } label: { Label("Add Command", systemImage: "plus") }
                    .controlSize(.small)
            }
            if draft.launchers.isEmpty {
                helpNote("No launchers. Add an X-client command or a Helios file browser.")
            } else {
                ForEach(Array(draft.launchers.enumerated()), id: \.offset) { idx, l in
                    launcherRow(idx: idx, launcher: l)
                    if idx < draft.launchers.count - 1 { Divider() }
                }
            }
        }
    }

    private func launcherRow(idx: Int, launcher l: MachineLauncher) -> some View {
        HStack(spacing: 8) {
            Image(systemName: l.fileBrowser ? "folder" : "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name.isEmpty ? "(unnamed)" : l.name)
                Text(l.fileBrowser ? "Helios file browser" : (l.command ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                launcherEdit = LauncherEditTarget(index: idx, launcher: l)
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button {
                draft.launchers.remove(at: idx)
                commit()
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Commit + validation

    /// Persist the draft if it's changed and valid. Called at edit boundaries
    /// (Return / leaving the pane); an invalid or unchanged draft is a no-op.
    private func commit() {
        guard canCommit else { return }
        model.onCommit?(draft)
        committed = draft
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
        Text(text).font(.headline)
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
/// `onSave`. A file-browser launcher needs no command; a regular one does.
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
                    TextField(draft.fileBrowser ? "(not needed for a file browser)"
                                                : "xterm -fg cyan -bg black",
                              text: Binding(get: { draft.command ?? "" },
                                            set: { draft.command = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(draft.fileBrowser)
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
                    .frame(width: 200)
                }
                GridRow {
                    Text("DISPLAY").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("inherit (leave blank)",
                              text: Binding(get: { draft.display ?? "" },
                                            set: { draft.display = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Helios file browser (no command)", isOn: $draft.fileBrowser)
            Toggle("Show progress window (verbose)", isOn: $draft.verbose)

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
        // A regular launcher needs a command; a file browser doesn't.
        if !draft.fileBrowser, (draft.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }
}
