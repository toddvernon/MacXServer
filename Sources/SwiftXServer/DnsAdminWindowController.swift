import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the DNS admin editor. SwiftUI content
// (DnsAdminPanelView) hosted in an NSPanel via NSHostingView — same shape as
// ResourcesWindowController. The secret provider is read live on each Helios
// call so the window keeps working across a stop/start (the per-launch secret
// changes), and harmlessly errors into the banner if the guest isn't running.

final class DnsAdminWindowController: NSWindowController {

    init(secretProvider: @escaping () -> String?) {
        let hostingView = NSHostingView(rootView: DnsAdminPanelView(secretProvider: secretProvider))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "SPARCstation Admin: DNS"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 420)
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
