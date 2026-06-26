import AppKit
import SwiftUI
import SwiftXServerCore

// Interactive console window for the bundled SPARCstation engine's serial
// console (qemu `-serial unix:`). An NSWindow hosting a SwiftUI chrome (boot
// thermometer, header, status + Shut Down / Force Quit) wrapped around a real
// terminal: the TerminalView renders libvterm's screen grid and sends the
// user's keystrokes back to the guest console, so vi/top/format work here when
// the graphical path is down. See CONSOLE_TERMINAL.md.
final class SparcPlugConsoleWindowController: NSWindowController {

    private let model = SparcPlugConsoleModel()

    init(onShutDown: @escaping () -> Void,
         onForceQuit: @escaping () -> Void,
         onInput: @escaping (Data) -> Void) {
        // Keystrokes the terminal produces go straight back to the guest
        // console (engine.sendConsole on the app side).
        model.terminalView.onInput = onInput

        let hostingView = NSHostingView(rootView: SparcPlugConsoleView(
            model: model, shutDown: onShutDown, forceQuit: onForceQuit))
        // First-class NSWindow (not an NSPanel/.utilityWindow): a utility panel
        // hides whenever macXserver isn't the foreground app, which is annoying
        // for a console you want to keep watching while you work elsewhere. A
        // plain window stays put on deactivate.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "SPARCstation Console"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 240)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Focus the terminal so typing goes to the guest. Deferred to the next
        // runloop so SwiftUI has realized the NSView tree first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.model.terminalView)
        }
    }

    /// Raw serial-console bytes from the engine -> the terminal emulator.
    func feedConsoleData(_ data: Data) {
        model.feed(data)
    }

    func setState(_ state: QemuEngine.State) {
        if state == .running, model.state != .running {
            model.safeToQuit = false   // fresh boot
            model.ready = false
            model.bootStalledReason = nil
            model.shutdownUnavailable = false
            model.beginRun()
        }
        model.state = state
    }

    /// 0...1 boot/shutdown progress for the thermometer.
    func setProgress(_ value: Double) {
        model.progress = value
    }

    /// Solaris reported filesystems synced -- show the positive safe signal.
    func markCleanHalt() {
        model.safeToQuit = true
    }

    /// The guest answered `hello` -- it's up and serving (C3).
    func markReady() {
        model.ready = true
    }

    /// The boot won't complete (fsck maintenance drop, or readiness timed out).
    func markBootStalled(_ reason: String) {
        model.bootStalledReason = reason
    }

    /// A graceful Shut Down couldn't reach the Helios daemon -- surface Force Quit
    /// even though the guest may still look "ready" (graceful-first policy).
    func markShutdownUnavailable() {
        model.shutdownUnavailable = true
    }
}

@MainActor
final class SparcPlugConsoleModel: ObservableObject {
    @Published var state: QemuEngine.State = .stopped
    /// Set once Solaris confirms filesystems are synced during shutdown.
    @Published var safeToQuit = false
    /// Set once the guest answers `hello` -- the authoritative "ready" signal.
    @Published var ready = false
    /// Non-nil when the boot stalled (fsck maintenance drop or readiness
    /// timeout); the value is a short human reason.
    @Published var bootStalledReason: String?
    /// Set when a graceful Shut Down couldn't reach the daemon -- forces the
    /// controls to offer Force Quit even though the guest still looks ready.
    @Published var shutdownUnavailable = false
    /// 0...1 boot/shutdown progress for the top thermometer.
    @Published var progress: Double = 0

    /// The interactive terminal: the libvterm emulator and its rendering view.
    /// Driven imperatively (feed bytes -> the NSView repaints itself), so it's
    /// not @Published -- SwiftUI only owns the chrome around it.
    let terminal = TerminalEmulator(rows: 24, cols: 80)
    lazy var terminalView = TerminalView(emulator: terminal)

    /// Feed raw console bytes into the emulator and repaint the view.
    func feed(_ data: Data) {
        terminal.feed(data)
        terminalView.refresh()
    }

    /// New boot. The terminal keeps its current screen; the guest repaints as
    /// it boots. (A hard screen reset per run could be added later if wanted.)
    func beginRun() {}
}

/// Bridges the AppKit TerminalView into SwiftUI, inside a scroll view with the
/// terminal's black background. The TerminalView sizes itself to the 80x24
/// grid; the scroll view clips/scrolls when the window is smaller (and is the
/// natural home for scrollback later).
private struct TerminalConsoleView: NSViewRepresentable {
    let view: TerminalView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.borderType = .noBorder
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

struct SparcPlugConsoleView: View {
    @ObservedObject var model: SparcPlugConsoleModel
    let shutDown: () -> Void
    let forceQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            bootBar
            content
        }
        .frame(minWidth: 480, minHeight: 240)
    }

    /// Full-width thermometer: grows as the guest boots, recedes as it shuts
    /// down. Driven by QemuEngine progress milestones. Blue while in motion
    /// (booting or unbooting); flips to green once the box is up and serving
    /// (state == .running and `ready`, i.e. Helios answered).
    private var bootBar: some View {
        let accent: Color = (model.state == .running && model.ready) ? .green : .blue
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(accent.opacity(0.15))
                Rectangle().fill(accent)
                    .frame(width: geo.size.width * model.progress)
            }
        }
        .frame(height: 5)
        .animation(.easeInOut(duration: 0.45), value: model.progress)
        .animation(.easeInOut(duration: 0.3), value: model.ready)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                // Tiny SPARCstation 5 bezel where the generic desktop icon was.
                Image("SparcStation5Panel")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 30)
                    .accessibilityLabel("Sun SPARCstation 5")
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPARCstation 5 — Solaris 2.6")
                        .font(.title2)
                    Text("Interactive serial console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            TerminalConsoleView(view: model.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.safeToQuit {
                    Label("Filesystems synced — safe to power off", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let reason = model.bootStalledReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                controls
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 480, minHeight: 240)
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .running:
            // Graceful-first: when the guest is up and answering (ready, no failed
            // graceful attempt, not wedged), the only stop is a clean Shut Down.
            // Force Quit appears only when Helios can't be reached -- still booting,
            // wedged, or a graceful attempt just failed.
            if model.ready && !model.shutdownUnavailable && model.bootStalledReason == nil {
                Button("Shut Down", action: shutDown)
            } else {
                Button("Force Quit", action: forceQuit)
            }
        case .shuttingDown:
            // Graceful shutdown underway; still offer the escape hatch.
            Button("Force Quit", action: forceQuit)
        case .stopped, .notInstalled:
            EmptyView()
        }
    }

    private var statusColor: Color {
        if model.bootStalledReason != nil { return .orange }
        switch model.state {
        case .running: return model.ready ? .green : .blue
        case .shuttingDown: return .orange
        case .stopped: return .secondary
        case .notInstalled: return .orange
        }
    }

    private var statusText: String {
        if model.bootStalledReason != nil { return "Boot stalled" }
        switch model.state {
        // Process alive but the guest hasn't answered Helios yet vs. up and serving.
        case .running: return model.ready ? "Ready" : "Booting\u{2026}"
        case .shuttingDown: return "Shutting down\u{2026}"
        case .stopped: return "Stopped"
        case .notInstalled: return "No disk image installed"
        }
    }
}
