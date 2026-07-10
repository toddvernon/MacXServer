import AppKit
import SwiftUI
import SwiftXServerCore

// The "one more thing -- add a user" step of the first-run flow
// (FIRST_RUN_EXPERIENCE.md). Shown right after a starter image finishes
// downloading, before the machine's first boot. Collects a username + password
// for the account the pipeline will create on the guest once it reaches ready;
// on submit the caller boots the VM and applies the login at ready
// (deferred-apply -- the helios daemon must be answering before /etc/passwd
// can be touched). Deliberately a small dedicated panel, not the full Users
// admin panel: this is one focused step in a guided flow.

final class FirstLoginWindowController: NSWindowController {

    /// `onCreate(username, password)` fires when the user commits; the caller
    /// boots + defers the add-user pipeline. `onSkip` closes without a login
    /// (the machine stays user-less and the flow re-offers on next ready).
    init(machineName: String,
         suggestedUsername: String,
         onCreate: @escaping (_ username: String, _ password: String) -> Void,
         onSkip: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Add a User"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        let view = FirstLoginView(
            machineName: machineName,
            suggestedUsername: suggestedUsername,
            create: { [weak self] user, pass in self?.close(); onCreate(user, pass) },
            skip: { [weak self] in self?.close(); onSkip() })
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FirstLoginView: View {
    let machineName: String
    let suggestedUsername: String
    let create: (String, String) -> Void
    let skip: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var confirm = ""

    init(machineName: String, suggestedUsername: String,
         create: @escaping (String, String) -> Void, skip: @escaping () -> Void) {
        self.machineName = machineName
        self.suggestedUsername = suggestedUsername
        self.create = create
        self.skip = skip
        _username = State(initialValue: suggestedUsername)
    }

    private var usernameProblem: String? {
        username.isEmpty ? nil : UserAdmin.usernameProblem(username)
    }
    private var passwordsMatch: Bool { password == confirm }
    private var canCreate: Bool {
        !username.isEmpty && usernameProblem == nil
            && !password.isEmpty && passwordsMatch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("One more thing \u{2014} add a user")
                        .font(.title3.weight(.semibold))
                    Text("The image downloaded. Create your login on "
                         + "\(machineName), and it will boot with your account.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .onChange(of: username) {
                        let cleaned = username.lowercased()
                            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }
                        username = String(cleaned.prefix(8))
                    }
                if let problem = usernameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirm)
                if !confirm.isEmpty && !passwordsMatch {
                    Text("Passwords don\u{2019}t match.").font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Vintage Unix reads only the first 8 characters of the "
                     + "password. The machine takes a couple of minutes to boot "
                     + "the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Skip for Now") { skip() }
                    .keyboardShortcut(.cancelAction)
                Button("Add User & Start") { create(username, password) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
