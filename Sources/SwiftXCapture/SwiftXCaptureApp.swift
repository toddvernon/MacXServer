import SwiftUI
import AppKit

// SwiftUI capture app — the GUI face of the `macxcapture` binary,
// sharing the SwiftXCaptureCore library with `macxserver`'s
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

    @NSApplicationDelegateAdaptor(CaptureAppDelegate.self) private var appDelegate

    var body: some Scene {

        // The launch window. SwiftUI opens the first scene's first
        // window automatically on app start.
        Window("MacXCapture", id: WindowID.modeChooser.rawValue) {
            ModeChooserView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // One singleton window per mode. Each mode view shows a Menu
        // back-button that dismisses itself and reopens the chooser,
        // so the chooser acts like a hub the user can always return
        // to without relaunching.
        Window("Record", id: WindowID.record.rawValue) {
            RecordView()
        }
        .windowResizability(.contentSize)

        Window("Open", id: WindowID.open.rawValue) {
            OpenView()
        }
        .windowResizability(.contentSize)

        Window("Replay", id: WindowID.replay.rawValue) {
            ReplayView()
        }
        .windowResizability(.contentSize)
    }
}

/// Top-left button shown on every mode view. Tapping closes the
/// current window and reopens the chooser, so the user can switch
/// modes without relaunching. Disabled-state lets callers block the
/// return path while a session is running (would silently drop a
/// live capture / replay).
struct BackToMenuButton: View {
    let fromWindow: WindowID
    var disabled: Bool = false

    init(from window: WindowID, disabled: Bool = false) {
        self.fromWindow = window
        self.disabled = disabled
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button {
            openWindow(id: WindowID.modeChooser.rawValue)
            dismissWindow(id: fromWindow.rawValue)
        } label: {
            Label("Menu", systemImage: "chevron.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(disabled
              ? "Stop the current session before switching modes"
              : "Back to the mode chooser")
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

/// Bring the app to the foreground on launch. Without this, a
/// terminal-launched macxcapture creates its window behind the
/// terminal that ran it — the user sees no GUI and assumes the
/// app is broken.
final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
