import AppKit
import SwiftUI
import SwiftXServerCore

/// Hosts the Machines list -- the app's front door under the machine-manager
/// reframe. Opens on launch and is reopened from the status item / Machines menu;
/// closing it does NOT quit the app (the status item is the persistent presence).
final class MachineListWindowController: NSWindowController {
    let model: MachineListModel

    init(model: MachineListModel) {
        self.model = model
        let hostingView = NSHostingView(rootView: MachineListPanelView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Machines"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false      // close != quit; reused on reopen
        // It's the front door, not a palette: stay visible when another app has
        // focus. NSPanel defaults hidesOnDeactivate to true, which would make it
        // vanish every time focus leaves the app (constant, since we're an
        // accessory app).
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 520, height: 320)
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
