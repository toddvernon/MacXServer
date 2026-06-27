import AppKit
import SwiftUI

// Window controller for the Acknowledgements / Open Source Licenses screen.
// SwiftUI content (AcknowledgementsView) hosted in an NSPanel via NSHostingView,
// the same shape ResourcesWindowController and the other secondary windows use.
//
// Resizable so the license texts have room; activates on show so the embedded
// links and selectable text take focus.

final class AcknowledgementsWindowController: NSWindowController {

    init() {
        let hostingView = NSHostingView(rootView: AcknowledgementsView())

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Acknowledgements"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 480)
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
