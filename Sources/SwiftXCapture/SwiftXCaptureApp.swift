import SwiftUI

// SwiftUI capture app — the GUI face of the `swiftx-capture` binary,
// sharing the SwiftXCaptureCore library with `swiftx-server`'s
// server-side capture path. Three modes: Record (proxy capture),
// Open (browse a `.xtap`), Replay (pipe a `.xtap` into a server).
//
// This struct does NOT carry @main — the executable's entry point
// is main.swift, which routes between the CLI and this GUI based on
// CommandLine.arguments. When the GUI is wanted, main.swift calls
// `SwiftXCaptureApp.main()` (the static method App protocol provides)
// explicitly. See step 9 in PRODUCT_1_CAPTURE.md § v2 for the
// rationale behind one binary instead of two.

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
