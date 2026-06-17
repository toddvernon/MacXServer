import AppKit
import SwiftUI

// First-run / no-image window for the bundled SPARCstation. Shown when the
// user picks Start SPARCstation with no disk image selected yet. Deliberately
// a friendly hero-panel window (same vocabulary as the Resources editor and
// Preferences) rather than a system error alert -- this is an invitation to
// boot a vintage Sun, not a failure. Explains what the emulator is, then
// offers to pick an existing image or download a starter image.
final class SparcStationWelcomeWindowController: NSWindowController {

    init(onChooseImage: @escaping () -> Void,
         onDownload: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "SPARCstation"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        let view = SparcStationWelcomeView(
            chooseImage: { [weak self] in self?.close(); onChooseImage() },
            download:    { [weak self] in self?.close(); onDownload() },
            cancel:      { [weak self] in self?.close() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SparcStationWelcomeView: View {
    let chooseImage: () -> Void
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .padding(.top, 8)

            Text("Start a SPARCstation")
                .font(.title2.weight(.semibold))

            Text("macXserver includes a built-in SPARCstation 5 — a complete vintage Sun workstation running Solaris 2.6, emulated on your Mac with no hardware required. Its X apps render right here through macXserver.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("To boot it, point macXserver at a Solaris disk image: choose a qcow2 image you already have, or download a prebuilt starter image from macXserver.com.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                Button(action: chooseImage) {
                    Text("Choose Image\u{2026}").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Button(action: download) {
                    Text("Download Starter Image\u{2026}").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: cancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 460, height: 460)
    }
}
