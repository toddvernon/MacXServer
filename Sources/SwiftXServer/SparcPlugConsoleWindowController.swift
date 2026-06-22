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
        if state == .running, model.state != .running {
            model.safeToQuit = false   // fresh boot
            model.ready = false
            model.bootStalledReason = nil
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
}

@MainActor
final class SparcPlugConsoleModel: ObservableObject {
    /// Finished lines (each already terminated with "\n").
    @Published var committed = AttributedString()
    /// The in-progress last line, re-rendered live so CR/BS overwrites (and the
    /// `\|/-` spinner) animate in place instead of waiting for a newline.
    @Published var currentLine = ""
    /// Bumped on every transcript change; the scroll view follows it.
    @Published var revision = 0
    @Published var state: QemuEngine.State = .stopped
    /// Set once Solaris confirms filesystems are synced during shutdown.
    @Published var safeToQuit = false
    /// Set once the guest answers `hello` -- the authoritative "ready" signal.
    @Published var ready = false
    /// Non-nil when the boot stalled (fsck maintenance drop or readiness
    /// timeout); the value is a short human reason.
    @Published var bootStalledReason: String?
    /// 0...1 boot/shutdown progress for the top thermometer.
    @Published var progress: Double = 0

    private let sanitizer = ConsoleSanitizer()

    private let mono: AttributeContainer = {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced)
        return c
    }()

    /// What the view draws: committed lines plus the live current line.
    var displayContent: AttributedString {
        var c = committed
        if !currentLine.isEmpty {
            c.append(AttributedString(currentLine, attributes: mono))
        }
        return c
    }

    func append(_ text: String) {
        let update = sanitizer.feed(text)
        for line in update.completedLines {
            committed.append(AttributedString(line + "\n", attributes: mono))
        }
        currentLine = update.currentLine
        revision &+= 1
    }

    /// New boot: flush any dangling partial line into history and clear the
    /// sanitizer's parse state so a half-line from the prior run doesn't merge
    /// into the new one. Keeps the scrollback.
    func beginRun() {
        if !currentLine.isEmpty {
            committed.append(AttributedString(currentLine + "\n", attributes: mono))
            currentLine = ""
        }
        sanitizer.reset()
        revision &+= 1
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
                    Text(model.displayContent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("console")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.revision) {
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
