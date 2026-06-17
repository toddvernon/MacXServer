import AppKit
import SwiftUI
import SwiftXServerCore

// Read-only observation window for the bundled SPARCstation engine's
// -nographic serial console. Modeled on LaunchProgressWindowController: an
// NSPanel hosting a SwiftUI monospaced transcript that autoscrolls. The user
// watches the boot here and drives shutdown from the buttons. Helios later
// builds its split terminal on this same window.
final class SparcPlugConsoleWindowController: NSWindowController {

    private let model = SparcPlugConsoleModel()

    init(onShutDown: @escaping () -> Void, onForceQuit: @escaping () -> Void) {
        let hostingView = NSHostingView(rootView: SparcPlugConsoleView(
            model: model, shutDown: onShutDown, forceQuit: onForceQuit))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "SPARCstation Console"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 240)
        panel.center()
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appendConsole(_ text: String) {
        model.append(text)
    }

    func setState(_ state: QemuEngine.State) {
        if state == .running { model.safeToQuit = false }   // fresh boot
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
}

@MainActor
final class SparcPlugConsoleModel: ObservableObject {
    @Published var content = AttributedString()
    @Published var state: QemuEngine.State = .stopped
    /// Set once Solaris confirms filesystems are synced during shutdown.
    @Published var safeToQuit = false
    /// 0...1 boot/shutdown progress for the top thermometer.
    @Published var progress: Double = 0

    private let mono: AttributeContainer = {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced)
        return c
    }()

    func append(_ text: String) {
        content.append(AttributedString(text, attributes: mono))
    }
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

    /// Full-width blue thermometer: grows as the guest boots, recedes as it
    /// shuts down. Driven by QemuEngine progress milestones.
    private var bootBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.blue.opacity(0.15))
                Rectangle().fill(Color.blue)
                    .frame(width: geo.size.width * model.progress)
            }
        }
        .frame(height: 5)
        .animation(.easeInOut(duration: 0.45), value: model.progress)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPARCstation 5 — Solaris 2.6")
                        .font(.title2)
                    Text("Serial console (read-only).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("console")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.content.characters.count) {
                    proxy.scrollTo("console", anchor: .bottom)
                }
            }

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
            Button("Shut Down", action: shutDown)
            Button("Force Quit", action: forceQuit)
        case .shuttingDown:
            // Graceful shutdown underway; still offer the escape hatch.
            Button("Force Quit", action: forceQuit)
        case .stopped, .notInstalled:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return .green
        case .shuttingDown: return .orange
        case .stopped: return .secondary
        case .notInstalled: return .orange
        }
    }

    private var statusText: String {
        switch model.state {
        case .running: return "Running"
        case .shuttingDown: return "Shutting down\u{2026}"
        case .stopped: return "Stopped"
        case .notInstalled: return "No disk image installed"
        }
    }
}
