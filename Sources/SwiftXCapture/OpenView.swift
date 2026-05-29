import SwiftUI
import SwiftXCaptureCore
import SwiftXCaptureUI

// Open mode. Pick a `.xtap` and read its decoded X11 traffic in the shared
// dark, syntax-highlighted viewer (the same one the server app uses), with
// Save As… / Export as Text… from the viewer's action row.

struct OpenView: View {

    @StateObject private var model = OpenModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navBar
            Divider()
            if let path = model.loadedPath, model.errorMessage == nil {
                CaptureViewerPanelView(
                    title: (path as NSString).lastPathComponent,
                    sourcePath: path,
                    text: model.decodedText
                )
                .id(path)   // rebuild the viewer when a different file loads
            } else {
                EmptyOpenState(model: model)
            }
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 540, idealHeight: 640)
    }

    // Compact mode bar: back to the chooser, the capture summary, and a way
    // to open another file. The viewer below shows the filename + actions.
    private var navBar: some View {
        HStack(spacing: 12) {
            BackToMenuButton(from: .open)
            if let s = model.summary {
                Text("\(s.filename) · \(s.frameCount) frames · \(s.durationDescription) · "
                     + "\(formatBytes(s.totalBytesC2S)) in / \(formatBytes(s.totalBytesS2C)) out")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Open").font(.title2)
            }
            Spacer()
            Button("Open\u{2026}") { model.chooseFileAndOpen() }
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Empty state

private struct EmptyOpenState: View {
    @ObservedObject var model: OpenModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a .xtap file to inspect its X11 traffic.")
                .foregroundStyle(.secondary)
            Button("Open\u{2026}") { model.chooseFileAndOpen() }
                .buttonStyle(.borderedProminent)
            if let err = model.errorMessage {
                Text(err).foregroundStyle(.red).font(.callout)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private func formatBytes(_ n: Int) -> String {
    let k = 1024.0
    let d = Double(n)
    if d < k { return "\(n) B" }
    if d < k * k { return String(format: "%.1f KB", d / k) }
    if d < k * k * k { return String(format: "%.1f MB", d / (k * k)) }
    return String(format: "%.1f GB", d / (k * k * k))
}
