import SwiftUI
import AppKit

// SwiftUI root for the capture viewer: a header, the dark code editor
// (read-only) showing a decoded .xtap chrono dump with a landmark outline
// sidebar to its left, and two save actions. The decoded text is produced
// once by the caller (AppDelegate.openCapture) and handed in; this view
// never edits it.
//
//   Save As…        copies the underlying .xtap (renamed — handy for
//                   promoting a session to a new gold recording), plus
//                   its .json sidecar.
//   Export as Text… writes the decoded chrono dump as a .txt.
//
//   Cmd-]  jump to the next landmark below the current view
//   Cmd-[  jump to the previous landmark above the current view
//   Click  any row in the outline sidebar to jump to that landmark.

public struct CaptureViewerPanelView: View {

    let title: String       // capture filename
    let sourcePath: String  // path of the .xtap on disk
    let text: String        // decoded chrono dump
    private let landmarks: [Landmark]

    @StateObject private var editor = CaptureEditorController()

    public init(title: String, sourcePath: String, text: String) {
        self.title = title
        self.sourcePath = sourcePath
        self.text = text
        self.landmarks = Self.extractLandmarks(from: text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 12) {
                if !landmarks.isEmpty {
                    landmarkSidebar
                        .frame(width: 240)
                }
                CodeEditorView(
                    text: .constant(text),
                    theme: .dark,
                    makeHighlighter: { theme, font in
                        CaptureSyntaxHighlighter(theme: theme, baseFont: font)
                    },
                    isEditable: false,
                    alwaysShowVerticalScroller: true,
                    controller: editor
                )
                .frame(minHeight: 320)
            }
            actionRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 720, minHeight: 520)
        // Invisible buttons hold the Cmd-]/Cmd-[ shortcuts so they fire
        // regardless of which subview has focus. SwiftUI requires a
        // button (or commands menu) to bind a keyboardShortcut to.
        .background(
            ZStack {
                Button("") { jumpNext() }
                    .keyboardShortcut("]", modifiers: .command)
                    .opacity(0)
                Button("") { jumpPrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0)
            }
            .frame(width: 0, height: 0)
        )
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
            if !landmarks.isEmpty {
                HStack(spacing: 6) {
                    Button(action: jumpPrevious) {
                        Image(systemName: "chevron.up")
                    }
                    .help("Previous landmark (\u{2318}[)")
                    Button(action: jumpNext) {
                        Image(systemName: "chevron.down")
                    }
                    .help("Next landmark (\u{2318}])")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Landmark outline sidebar

    private var landmarkSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Landmarks")
                    .font(.headline)
                Spacer()
                Text("\(landmarks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            List(landmarks) { lm in
                Button(action: { editor.jump(toLine: lm.line) }) {
                    Text(lm.displayText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Navigation actions

    private func jumpNext() {
        guard !landmarks.isEmpty else { return }
        let current = editor.firstVisibleLine()
        if let target = landmarks.first(where: { $0.line > current }) {
            editor.jump(toLine: target.line)
        } else {
            // Wrap to first landmark.
            editor.jump(toLine: landmarks[0].line)
        }
    }

    private func jumpPrevious() {
        guard !landmarks.isEmpty else { return }
        let current = editor.firstVisibleLine()
        if let target = landmarks.last(where: { $0.line < current }) {
            editor.jump(toLine: target.line)
        } else {
            // Wrap to last landmark.
            editor.jump(toLine: landmarks.last!.line)
        }
    }

    // MARK: - Landmark extraction

    /// A landmark row in the outline sidebar.
    struct Landmark: Identifiable {
        let id: Int          // line number (unique per landmark)
        let line: Int        // same as id, 1-based
        let displayText: String

        init(line: Int, text: String) {
            self.id = line
            self.line = line
            // Strip the leading "# " for display so the sidebar reads as
            // a labeled outline rather than a code-comment listing.
            self.displayText = text.hasPrefix("# ")
                ? String(text.dropFirst(2))
                : text
        }
    }

    private static func extractLandmarks(from text: String) -> [Landmark] {
        var out: [Landmark] = []
        var line = 1
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            if s.hasPrefix("# ") {
                out.append(Landmark(line: line, text: s))
            }
            line += 1
        }
        return out
    }

    // MARK: - Save actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Export as Text\u{2026}") { exportText() }
            Button("Save As\u{2026}") { saveXtap() }
                .keyboardShortcut("s", modifiers: .command)
        }
    }

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
