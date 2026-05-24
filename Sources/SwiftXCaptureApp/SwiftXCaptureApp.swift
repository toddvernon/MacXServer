import SwiftUI

// SwiftUI capture app — successor to the v1 CLI tool, sharing the
// SwiftXCaptureCore library with `swiftx-server`'s server-side
// capture path. Step 5 of PRODUCT_1_CAPTURE.md § v2 is just the
// skeleton: a mode-chooser at launch, three placeholder windows
// (Record / Open / Replay) that real implementations land in steps
// 6, 7, 8. Each placeholder lists what it'll do so the navigation
// reads as intentional, not unfinished.
//
// Binary name is `swiftx-capture-app` for now; v1's `swiftx-capture`
// CLI keeps its name during the transition. Step 9 resolves the
// collision — either rename this app or fold the CLI into a
// --headless mode of this binary.

@main
struct SwiftXCaptureApp: App {

    var body: some Scene {

        // The launch window. SwiftUI opens the first scene's first
        // window automatically on app start.
        Window("Capture Mode", id: WindowID.modeChooser.rawValue) {
            ModeChooserView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // One singleton window per mode. Opening from the chooser uses
        // OpenWindowAction; closing returns the user to whatever was
        // already on screen (typically nothing, prompting a relaunch
        // or chooser reopen).
        Window("Record", id: WindowID.record.rawValue) {
            RecordView()
        }
        .windowResizability(.contentSize)

        Window("Open Capture", id: WindowID.open.rawValue) {
            OpenView()
        }
        .windowResizability(.contentSize)

        Window("Replay", id: WindowID.replay.rawValue) {
            ReplayView()
        }
        .windowResizability(.contentSize)
    }
}

/// Stable string IDs for the four windows. Centralised so the chooser
/// and any future menu commands reference the same constants.
enum WindowID: String {
    case modeChooser = "mode-chooser"
    case record = "record"
    case open = "open"
    case replay = "replay"
}
