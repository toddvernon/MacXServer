import AppKit
import SwiftUI
import SwiftXServerCore

// Window controller for the font mappings editor. SwiftUI content
// (FontMappingsPanelView) hosted in an NSPanel via NSHostingView — same
// shape as ResourcesWindowController.

final class FontMappingsWindowController: NSWindowController {

    init(path: String = FontMappingFileLoader.defaultPath) {
        let hostingView = NSHostingView(rootView: FontMappingsPanelView(path: path))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "MacXServer Font Mappings"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 580, height: 380)
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
