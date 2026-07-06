import AppKit
import SwiftUI
import SwiftXServerCore

/// Hosts the unified Machines window -- the app's front door under the
/// machine-manager reframe. Master list of machines + a per-machine detail pane
/// (Overview / Settings tabs). Opens on launch and is reopened from the status
/// item / Machines menu; closing it does NOT quit (the status item is the
/// persistent presence). A standard resizable window (not a utility panel), since
/// it's a manager surface with a master/detail editor, not a palette.
final class MachinesWindowController: NSWindowController {
    let model: MachinesModel

    init(model: MachinesModel) {
        self.model = model
        let hostingView = NSHostingView(rootView: MachinesWindowView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Machines"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false      // close != quit; reused on reopen
        window.minSize = NSSize(width: 760, height: 480)
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
