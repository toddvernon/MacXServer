import SwiftUI
import AppKit
import SwiftXServerCore

// Users admin panel: list / add / delete accounts on a guest over the Helios
// daemon, driven by UserAdmin (SwiftXServerCore). Same window/model/threading
// shape as DnsAdminPanelView (blocking HeliosClient on a background queue,
// hop back to the main actor), but the payload is the account list and the
// two sheets rather than a text editor. The per-OS mechanics all live in
// UserAdmin; this file is purely UI + the off-main plumbing.

struct UsersPanelView: View {

    @StateObject private var model: UsersPanelModel
    private let machineName: String
    private let onDismiss: (() -> Void)?

    init(machineName: String,
         osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16,
         activeUserProvider: @escaping () -> String,
         onSetActiveUser: @escaping (_ user: String, _ password: String) -> Void,
         onDismiss: (() -> Void)? = nil) {
        self.machineName = machineName
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: UsersPanelModel(
            osProvider: osProvider, secretProvider: secretProvider,
            hostProvider: hostProvider, portProvider: portProvider,
            activeUserProvider: activeUserProvider,
            onSetActiveUser: onSetActiveUser))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            userList
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { model.load() }
        .sheet(isPresented: $model.showingAdd) {
            AddUserSheet(model: model)
        }
        .sheet(isPresented: $model.showingSetActive) {
            SetActiveUserSheet(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Users").font(.title2)
                Text("Accounts on \(machineName). Changes here are made as "
                     + "root over the admin connection; launchers log in as "
                     + "the account marked active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Show system accounts", isOn: $model.showSystemAccounts)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    // MARK: List

    private var userList: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleUsers, id: \.name) { u in
                UserRow(entry: u,
                        isActiveUser: u.name == model.activeUserProvider(),
                        deletable: model.isDeletable(u))
                    .tag(u.name)
            }
        }
        .frame(minHeight: 220)
        .overlay {
            if model.visibleUsers.isEmpty && !model.busy {
                Text("No accounts loaded.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.transcript).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Button("Dismiss") { onDismiss?() }
                .keyboardShortcut(.cancelAction)
            Button("Set Active\u{2026}") { model.beginSetActive() }
                .disabled(!model.canSetActiveSelection || model.busy)
            Button("Delete\u{2026}") { model.confirmDelete() }
                .disabled(!model.canDeleteSelection || model.busy)
            Button("Reload") { model.load() }.disabled(model.busy)
            Button("Add User\u{2026}") { model.beginAdd() }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
        }
    }

    private var bannerRow: some View {
        Text(model.banner.isEmpty ? " " : model.banner)
            .font(.caption)
            .foregroundStyle(model.bannerIsError ? .red : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

private struct UserRow: View {
    let entry: PasswdEntry
    let isActiveUser: Bool
    let deletable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.uid == 0 ? "crown" : "person")
                .foregroundStyle(deletable ? .primary : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(deletable ? .regular : .medium)
                    if isActiveUser {
                        Text("active").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18),
                                        in: Capsule())
                    }
                }
                if !entry.gecos.isEmpty {
                    Text(entry.gecos).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("uid \(entry.uid)").font(.caption).foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .foregroundStyle(deletable ? .primary : .secondary)
    }
}

// MARK: - Add sheet

private struct AddUserSheet: View {
    @ObservedObject var model: UsersPanelModel
    @State private var username = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var setActive = true

    private var usernameProblem: String? {
        username.isEmpty ? nil : UserAdmin.usernameProblem(username)
    }
    private var passwordsMatch: Bool { password == confirm }
    private var canSubmit: Bool {
        !username.isEmpty && usernameProblem == nil
            && !password.isEmpty && passwordsMatch && !model.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a user").font(.title3.weight(.semibold))

            Form {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .onChange(of: username) {
                        // Normalize at the edit boundary: lowercase, drop the
                        // bytes the rules forbid, cap at 8 (UserAdmin's rule).
                        let cleaned = username.lowercased()
                            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }
                        username = String(cleaned.prefix(8))
                    }
                if let problem = usernameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                TextField("Full name (optional)", text: $fullName)
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirm)
                if !confirm.isEmpty && !passwordsMatch {
                    Text("Passwords don\u{2019}t match.").font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Vintage Unix reads only the first 8 characters of the "
                     + "password.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Make this the active user (launchers log in as it)",
                       isOn: $setActive)
            }
            .formStyle(.grouped)

            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.transcript).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button("Cancel") { model.cancelAdd() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Button("Add") {
                    model.submitAdd(username: username, fullName: fullName,
                                    password: password, setActive: setActive)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Set Active sheet

/// Switching the active user requires proving you know the account's password
/// (it lands in the launcher Keychain slot, so a wrong one would break every
/// launcher). Verified against the guest's stored hash before anything is
/// adopted.
private struct SetActiveUserSheet: View {
    @ObservedObject var model: UsersPanelModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set the active user").font(.title3.weight(.semibold))
            Text("Launchers will log in as "
                 + "\u{201C}\(model.selection ?? "")\u{201D} from now on. "
                 + "Enter the account\u{2019}s password to switch.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if !model.setActiveError.isEmpty {
                Text(model.setActiveError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Checking the password\u{2026}")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelSetActive() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Button("Set Active") { model.submitSetActive(password: password) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.busy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Marshals UserAdmin's synchronous, off-main progress callbacks onto the main
/// actor without the work closure having to capture the @MainActor model
/// directly (which the concurrency checker rejects as "sending self"). Holds
/// the model weakly and hops each line to main.
private final class TranscriptRelay: @unchecked Sendable {
    weak var model: UsersPanelModel?
    init(_ model: UsersPanelModel) { self.model = model }
    func post(_ line: String) {
        DispatchQueue.main.async { [weak model] in model?.transcript = line }
    }
}

// MARK: - View model

@MainActor
final class UsersPanelModel: ObservableObject {

    @Published var users: [PasswdEntry] = []
    @Published var selection: String?
    @Published var showSystemAccounts = false
    @Published var busy = false
    @Published var banner = ""
    @Published var bannerIsError = false
    @Published var transcript = ""
    @Published var showingAdd = false
    @Published var showingSetActive = false
    @Published var setActiveError = ""

    let activeUserProvider: () -> String
    private let osProvider: () -> MachineOS?
    private let secretProvider: () -> String?
    private let hostProvider: () -> String
    private let portProvider: () -> UInt16
    private let onSetActiveUser: (String, String) -> Void

    init(osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16,
         activeUserProvider: @escaping () -> String,
         onSetActiveUser: @escaping (String, String) -> Void) {
        self.osProvider = osProvider
        self.secretProvider = secretProvider
        self.hostProvider = hostProvider
        self.portProvider = portProvider
        self.activeUserProvider = activeUserProvider
        self.onSetActiveUser = onSetActiveUser
    }

    // MARK: Derived

    /// System accounts (uid < 100) hidden unless the toggle is on; template is
    /// always shown but dimmed (it's the stamp, not a login).
    var visibleUsers: [PasswdEntry] {
        users.filter { showSystemAccounts || $0.uid >= 100 }
    }

    /// Deletable = not root, not template, uid >= 100. Mirrors UserAdmin's own
    /// refusals so the button dims instead of erroring.
    func isDeletable(_ u: PasswdEntry) -> Bool {
        u.uid >= 100 && u.name != "root" && u.name != "template"
    }

    var canDeleteSelection: Bool {
        guard let name = selection,
              let u = users.first(where: { $0.name == name }) else { return false }
        return isDeletable(u)
    }

    /// Any real selected account can become active except `template` (it's
    /// locked, so its password can never verify) and the one already active.
    /// root is allowed on purpose.
    var canSetActiveSelection: Bool {
        guard let name = selection,
              users.contains(where: { $0.name == name }) else { return false }
        return name != "template" && name != activeUserProvider()
    }

    // MARK: Load

    func load() {
        guard !busy else { return }
        busy = true
        setBanner("Reading the account list\u{2026}", error: false)
        let secret = secretProvider(), host = hostProvider(), port = portProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[PasswdEntry], Error>
            let client = HeliosClient(host: host, port: port, timeout: 60, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.hello()
                outcome = .success(try UserAdmin.listUsers(transport: client))
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let list):
                    self.users = list
                    self.setBanner("\(self.visibleUsers.count) account(s).", error: false)
                case .failure(let error):
                    self.setBanner("Couldn\u{2019}t read the account list: "
                                   + Self.describe(error), error: true)
                }
            }
        }
    }

    // MARK: Add

    func beginAdd() { showingAdd = true; transcript = "" }
    func cancelAdd() { if !busy { showingAdd = false } }

    func submitAdd(username: String, fullName: String, password: String,
                   setActive: Bool) {
        guard !busy else { return }
        guard let os = osProvider() else {
            setBanner("This machine\u{2019}s OS isn\u{2019}t known, so users "
                      + "can\u{2019}t be managed.", error: true)
            return
        }
        busy = true
        transcript = ""
        // Hash host-side: the cleartext never crosses the wire (only the
        // Keychain, via onSetActiveUser, keeps it).
        let hash = UserAdmin.desHash(password: password)
        let req = UserAdmin.AddRequest(name: username, gecos: fullName, hash: hash)
        let secret = secretProvider(), host = hostProvider(), port = portProvider()
        let relay = TranscriptRelay(self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Int, Error>
            let client = HeliosClient(host: host, port: port, timeout: 60, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.hello()
                let uid = try UserAdmin.addUser(req, os: os, transport: client,
                                                progress: { relay.post($0) })
                outcome = .success(uid)
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success:
                    if setActive { self.onSetActiveUser(username, password) }
                    self.showingAdd = false
                    self.setBanner("Added \u{201C}\(username)\u{201D}.", error: false)
                    self.load()
                case .failure(let error):
                    // Stay on the sheet so the user can fix and retry.
                    self.transcript = ""
                    self.setBanner("Add failed: " + Self.describe(error), error: true)
                }
            }
        }
    }

    // MARK: Set active

    func beginSetActive() {
        guard canSetActiveSelection else { return }
        setActiveError = ""
        showingSetActive = true
    }

    func cancelSetActive() { if !busy { showingSetActive = false } }

    /// Verify the password against the guest's stored hash, then adopt the
    /// account as the machine's active user (machine.user + telnet Keychain,
    /// via onSetActiveUser -> adoptMachineLogin). Nothing on the guest
    /// changes; a wrong password changes nothing anywhere.
    func submitSetActive(password: String) {
        guard !busy, let name = selection else { return }
        guard let os = osProvider() else {
            setActiveError = "This machine\u{2019}s OS isn\u{2019}t known, so "
                + "the password can\u{2019}t be checked."
            return
        }
        busy = true
        setActiveError = ""
        let secret = secretProvider(), host = hostProvider(), port = portProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Bool, Error>
            let client = HeliosClient(host: host, port: port, timeout: 60, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.hello()
                outcome = .success(try UserAdmin.verifyPassword(
                    name: name, password: password, os: os, transport: client))
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(true):
                    self.onSetActiveUser(name, password)
                    self.showingSetActive = false
                    self.setBanner("\u{201C}\(name)\u{201D} is now the active "
                                   + "user; launchers log in as it.", error: false)
                case .success(false):
                    // Stay on the sheet; wrong password is the retry case.
                    self.setActiveError = "That isn\u{2019}t "
                        + "\u{201C}\(name)\u{201D}\u{2019}s password."
                case .failure(let error):
                    self.setActiveError = Self.describe(error)
                }
            }
        }
    }

    // MARK: Delete

    func confirmDelete() {
        guard let name = selection, canDeleteSelection, let os = osProvider() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the account \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This removes the login from \(hostProvider() == "127.0.0.1" ? "the machine" : hostProvider())."
            + (name == activeUserProvider()
               ? "\n\nThis is the machine\u{2019}s active user, the account "
               + "launchers log in as; you\u{2019}ll need to set another "
               + "account active afterward."
               : "")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // A separate checkbox so removing a login never silently destroys files.
        let check = NSButton(checkboxWithTitle: "Also delete the home directory "
                             + "(/home/\(name))", target: nil, action: nil)
        check.state = .off
        alert.accessoryView = check
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteUser(name: name, removeHome: check.state == .on, os: os)
    }

    private func deleteUser(name: String, removeHome: Bool, os: MachineOS) {
        busy = true
        transcript = ""
        let secret = secretProvider(), host = hostProvider(), port = portProvider()
        let relay = TranscriptRelay(self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Void, Error>
            let client = HeliosClient(host: host, port: port, timeout: 60, secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.hello()
                try UserAdmin.deleteUser(name: name, os: os, removeHome: removeHome,
                                         transport: client, progress: { relay.post($0) })
                outcome = .success(())
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success:
                    self.setBanner("Removed \u{201C}\(name)\u{201D}.", error: false)
                    self.load()
                case .failure(let error):
                    self.setBanner("Delete failed: " + Self.describe(error), error: true)
                }
            }
        }
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message; bannerIsError = error
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? UserAdminError { return e.errorDescription ?? "\(e)" }
        if let e = error as? HeliosClient.HeliosError { return e.errorDescription ?? "\(e)" }
        return error.localizedDescription
    }
}
