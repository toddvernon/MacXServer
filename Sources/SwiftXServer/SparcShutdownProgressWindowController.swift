import AppKit
import SwiftUI

/// Live feedback for the "Try to Shut It Down" orphan-recovery path. We ask the
/// guest's Helios daemon to `init 5` (C4) and then poll the pid; this panel
/// shows a countdown while we wait for the orphan to power off, so the user
/// isn't left guessing whether to wait, force quit, or give up. It then either
/// auto-dismisses and boots (success) or flips to an actionable failure state
/// with Force Quit / Show Me How / Cancel. See PLUGIN_V1_PUNCHLIST L2(b).
final class SparcShutdownProgressWindowController: NSWindowController {

    let model: SparcShutdownProgressModel

    init(totalSeconds: Int,
         onForceQuit: @escaping () -> Void,
         onShowManual: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        let m = SparcShutdownProgressModel(total: totalSeconds)
        m.onForceQuit = onForceQuit
        m.onShowManual = onShowManual
        m.onCancel = onCancel
        self.model = m

        let hostingView = NSHostingView(rootView: SparcShutdownProgressView(model: m))
        // No .closable: the only ways out are the explicit buttons, so we never
        // leave the background poll running behind a closed window.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Shutting Down SPARCstation"
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

    /// Seconds left before the wait gives up. Drives the countdown + bar.
    func updateRemaining(_ seconds: Int) { model.remaining = max(0, seconds) }

    /// The orphan powered off. Show the green state; the caller dismisses us
    /// after a beat and boots.
    func markSucceeded() { model.phase = .succeeded }

    /// The wait timed out, or the Helios daemon couldn't be reached. Surface
    /// the escalation buttons.
    func markFailed() { model.phase = .failed }
}

@MainActor
final class SparcShutdownProgressModel: ObservableObject {
    enum Phase { case working, succeeded, failed }

    @Published var phase: Phase = .working
    @Published var remaining: Int

    let total: Int

    var onForceQuit: () -> Void = {}
    var onShowManual: () -> Void = {}
    var onCancel: () -> Void = {}

    init(total: Int) {
        self.total = total
        self.remaining = total
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(total - remaining) / Double(total)
    }
}

struct SparcShutdownProgressView: View {
    @ObservedObject var model: SparcShutdownProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.headline)
                    Text(substatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if model.phase == .working {
                ProgressView(value: model.fraction)
            }

            HStack(spacing: 10) {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.phase {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
        }
    }

    private var headline: String {
        switch model.phase {
        case .working:   return "Shutting down the SPARCstation…"
        case .succeeded: return "Powered off"
        case .failed:    return "It didn’t shut down on its own"
        }
    }

    private var substatus: String {
        switch model.phase {
        case .working:
            return "Sent the shutdown command (init 5). Waiting for it to power "
                + "off — \(model.remaining)s left."
        case .succeeded:
            return "Starting your SPARCstation…"
        case .failed:
            return "Telnet root login is often refused on Solaris 2.6, so the "
                + "guest may never have gotten the command. Force quit it (risks "
                + "a disk check on the next boot), or shut it down by hand."
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .working:
            Button("Cancel") { model.onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Force Quit") { model.onForceQuit() }
        case .failed:
            Button("Cancel") { model.onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Show Me How") { model.onShowManual() }
            Button("Force Quit") { model.onForceQuit() }
        case .succeeded:
            EmptyView()
        }
    }
}
