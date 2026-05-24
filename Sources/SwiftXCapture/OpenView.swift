import SwiftUI
import SwiftXCaptureCore

// Open mode (step 7). Pick a `.xtap` and browse what's in it.
//
// Layout: a header bar with the file summary, then a split between
// a scrollable row list on the left and a detail pane on the right.
// Each row corresponds to one X11 packet decoded by ChronoDumper.
// Selecting a row shows its full line in the detail pane.
//
// Tree-by-phase grouping and the timeline scrubber from the spec
// are post-v2 polish. The detail pane's annotated/hex tabs are too;
// step 7 ships with just the structured-text view.

struct OpenView: View {

    @StateObject private var model = OpenModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(model: model)
            Divider()
            if model.loadedPath == nil {
                EmptyOpenState(model: model)
            } else {
                HSplitView {
                    RowList(model: model)
                        .frame(minWidth: 320, idealWidth: 420)
                    DetailPane(model: model)
                        .frame(minWidth: 260)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 540, idealHeight: 640)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var model: OpenModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            BackToMenuButton(from: .open)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open").font(.largeTitle)
                if let s = model.summary {
                    Text("\(s.filename) · \(s.frameCount) frames · \(s.durationDescription) · "
                         + "\(formatBytes(s.totalBytesC2S)) in / \(formatBytes(s.totalBytesS2C)) out")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("Browse a .xtap. Inspect requests, replies, events.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Open\u{2026}") { model.chooseFileAndOpen() }
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(20)
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

// MARK: - Row list (left pane)

private struct RowList: View {
    @ObservedObject var model: OpenModel

    var body: some View {
        List(model.rows, selection: $model.selectedRowId) { row in
            // One-line row. Title (e.g. PolyFillRectangle) in primary
            // weight, the trailing detail muted and truncated.
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .tag(row.id)
        }
        .listStyle(.inset)
    }
}

// MARK: - Detail pane (right)

private struct DetailPane: View {
    @ObservedObject var model: OpenModel

    private var selectedRow: CaptureRow? {
        guard let id = model.selectedRowId else { return nil }
        return model.rows.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = selectedRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                    Text("Row \(row.id + 1) of \(model.rows.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                Divider()
                ScrollView {
                    Text(row.lineText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Pick a row to see details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
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
