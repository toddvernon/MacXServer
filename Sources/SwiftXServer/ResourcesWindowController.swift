import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the resources editor. SwiftUI content
// (ResourcesPanelView) hosted in an NSPanel via NSHostingView —
// same shape Covey uses for its panels.
//
// Not nonactivating: the editor needs keyboard focus, so the panel
// activates when shown.

final class ResourcesWindowController: NSWindowController {

    init(path: String = ResourceFileLoader.defaultPath) {
        let hostingView = NSHostingView(rootView: ResourcesPanelView(path: path))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "swiftx-server Resources"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 580, height: 420)
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
