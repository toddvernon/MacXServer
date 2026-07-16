import SwiftUI
import SwiftXServerCore

/// The starter-image install wizard: the imageless bundled machine's one
/// path from marketing pane to running SPARCstation (DECISIONS 2026-07-16 --
/// the Add Machine wizard proved the pattern in the field, superseding the
/// 2026-07-10 in-window bubble flow). Walks the three facts the stranger
/// flow needs -- where the disk image lives, the login to create, an
/// optional DNS server -- and commits NOTHING until Install & Boot, so
/// Cancel never leaves half-configured state. The download, boot, and
/// deferred account creation stay the proven 2026-07-10 machinery; the
/// wizard just collects everything up front so the user never revisits a
/// panel mid-flow.
struct InstallStarterWizardView: View {
    /// The imageless machine being installed (its OS keys the catalog).
    let machineID: UUID
    let machineName: String
    /// Guest OS display name for the copy ("Solaris 2.6", ...).
    let osName: String
    @ObservedObject var model: MachinesModel
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case location
        case login
        case network
        case summary
    }
    @State private var step: Step = .location

    // Step 1: where the disk image lives.
    @State private var imagesDir = ""

    // Step 2: the login created on the machine at first boot.
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var usernameFocused: Bool

    // Step 3: guest DNS. Default = leave the built-in network alone.
    private enum DNSChoice { case builtIn, custom }
    @State private var dnsChoice: DNSChoice = .builtIn
    @State private var dnsServer = ""

    init(machineID: UUID, machineName: String, osName: String,
         model: MachinesModel) {
        self.machineID = machineID
        self.machineName = machineName
        self.osName = osName
        self.model = model
        // Prefills: the effective images directory, and the Mac's short
        // login name cleaned to the vintage-Unix username rules.
        _imagesDir = State(initialValue: model.imagesDirectory?() ?? "")
        let suggested = String(NSUserName().lowercased()
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }
            .prefix(8))
        _username = State(initialValue: suggested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install \(osName)").font(.title3.weight(.semibold))
            stepBody
            Spacer(minLength: 0)
            buttonRow
        }
        .padding(20)
        .frame(width: 460, height: 400, alignment: .top)
    }

    // MARK: Steps

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .location: locationStep
        case .login:    loginStep
        case .network:  networkStep
        case .summary:  summaryStep
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Where should the disk image be kept?")
            HStack(spacing: 8) {
                Button("Choose\u{2026}") {
                    if let dir = model.onPickImagesDirectory?() { imagesDir = dir }
                }
                Text(imagesDir)
                    .lineLimit(1).truncationMode(.middle)
            }
            caption("The default is fine. This folder holds the machine\u{2019}s "
                  + "hard disk (about 1.3 GB) \u{2014} downloaded images for "
                  + "other machines go here too.")
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Create your login on \(machineName).")
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($usernameFocused)
                .onChange(of: username) {
                    let cleaned = username.lowercased()
                        .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }
                    username = String(cleaned.prefix(8))
                }
            if let problem = usernameProblem {
                errorText(problem)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $confirm)
                .textFieldStyle(.roundedBorder)
            if !confirm.isEmpty && password != confirm {
                errorText("Passwords don\u{2019}t match.")
            }
            caption("The account is created on the machine the first time it "
                  + "boots. Vintage Unix reads only the first 8 characters of "
                  + "the password.")
        }
    }

    private var networkStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            subtitle("Network")
            Picker("", selection: $dnsChoice) {
                Text("Use the built-in network (recommended)").tag(DNSChoice.builtIn)
                Text("Also point it at my own DNS server").tag(DNSChoice.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if dnsChoice == .custom {
                TextField("DNS server address", text: $dnsServer)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            caption(dnsChoice == .builtIn
                ? "The machine shares this Mac\u{2019}s connection and looks up "
                  + "names through public resolvers. Nothing to configure."
                : "The machine\u{2019}s name lookups go to this server instead. "
                  + "It\u{2019}s written to the machine at first boot and can be "
                  + "changed later from the DNS panel.")
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            subtitle("Ready to install:")
            summaryLine("System", osName)
            summaryLine("Disk image", (imagesDir as NSString).abbreviatingWithTildeInPath)
            summaryLine("Your login", username)
            summaryLine("DNS", dnsChoice == .custom
                        ? dnsServer.trimmingCharacters(in: .whitespaces)
                        : "built-in")
            caption("Downloads the starter system (about 250 MB), then the "
                  + "machine boots and your login is created automatically. "
                  + "The first boot takes a couple of minutes.")
        }
    }

    // MARK: Navigation

    private var buttonRow: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .location {
                Button("Back") { goBack() }
            }
            Button(step == .summary ? "Install & Boot" : "Continue") { goForward() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canGoForward)
        }
    }

    private var usernameProblem: String? {
        username.isEmpty ? nil : UserAdmin.usernameProblem(username)
    }

    private var canGoForward: Bool {
        switch step {
        case .location:
            return !imagesDir.trimmingCharacters(in: .whitespaces).isEmpty
        case .login:
            return !username.isEmpty && usernameProblem == nil
                && !password.isEmpty && password == confirm
        case .network:
            return dnsChoice == .builtIn
                || !dnsServer.trimmingCharacters(in: .whitespaces).isEmpty
        case .summary:
            return true
        }
    }

    private func goForward() {
        switch step {
        case .location:
            step = .login
            DispatchQueue.main.async { usernameFocused = true }
        case .login:
            step = .network
        case .network:
            step = .summary
        case .summary:
            install()
        }
    }

    private func goBack() {
        switch step {
        case .location: break
        case .login:    step = .location
        case .network:  step = .login
        case .summary:  step = .network
        }
    }

    private func install() {
        let dns = dnsChoice == .custom
            ? dnsServer.trimmingCharacters(in: .whitespaces)
            : nil
        let dir = imagesDir.trimmingCharacters(in: .whitespaces)
        let model = self.model
        let id = machineID
        let user = username
        let pass = password
        dismiss()
        // Kick after the sheet is gone -- the install republishes the model,
        // and dismiss runs inside a view update (the Add Machine wizard's
        // same ordering).
        DispatchQueue.main.async {
            model.onInstallStarter?(id, dir, user, pass, dns)
        }
    }

    // MARK: Small pieces

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
}
