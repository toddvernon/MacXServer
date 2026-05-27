import AppKit
import SwiftUI
import SwiftXServerCore

final class LaunchersWindowController: NSWindowController {
    init(path: String = LauncherFileLoader.defaultPath) {
        let hostingView = NSHostingView(rootView: LaunchersPanelView(path: path))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "MacXServer Launchers"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 540, height: 340)
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
