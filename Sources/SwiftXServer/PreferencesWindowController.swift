import AppKit
import SwiftUI

// Window controller for Preferences. SwiftUI content
// (PreferencesPanelView) hosted in an NSPanel via NSHostingView —
// same shape as ResourcesWindowController. The Preferences model is
// owned by the app and passed in so settings writes flow through the
// existing UserDefaults-backed Preferences class.

final class PreferencesWindowController: NSWindowController {

    init(preferences: Preferences) {
        let hostingView = NSHostingView(rootView: PreferencesPanelView(preferences: preferences))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "swiftx-server Preferences"
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
