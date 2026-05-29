import AppKit
import SwiftUI

// Window controller for the read-only capture viewer. Hosts
// CaptureViewerPanelView in an NSPanel, same shape as the resources / font
// editors. Unlike those singletons, the viewer supports multiple open
// windows (compare two captures), so AppDelegate keeps a list and uses
// `onClose` to drop the controller when its window closes.

final class CaptureViewerWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the window closes so the owner can release this controller.
    var onClose: (() -> Void)?

    init(title: String, sourcePath: String, text: String) {
        let hostingView = NSHostingView(rootView: CaptureViewerPanelView(title: title, sourcePath: sourcePath, text: text))

        // A first-class NSWindow (not a utility NSPanel): it stays on screen
        // when MacXServer isn't the foreground app, so you can read a capture
        // alongside other windows. (.utilityWindow panels hide on deactivate.)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 580, height: 420)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
