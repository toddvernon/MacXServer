import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the Helios file browser (the per-launcher "Files…"
// item). SwiftUI content (FileBrowserPanelView) hosted in an NSPanel via
// NSHostingView -- same shape as DnsAdminWindowController. One controller per
// launcher entry; AppDelegate caches them by launcher key so reopening reuses
// the window (and its current folder). The config carries the launcher's
// host/port/user plus a live secret provider, so the window keeps working
// across a guest stop/start.

final class FileBrowserWindowController: NSWindowController {

    init(config: HeliosFileBrowserConfig) {
        let hostingView = NSHostingView(rootView: FileBrowserPanelView(config: config))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "SPARCstation Files: \(config.user)"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 460, height: 380)
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
