import SwiftUI

// Record mode (step 6). Proxy capture between an X client and a
// real X server — bytes pass through faithfully, both directions
// land in a `.xtap` file, and the UI shows live progress.

struct RecordView: View {

    @StateObject private var model = RecordModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "recordingtape")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record").font(.largeTitle)
                    Text("Sit between an X client and an X server. Save the wire traffic to a .xtap file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Listen on") {
                    HStack(spacing: 4) {
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField("6001", value: $model.listenPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.status.isRunning)
                            .frame(maxWidth: 100)
                        Text("(the X display port on this Mac that clients dial)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledField("Forward to") {
                    TextField("host:port (e.g., sun-b.lan:6000)",
                              text: $model.forwardTarget)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.status.isRunning)
                }

                LabeledField("Output") {
                    HStack(spacing: 8) {
                        TextField("", text: $model.outputPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.status.isRunning)
                        Button("Choose\u{2026}") {
                            model.chooseOutputPath()
                        }
                        .disabled(model.status.isRunning)
                    }
                }
            }
            .padding(20)
            Divider()

            // Action row
            HStack(spacing: 12) {
                if model.status.isRunning {
                    Button("Stop", role: .destructive) { model.stop() }
                        .keyboardShortcut(.return)
                } else {
                    Button("Start") {
                        model.refreshDefaultOutputPath()
                        model.start()
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
                Text(model.status.summary)
                    .font(.callout)
                    .foregroundStyle(model.statusIsError ? .red : .secondary)
                Spacer()
                Text("\(formatBytes(model.bytesIn)) in / \(formatBytes(model.bytesOut)) out")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            // Recent requests feed
            VStack(alignment: .leading, spacing: 6) {
                Text("Last requests")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if model.recentRequests.isEmpty {
                    HStack {
                        Spacer()
                        Text(model.status.isRunning
                             ? "Waiting for a client to send something\u{2026}"
                             : "No traffic yet.")
                            .foregroundStyle(.tertiary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 32)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.recentRequests.enumerated()), id: \.offset) { _, name in
                                Text(name)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 540, idealHeight: 640)
    }
}

private extension RecordStatus {
    /// For the status-line tinting. `failed` is the only state that
    /// reads as an error to the user.
    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension RecordModel {
    var statusIsError: Bool { status.isError }
}

/// Two-column row: label on the left, content on the right. The label
/// has a fixed width so all rows line up.
private struct LabeledField<Content: View>: View {
    let label: String
    let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label + ":")
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Format a byte count for the status line. Plain integer up to
/// 1 KiB, then K/M/G with one decimal place.
private func formatBytes(_ n: Int) -> String {
    let k = 1024.0
    let d = Double(n)
    if d < k { return "\(n) B" }
    if d < k * k { return String(format: "%.1f KB", d / k) }
    if d < k * k * k { return String(format: "%.1f MB", d / (k * k)) }
    return String(format: "%.1f GB", d / (k * k * k))
}
