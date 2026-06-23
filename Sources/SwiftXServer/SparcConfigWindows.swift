import SwiftUI
import AppKit
import SwiftXServerCore

// The SPARCstation > Config windows: the settings that used to be the
// Preferences "SPARCstation" tab, broken into one focused window per logical
// task. Each is an NSPanel hosting a small SwiftUI view bound to the shared
// SparcConfigModel, reusing the Preferences hero-panel vocabulary (PanelHeader).

/// One Config window per logical task.
enum SparcConfigSection: Hashable {
    case diskImage, sharedFolder, claudeDev

    var title: String {
        switch self {
        case .diskImage:    return "Disk Image"
        case .sharedFolder: return "Shared Folder"
        case .claudeDev:    return "Claude Development"
        }
    }

    var windowTitle: String { "SPARCstation Config: \(title)" }

    /// Menu item label.
    var menuTitle: String { "\(title)\u{2026}" }

    var defaultSize: NSSize {
        switch self {
        case .diskImage:    return NSSize(width: 620, height: 440)
        case .sharedFolder: return NSSize(width: 640, height: 580)
        case .claudeDev:    return NSSize(width: 560, height: 320)
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
        case .diskImage:    DiskImageConfigView(model: model)
        case .sharedFolder: SharedFolderConfigView(model: model)
        case .claudeDev:    ClaudeDevConfigView(model: model)
        }
    }
}

// MARK: - Disk Image

private struct DiskImageConfigView: View {
    @ObservedObject var model: SparcConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "internaldrive",
                title: "Disk Image",
                caption: "The Solaris 2.6 disk image the SPARCstation boots."
            )

            Text("Disk image:")
                .foregroundStyle(.secondary)

            Text(model.sparcDiskImagePath.isEmpty
                 ? "No disk image selected" : model.sparcDiskImagePath)
                .font(.callout)
                .foregroundStyle(model.sparcDiskImagePath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Choose\u{2026}") { model.chooseSparcDiskImage() }
                if !model.sparcDiskImagePath.isEmpty {
                    Button("Reveal in Finder") { model.revealSparcDiskImage() }
                    Button("Clear") { model.sparcDiskImagePath = "" }
                }
                Spacer()
            }

            Text("Point this at a Solaris qcow2 disk image; the SPARCstation \u{203A} Start command boots it. Booting writes to the image (the VM persists its own state), so use a copy if you want to keep a pristine master.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Back up the disk image after each clean shutdown",
                   isOn: $model.sparcAutoBackupOnShutdown)

            Text("Keeps a dated \u{201C}last known good\u{201D} copy next to the image whenever the SPARCstation shuts down cleanly, so you can roll back if a later session corrupts it. Only the most recent few are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 420, alignment: .topLeading)
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
                    caption: "Copy files into the SPARCstation over TFTP."
                )

                Toggle("Use a shared folder to copy files into the SPARCstation",
                       isOn: $model.sparcTftpEnabled)

                if model.sparcEngineRunning {
                    Label("The SPARCstation is running. Shut it down and start it again to apply a change to the shared folder.",
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

                Text("Drop files in this folder, then on the SPARCstation pull them over with the built-in TFTP client (the folder is served read-only on the gateway, 10.0.2.2):")
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

// MARK: - Claude Development

private struct ClaudeDevConfigView: View {
    @ObservedObject var model: SparcConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(
                icon: "key.horizontal",
                title: "Claude Development",
                caption: "Expose the Helios daemon key for agentic development."
            )

            Toggle("Claude development", isOn: $model.sparcClaudeDevelopment)

            Text("Writes the running SPARCstation\u{2019}s Helios control-daemon key to /tmp/sparkplug (owner-only) each launch, so Claude Code can drive the guest for agentic development. Leave off unless you\u{2019}re doing that \u{2014} it exposes the key to anything on this Mac that can read the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 300, alignment: .topLeading)
    }
}
