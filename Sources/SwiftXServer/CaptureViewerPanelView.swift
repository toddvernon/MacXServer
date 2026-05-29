import SwiftUI
import AppKit

// SwiftUI root for the capture viewer: a header, the dark code editor
// (read-only) showing a decoded .xtap chrono dump, and two save actions.
// The decoded text is produced once by the caller (AppDelegate.openCapture)
// and handed in; this view never edits it.
//
//   Save As…       copies the underlying .xtap (renamed — handy for promoting
//                  a session to a new gold recording), plus its .json sidecar.
//   Export as Text… writes the decoded chrono dump as a .txt.

struct CaptureViewerPanelView: View {

    let title: String       // capture filename
    let sourcePath: String  // path of the .xtap on disk
    let text: String        // decoded chrono dump

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CodeEditorView(
                text: .constant(text),
                theme: .dark,
                makeHighlighter: { theme, font in
                    CaptureSyntaxHighlighter(theme: theme, baseFont: font)
                },
                isEditable: false,
                alwaysShowVerticalScroller: true
            )
            .frame(minHeight: 320)
            actionRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                Text("Decoded X11 wire log (read-only). The .xtap on disk stays the source of truth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Export as Text\u{2026}") { exportText() }
            Button("Save As\u{2026}") { saveXtap() }
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    // MARK: - Save actions

    /// Copy the .xtap (and its .json sidecar) under a user-chosen name.
    private func saveXtap() {
        guard let dest = runSavePanel(title: "Save Capture As", ext: "xtap") else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(atPath: sourcePath, toPath: dest.path)
            // Copy the "<name>.xtap.json" metadata sidecar too, if present, so
            // the saved capture is a complete copy (gold recordings use it).
            let srcSidecar = sourcePath + ".json"
            if fm.fileExists(atPath: srcSidecar) {
                let dstSidecar = dest.path + ".json"
                if fm.fileExists(atPath: dstSidecar) { try fm.removeItem(atPath: dstSidecar) }
                try fm.copyItem(atPath: srcSidecar, toPath: dstSidecar)
            }
        } catch {
            showError("Couldn't save capture", error)
        }
    }

    /// Write the decoded chrono dump as a .txt under a user-chosen name.
    private func exportText() {
        guard let dest = runSavePanel(title: "Export as Text", ext: "txt") else { return }
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            showError("Couldn't export text", error)
        }
    }

    // MARK: - Helpers

    /// Run a save panel with an empty name field (so you just type and go) and
    /// return the chosen URL with exactly one trailing ".<ext>" — appended if
    /// the user didn't type it. nil if cancelled. We deliberately don't set
    /// allowedContentTypes (it forces a select-all'd "name.<ext>" default and
    /// can double the extension); the empty field + normalize gives a clean
    /// "type the name, get name.<ext>" flow.
    private func runSavePanel(title: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = ""
        panel.directoryURL = URL(fileURLWithPath: (sourcePath as NSString).deletingLastPathComponent)

        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        var base = chosen.lastPathComponent
        let dot = ".\(ext)"
        if base.hasSuffix(dot) { base = String(base.dropLast(dot.count)) }
        if base.isEmpty { base = "capture" }
        return chosen.deletingLastPathComponent().appendingPathComponent(base + dot)
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
