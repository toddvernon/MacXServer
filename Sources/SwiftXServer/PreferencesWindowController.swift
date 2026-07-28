import AppKit
import SwiftUI

// Window controllers for the X11 server settings panes (Cut and Paste,
// Capture, Mouse, Display). Each pane is its own window opened from its own
// X11Server menu item -- the Edit Resources model -- replacing the tabbed
// app-Preferences window (2026-07-28 reorg). SwiftUI content hosted in an
// NSPanel via NSHostingView, same shape as ResourcesWindowController. The
// Preferences model is owned per-window; the panes' settings are disjoint,
// and every write flows through the UserDefaults-backed Preferences class,
// so two open panes can't fight over a field.

/// The four settings panes. AppDelegate keys its controller cache on this.
enum SettingsPane {
    case cutPaste, capture, mouse, display

    var title: String {
        switch self {
        case .cutPaste: return "Cut and Paste Settings"
        case .capture:  return "Capture Settings"
        case .mouse:    return "Mouse Settings"
        case .display:  return "Display Settings"
        }
    }

    /// Window size per pane -- the panes lay out top-leading with Spacers,
    /// so the frame is the design: tall enough for the content, no dead air.
    var contentSize: NSSize {
        switch self {
        case .cutPaste: return NSSize(width: 560, height: 320)
        case .capture:  return NSSize(width: 560, height: 340)
        case .mouse:    return NSSize(width: 620, height: 560)
        case .display:  return NSSize(width: 620, height: 620)
        }
    }
}

final class SettingsPaneWindowController: NSWindowController {

    private let model: PreferencesPanelModel

    init(pane: SettingsPane, preferences: Preferences) {
        let model = PreferencesPanelModel(preferences: preferences)
        self.model = model

        let content: AnyView
        switch pane {
        case .cutPaste: content = AnyView(CutPastePane(model: model))
        case .capture:  content = AnyView(CapturePane(model: model))
        case .mouse:    content = AnyView(MousePane(model: model))
        case .display:  content = AnyView(DisplayPane(model: model))
        }

        let size = pane.contentSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = pane.title
        // Pin the SwiftUI content to the design size. The panes fill
        // maxHeight .infinity (Spacer layouts), so an unpinned NSHostingView
        // reports an unbounded ideal height and resizes the window to the
        // full screen.
        panel.contentView = NSHostingView(
            rootView: content.frame(width: size.width, height: size.height))
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
