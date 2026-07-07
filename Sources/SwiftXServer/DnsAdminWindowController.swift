import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the DNS admin editor. SwiftUI content
// (DnsAdminPanelView) hosted in an NSPanel via NSHostingView — same shape as
// ResourcesWindowController. The secret provider is read live on each Helios
// call so the window keeps working across a stop/start (the per-launch secret
// changes), and harmlessly errors into the banner if the guest isn't running.

final class DnsAdminWindowController: NSWindowController {

    init(machineName: String,
         secretProvider: @escaping () -> String?,
         hostProvider: @escaping () -> String,
         portProvider: @escaping () -> UInt16) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // A successful Apply is the natural end of the task, so the window
        // dismisses itself; failures keep it open with the error banner. The
        // Dismiss button (Esc) closes without applying.
        let hostingView = NSHostingView(rootView: DnsAdminPanelView(
            machineName: machineName,
            secretProvider: secretProvider, hostProvider: hostProvider,
            portProvider: portProvider,
            onApplied: { [weak panel] in panel?.close() },
            onDismiss: { [weak panel] in panel?.close() }))

        panel.title = "\(machineName) Admin: DNS"
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
