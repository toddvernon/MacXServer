import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the Clock admin panel. Same shape as
// UsersWindowController: SwiftUI content (ClockPanelView) in an NSPanel via
// NSHostingView, providers read the registry live so the window survives a
// guest stop/start (per-boot secret) and host edits. Keyed per machine in
// AppDelegate so repeated clicks focus the existing window.

final class ClockWindowController: NSWindowController {

    init(machineName: String,
         osProvider: @escaping () -> MachineOS?,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: ClockPanelView(
            machineName: machineName,
            osProvider: osProvider,
            secretProvider: secretProvider,
            hostProvider: hostProvider,
            portProvider: portProvider,
            onDismiss: { [weak panel] in panel?.close() }))

        panel.title = "\(machineName) Admin: Clock"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
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
