import AppKit
import SwiftUI

final class LaunchProgressWindowController: NSWindowController {

    private let model = LaunchProgressModel()

    init(title: String) {
        let hostingView = NSHostingView(rootView: LaunchProgressView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Launching: \(title)"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 200)
        panel.center()
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appendText(_ text: String) {
        model.append(text, bold: false)
    }

    func appendBoldText(_ text: String) {
        model.append(text, bold: true)
    }

    func appendStatusLine(_ text: String) {
        model.appendStatusLine(text)
    }

    func markDone(failed: Bool) {
        model.markDone(failed: failed)
    }
}

@MainActor
final class LaunchProgressModel: ObservableObject {
    @Published var content = AttributedString()
    @Published var isDone: Bool = false
    @Published var failed: Bool = false

    private let regular: AttributeContainer = {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced)
        return c
    }()

    private let bold: AttributeContainer = {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced).bold()
        return c
    }()

    func append(_ text: String, bold: Bool) {
        content.append(AttributedString(text, attributes: bold ? self.bold : regular))
    }

    func appendStatusLine(_ text: String) {
        var s = ""
        if !content.characters.isEmpty {
            let lastChar = content.characters[content.characters.index(before: content.characters.endIndex)]
            if lastChar != "\n" { s.append("\n") }
        }
        s.append(text)
        s.append("\n")
        content.append(AttributedString(s, attributes: bold))
    }

    func markDone(failed: Bool) {
        self.failed = failed
        self.isDone = true
    }
}

struct LaunchProgressView: View {
    @ObservedObject var model: LaunchProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launcher Progress")
                        .font(.title2)
                    Text("Telnet session log. Turn off verbose in the launcher config once it works.")
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
                        .id("terminal")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.content.characters.count) { _ in
                    proxy.scrollTo("terminal", anchor: .bottom)
                }
            }

            HStack {
                if model.isDone {
                    Image(systemName: model.failed
                          ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.failed ? .red : .green)
                    Text(model.failed ? "Failed" : "Complete")
                        .font(.caption)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 400, minHeight: 200)
    }
}
