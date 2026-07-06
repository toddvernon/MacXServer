import SwiftUI
import AppKit
import SwiftXServerCore

// The engine-global Config windows. Two of the original three sections
// retired in P2: Disk Image (per-machine now -- the Machines window's Settings
// tab is the one image editor) and Claude Development (the /tmp/sparkplug
// secret file is gone; the image lock carries the secret, and the MCP bridge
// is the coming channel). What's left is genuinely global: the Shared Folder
// (one TFTP dir slirp serves to every guest).

/// One Config window per logical task.
enum SparcConfigSection: Hashable {
    case sharedFolder

    var title: String {
        switch self {
        case .sharedFolder: return "Shared Folder"
        }
    }

    var windowTitle: String { title }

    /// Menu item label.
    var menuTitle: String { "\(title)\u{2026}" }

    var defaultSize: NSSize {
        switch self {
        case .sharedFolder: return NSSize(width: 640, height: 580)
        }
    }
}

final class SparcConfigWindowController: NSWindowController {

    let section: SparcConfigSection

    init(section: SparcConfigSection, model: SparcConfigModel) {
        self.section = section
        let hostingView = NSHostingView(rootView: SparcConfigRootView(section: section, model: model))
        let size = section.defaultSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = section.windowTitle
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 260)
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

private struct SparcConfigRootView: View {
    let section: SparcConfigSection
    @ObservedObject var model: SparcConfigModel

    var body: some View {
        switch section {
        case .sharedFolder: SharedFolderConfigView(model: model)
        }
    }
}

// MARK: - Shared Folder

private struct SharedFolderConfigView: View {
    @ObservedObject var model: SparcConfigModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PanelHeader(
                    icon: "folder",
                    title: "Shared Folder",
                    caption: "Copy files into the guests over TFTP."
                )

                Toggle("Use a shared folder to copy files into the guests",
                       isOn: $model.sparcTftpEnabled)

                if model.sparcEngineRunning {
                    Label("A machine is running. Changes to the shared folder apply to each guest at its next start.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(model.sparcTftpDirectory)
                    .font(.callout)
                    .foregroundStyle(model.sparcTftpEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Choose\u{2026}") { model.chooseSparcTftpDirectory() }
                    Button("Reveal in Finder") { model.revealSparcTftpDirectory() }
                    Spacer()
                }
                .disabled(!model.sparcTftpEnabled)

                Text("Drop files in this folder, then on a guest pull them over with the built-in TFTP client (the folder is served read-only on the gateway, 10.0.2.2):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("tftp 10.0.2.2\nbinary\nget filename\nquit")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("TFTP moves one file at a time and can't list the folder, so tar up a set first. \u{2018}binary\u{2019} is required or binaries arrive corrupted. Takes effect on the next Start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
