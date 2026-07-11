import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the Users admin panel. Same shape as
// DnsAdminWindowController: SwiftUI content (UsersPanelView) in an NSPanel via
// NSHostingView, all providers read the registry live so the window survives a
// guest stop/start (per-boot secret) and host/user edits. Keyed per machine in
// AppDelegate so repeated clicks focus the existing window.

final class UsersWindowController: NSWindowController {

    init(machineName: String,
         osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16,
         activeUserProvider: @escaping () -> String,
         onSetActiveUser: @escaping (_ user: String, _ password: String) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: UsersPanelView(
            machineName: machineName,
            osProvider: osProvider,
            secretProvider: secretProvider,
            hostProvider: hostProvider,
            portProvider: portProvider,
            activeUserProvider: activeUserProvider,
            onSetActiveUser: onSetActiveUser,
            onDismiss: { [weak panel] in panel?.close() }))

        panel.title = "\(machineName) Admin: Users"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 420)
        panel.center()

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
