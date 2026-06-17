import AppKit
import SwiftUI
import SwiftXServerCore

// Read-only observation window for the bundled SPARCstation engine's
// -nographic serial console. Modeled on LaunchProgressWindowController: an
// NSPanel hosting a SwiftUI monospaced transcript that autoscrolls. For
// plugin v1 it's display-only (you watch the boot); the interactive console
// / QMP control surface is a post-v1 concern. Helios later builds its split
// terminal on this same window.
final class SparcPlugConsoleWindowController: NSWindowController {

    private let model = SparcPlugConsoleModel()

    init() {
        let hostingView = NSHostingView(rootView: SparcPlugConsoleView(model: model))
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
        model.state = state
    }
}

@MainActor
final class SparcPlugConsoleModel: ObservableObject {
    @Published var content = AttributedString()
    @Published var state: QemuEngine.State = .stopped

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

    var body: some View {
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

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 480, minHeight: 240)
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return .green
        case .stopped: return .secondary
        case .notInstalled: return .orange
        }
    }

    private var statusText: String {
        switch model.state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .notInstalled: return "No disk image installed"
        }
    }
}
