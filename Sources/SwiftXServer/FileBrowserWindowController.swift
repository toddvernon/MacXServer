import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the Helios file browser (the per-launcher "Files…"
// item). SwiftUI content (FileBrowserPanelView) hosted in a regular NSWindow
// via NSHostingView. One controller per launcher entry; AppDelegate caches
// them by launcher key so reopening reuses the window (and its current
// folder). The config carries the launcher's host/port/user plus a live
// secret provider, so the window keeps working across a guest stop/start.
//
// Deliberately a normal NSWindow, NOT an NSPanel: a utility panel hides
// whenever the app deactivates, and the browser's whole job is receiving
// drags from Finder -- which requires staying visible while Finder is
// frontmost (Todd, 2026-07-07).

final class FileBrowserWindowController: NSWindowController {

    init(config: HeliosFileBrowserConfig) {
        let hostingView = NSHostingView(rootView: FileBrowserPanelView(config: config))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SPARCstation Files: \(config.user)"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
