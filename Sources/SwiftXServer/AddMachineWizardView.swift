import SwiftUI
import SwiftXServerCore

/// The Add Machine wizard: the + button's one and only add path (2026-07-15).
/// Before this, integrating a machine meant visiting every tab -- name in the
/// header, host + OS on Settings, user via Change Login on Overview, an xterm
/// launcher on Launchers. Fine if you already know the app, hopeless if you
/// don't. The wizard walks the same facts in order and commits NOTHING until
/// Create, so Cancel never leaves a half-configured machine behind.
///
/// External hosts get the full walk: name -> where -> login (proved with the
/// same probe as Change Login, with the same continue-without-checking hatch
/// for a box that's off the network) -> a pre-filled xterm launcher -> create.
/// Emulated VMs establish ONE thing fast -- hooking up an existing disk image
/// vs creating a new machine from a downloaded starter image -- and get out;
/// the existing first-boot choreography (FirstLogin window, Download button)
/// owns the rest.
struct AddMachineWizardView: View {
    @ObservedObject var model: MachinesModel
    @Environment(\.dismiss) private var dismiss

    /// The wizard's pages, in walk order. VM and external branches share
    /// nameKind and summary.
    private enum Step {
        case nameKind
        case vmSource      // VM branch: existing image vs downloaded starter
        case host          // external branch from here down
        case login
        case launcher
        case summary
    }
    @State private var step: Step = .nameKind

    // Step 1: name + kind.
    @State private var name = ""
    @State private var kind: MachineKind = .externalHost
    @FocusState private var nameFocused: Bool

    // External branch: where + OS.
    @State private var host = ""
    @State private var os: MachineOS?

    // External branch: login. Same shape as ChangeLoginSheet: the proof runs
    // on Continue, a rejection is authoritative (retype), and only a proof
    // that couldn't run unlocks Continue Without Checking.
    @State private var transport: LauncherTransport = .telnet
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: VerifyLoginFailure?
    /// Set on every telnet login proof that produced output: the probe's
    /// best guess at the shell prompt (the last visible line), shown for the
    /// user to validate. Always asked -- recognition heuristics are tuned on
    /// our own fleet's prompts, so a match improves the prefill but never
    /// silently skips the question (Todd, 2026-07-15). The confirmed text
    /// becomes the machine's shellPrompt, the needle launches wait for.
    @State private var suspectedPrompt: String?
    @State private var promptText = ""
    /// What the user actually confirmed (Continue past the prompt question):
    /// this is what Create stores as shellPrompt. Separate from promptText so
    /// a re-proof or a back-step can't smuggle stale field text onto the
    /// machine.
    @State private var confirmedPrompt: String?

    // External branch: the first launcher.
    @State private var makeXterm = true
    @State private var xtermCommand = "xterm"

    // VM branch.
    private enum VMSource { case existingImage, downloadStarter }
    @State private var vmSource: VMSource = .existingImage
    @State private var imagePath: String?
    @State private var detection: GuestOSDetection?
    /// The seed path's OS pick (drives which starter image downloads).
    @State private var seedOS: MachineOS = .solaris26

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Machine").font(.title3.weight(.semibold))
            stepBody
            Spacer(minLength: 0)
            buttonRow
        }
        .padding(20)
        .frame(width: 460, height: 380, alignment: .top)
        .onAppear {
            // Async hop so the field exists before focus is asked for
            // (NSPanel-hosted sheet).
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: Steps

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .nameKind: nameKindStep
        case .vmSource: vmSourceStep
        case .host:     hostStep
        case .login:    loginStep
        case .launcher: launcherStep
        case .summary:  summaryStep
        }
    }

    private var nameKindStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("What should this machine be called, and what is it?")
            TextField("Machine name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Picker("", selection: $kind) {
                Text("External host").tag(MachineKind.externalHost)
                Text("Emulated VM").tag(MachineKind.emulatedVM)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption(kind == .externalHost
                ? "A real machine on your network that this app connects to."
                : "A SPARCstation that runs right here on your Mac.")
        }
    }

    private var vmSourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Does this machine already have a disk image?")
            Picker("", selection: $vmSource) {
                Text("Use an existing disk image").tag(VMSource.existingImage)
                Text("Download a starter system").tag(VMSource.downloadStarter)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if vmSource == .existingImage {
                HStack(spacing: 8) {
                    Button("Choose\u{2026}") { pickImage() }
                    Text(imagePath.map { ($0 as NSString).lastPathComponent }
                         ?? "No image chosen")
                        .foregroundStyle(imagePath == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let detection {
                    caption(detection.explanation)
                }
                if let claimant = imageClaimantName {
                    errorText("\u{201C}\(claimant)\u{201D} already uses that image. "
                            + "Two machines can\u{2019}t share one disk.")
                }
                if imagePath != nil, detection?.os == nil {
                    LabeledContent("OS") { osPicker($os, emulatableOnly: true) }
                }
            } else {
                LabeledContent("System") {
                    Picker("", selection: $seedOS) {
                        // Starter images exist only for the emulatable OSes.
                        ForEach(MachineOS.allCases.filter { $0.emulatable }, id: \.self) { os in
                            Text(os.displayName).tag(os)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                caption("A ready-to-boot starter image downloads after the "
                      + "machine is created.")
            }
        }
    }

    private var hostStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Where is \(displayNameOrIt) on your network?")
            TextField("hostname or IP", text: $host)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            LabeledContent("OS") { osPicker($os) }
            caption("The OS tells the app where that system keeps its X "
                  + "programs and how to talk to it. \u{201C}Not sure\u{201D} "
                  + "is fine \u{2014} it can be set later in Settings.")
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("How should launchers sign in to \(displayNameOrIt)?")
            Picker("", selection: $transport) {
                Text("Telnet").tag(LauncherTransport.telnet)
                Text("SSH").tag(LauncherTransport.ssh)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: transport) { failure = nil; suspectedPrompt = nil }
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: username) { suspectedPrompt = nil }
            if transport != .ssh {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: password) { suspectedPrompt = nil }
            } else {
                caption("SSH signs in with your ssh key; no password is stored. "
                      + "The login is checked with the key before continuing.")
            }
            if suspectedPrompt != nil {
                // Login proved, prompt shape unrecognized: show what the
                // machine ended with and let the user fix it, instead of
                // asking them to know their prompt cold (Todd, 2026-07-15).
                Text("Signed in. \(displayNameOrIt)\u{2019}s command prompt "
                     + "looks like this:")
                    .font(.callout)
                LabeledContent("Prompt") {
                    TextField("", text: $promptText)
                        .textFieldStyle(.roundedBorder)
                }
                caption("Launchers wait for this text to know the machine is "
                      + "ready for a command. Edit it down to just the last "
                      + "few characters that are unique to the prompt; "
                      + "that\u{2019}s all that gets matched. If it isn\u{2019}t "
                      + "the prompt at all (a message that printed after "
                      + "signing in), replace it.")
            }
            if let failure {
                errorText(failure.message)
                if failure.canSaveUnverified {
                    // Same hatch as Change Login (Todd's wording 2026-07-15):
                    // one affirmative button, relabeled -- never a silent
                    // fallback.
                    caption("You can continue without checking it. The login "
                          + "is used as-is the next time the machine is on "
                          + "the network; if it\u{2019}s wrong, launchers "
                          + "will fail to sign in until it\u{2019}s corrected.")
                }
            }
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Signing in\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var launcherStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Create the first launcher?")
            Toggle("Create an xterm launcher", isOn: $makeXterm)
            if makeXterm {
                LabeledContent("Command") {
                    TextField("xterm", text: $xtermCommand)
                        .textFieldStyle(.roundedBorder)
                }
                caption("Runs on \(displayNameOrIt) with its windows on this "
                      + "Mac. The system\u{2019}s X program folders are on "
                      + "the path, so a bare command name works.")
            } else {
                caption("Launchers can be added any time on the machine\u{2019}s "
                      + "Launchers tab.")
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            subtitle("Ready to create:")
            summaryLine("Name", name.trimmingCharacters(in: .whitespaces))
            if kind == .externalHost {
                summaryLine("Host", host.trimmingCharacters(in: .whitespaces))
                summaryLine("OS", os?.displayName ?? "not set")
                summaryLine("Login", "\(username) over \(transport.displayName)"
                            + (failure?.canSaveUnverified == true ? " (not checked)" : ""))
                if let confirmedPrompt { summaryLine("Prompt", confirmedPrompt) }
                if makeXterm { summaryLine("Launcher", "xterm") }
            } else if vmSource == .existingImage {
                summaryLine("Disk image",
                            imagePath.map { ($0 as NSString).lastPathComponent } ?? "")
                summaryLine("OS", (detection?.os ?? os)?.displayName ?? "not set")
                caption("It boots from this image. The active user is set at "
                      + "first boot.")
            } else {
                summaryLine("System", seedOS.displayName)
                caption("The starter image download begins as soon as the "
                      + "machine is created.")
            }
        }
    }

    // MARK: Navigation

    private var buttonRow: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(busy)
            Spacer()
            if step != .nameKind {
                Button("Back") { goBack() }.disabled(busy)
            }
            Button(forwardLabel) { goForward() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canGoForward || busy)
        }
    }

    /// One affirmative button, two meanings on the login step (the Change
    /// Login pattern): normally Continue runs the proof; after an unreachable
    /// failure it relabels and skips the check.
    private var forwardLabel: String {
        if step == .summary { return "Create" }
        if step == .login, failure?.canSaveUnverified == true {
            return "Continue Without Checking"
        }
        return "Continue"
    }

    private var canGoForward: Bool {
        switch step {
        case .nameKind:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .vmSource:
            if vmSource == .existingImage {
                return imagePath != nil && imageClaimantName == nil
            }
            return true
        case .host:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .login:
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
                && (transport == .ssh || !password.isEmpty)
        case .launcher:
            return !makeXterm
                || !xtermCommand.trimmingCharacters(in: .whitespaces).isEmpty
        case .summary:
            return true
        }
    }

    private func goForward() {
        switch step {
        case .nameKind:
            step = kind == .externalHost ? .host : .vmSource
        case .vmSource:
            step = .summary
        case .host:
            step = .login
        case .login:
            if suspectedPrompt != nil {
                // Prompt confirmed; the proof already ran. An emptied field
                // means "not sure" -- store nothing, launches fall back to
                // the generic detection.
                let trimmed = promptText.trimmingCharacters(in: .whitespaces)
                confirmedPrompt = trimmed.isEmpty ? nil : trimmed
                step = .launcher
            } else if failure?.canSaveUnverified == true {
                step = .launcher   // the explicit unchecked path
            } else {
                runLoginProof()    // advances itself on success
            }
        case .launcher:
            step = .summary
        case .summary:
            create()
        }
    }

    private func goBack() {
        switch step {
        case .nameKind: break
        case .vmSource: step = .nameKind
        case .host:     step = .nameKind
        case .login:    step = .host
        case .launcher: step = .login
        case .summary:  step = kind == .externalHost ? .launcher : .vmSource
        }
        // A different page means a different question; stale proof errors
        // shouldn't follow the user around. The suspected prompt goes too --
        // stepping back to the login page means re-proving, which regathers it.
        failure = nil
        suspectedPrompt = nil
        busy = false
    }

    // MARK: Actions

    private func runLoginProof() {
        busy = true
        failure = nil
        suspectedPrompt = nil
        confirmedPrompt = nil
        model.onProbeLoginEndpoint?(host.trimmingCharacters(in: .whitespaces),
                                    transport,
                                    username.trimmingCharacters(in: .whitespaces),
                                    password) { result, suspected in
            busy = false
            if let result {
                failure = result   // rejection: retype; unreachable: hatch
            } else if let suspected, !suspected.isEmpty {
                // Signed in, but the prompt shape wasn't recognized: stay
                // here and ask the user to validate the probe's guess before
                // moving on (it becomes the machine's launch-time needle).
                failure = nil
                suspectedPrompt = suspected
                promptText = suspected
            } else {
                failure = nil
                step = .launcher
            }
        }
    }

    private func pickImage() {
        guard let path = model.onPickImage?() else { return }
        imagePath = path
        detection = nil
        Task {
            let result = await Task.detached { GuestOSDetector.detect(imagePath: path) }.value
            guard imagePath == path else { return }   // re-picked mid-scan
            detection = result
        }
    }

    /// The other machine already claiming the chosen image, if any. The
    /// excluding id is fresh -- this machine doesn't exist yet, so nothing
    /// legitimate is excluded.
    private var imageClaimantName: String? {
        guard let path = imagePath else { return nil }
        return model.imageClaimant?(path, UUID())
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var m: Machine
        var telnetPassword: String?
        var startDownload = false
        switch kind {
        case .externalHost:
            m = Machine(name: trimmedName, kind: .externalHost, os: os,
                        host: host.trimmingCharacters(in: .whitespaces),
                        user: username.trimmingCharacters(in: .whitespaces),
                        transport: transport,
                        shellPrompt: confirmedPrompt)
            if makeXterm {
                m.launchers = [MachineLauncher(
                    name: "xterm",
                    command: xtermCommand.trimmingCharacters(in: .whitespaces))]
            }
            // ssh proves a key, not a password -- store nothing (the Change
            // Login doctrine).
            if transport != .ssh { telnetPassword = password }
        case .emulatedVM:
            switch vmSource {
            case .existingImage:
                m = Machine(name: trimmedName, kind: .emulatedVM,
                            os: detection?.os ?? os, host: "", user: "",
                            imagePath: imagePath)
            case .downloadStarter:
                m = Machine(name: trimmedName, kind: .emulatedVM, os: seedOS,
                            host: "", user: "")
                startDownload = true
            }
        }
        guard let id = model.onWizardCreate?(m, telnetPassword) else {
            dismiss()
            return
        }
        let model = self.model
        dismiss()
        // Select (and kick the download) after the sheet is gone -- both
        // republish the model, and dismiss runs inside a view update.
        DispatchQueue.main.async {
            model.selection = id
            if startDownload { model.onDownload?(id) }
        }
    }

    // MARK: Small pieces

    private var displayNameOrIt: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "it" : trimmed
    }

    private func subtitle(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
        }
        .font(.callout)
    }

    /// `emulatableOnly` for the qcow2-image branch (a SPARC disk can't hold
    /// an external-only OS like IRIX); the external-host step shows them all.
    private func osPicker(_ selection: Binding<MachineOS?>,
                          emulatableOnly: Bool = false) -> some View {
        Picker("", selection: selection) {
            Text("Not sure").tag(MachineOS?.none)
            ForEach(MachineOS.allCases.filter { !emulatableOnly || $0.emulatable },
                    id: \.self) { os in
                Text(os.displayName).tag(MachineOS?.some(os))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
