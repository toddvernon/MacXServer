import AppKit
import SwiftUI

// Window controller for Preferences. SwiftUI content
// (PreferencesPanelView) hosted in an NSPanel via NSHostingView —
// same shape as ResourcesWindowController. The Preferences model is
// owned by the app and passed in so settings writes flow through the
// existing UserDefaults-backed Preferences class.

final class PreferencesWindowController: NSWindowController {

    /// Owned here (not created inside the SwiftUI view) so callers can drive
    /// the selected tab.
    private let model: PreferencesPanelModel

    init(preferences: Preferences) {
        let model = PreferencesPanelModel(preferences: preferences)
        self.model = model
        let hostingView = NSHostingView(rootView: PreferencesPanelView(model: model))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "MacXServer Preferences"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Show the window, optionally jumping to a specific tab.
    func showWindow(selecting tab: PreferencesTab? = nil) {
        if let tab { model.selectedTab = tab }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
