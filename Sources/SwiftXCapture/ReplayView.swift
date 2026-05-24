import SwiftUI

// Replay mode (step 8). Pick a `.xtap`, point it at a target X
// server, optionally hold the connection open after the last
// frame. Same wire semantics as the v1 CLI's `replay` subcommand
// but driven by a Stop button rather than SIGINT.

struct ReplayView: View {

    @StateObject private var model = ReplayModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "play.circle")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replay").font(.largeTitle)
                    Text("Pipe a .xtap into a live X server. Smoke-test against your server or watch a recorded session render.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            // Inputs
            VStack(alignment: .leading, spacing: 14) {

                LabeledField("Capture") {
                    HStack(spacing: 8) {
                        Text(model.capturePath.map { ($0 as NSString).lastPathComponent } ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.capturePath == nil ? .tertiary : .primary)
                        Spacer()
                        Button("Choose\u{2026}") { model.chooseFile() }
                            .disabled(model.status.isRunning)
                    }
                }

                LabeledField("Target") {
                    HStack(spacing: 6) {
                        TextField("host", text: $model.targetHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.status.isRunning)
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField("port",
                                  value: $model.targetPort,
                                  format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.status.isRunning)
                            .frame(maxWidth: 80)
                    }
                }

                LabeledField("Pacing") {
                    Picker("", selection: Binding(
                        get: { model.pacing },
                        set: { model.pacing = $0 }
                    )) {
                        ForEach(ReplayPacing.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .disabled(model.status.isRunning)
                }

                LabeledField("Hold open") {
                    Toggle(isOn: $model.holdOpen) {
                        Text("Keep the connection alive after the last frame (Stop to close)")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.status.isRunning)
                }
            }
            .padding(20)
            Divider()

            // Action + status row
            HStack(spacing: 12) {
                if model.status.isRunning {
                    Button("Stop", role: .destructive) { model.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Start") { model.start() }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.capturePath == nil)
                }
                Text(model.status.summary)
                    .font(.callout)
                    .foregroundStyle(model.status.isError ? .red : .secondary)
                Spacer()
                Text("\(formatBytes(model.bytesSent)) sent / \(formatBytes(model.bytesReceived)) received")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            // Progress
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                HStack {
                    if model.totalFrames > 0 {
                        Text("\(model.framesSent) / \(model.totalFrames) frames")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pick a capture and click Start.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)

            Spacer()
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 520, idealHeight: 580)
    }

    private var progressFraction: Double {
        guard model.totalFrames > 0 else { return 0 }
        return Double(model.framesSent) / Double(model.totalFrames)
    }
}

/// Two-column row: label on the left, content on the right. Shared
/// shape with RecordView's labelled rows so the two modes feel like
/// the same form vocabulary.
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

private func formatBytes(_ n: Int) -> String {
    let k = 1024.0
    let d = Double(n)
    if d < k { return "\(n) B" }
    if d < k * k { return String(format: "%.1f KB", d / k) }
    if d < k * k * k { return String(format: "%.1f MB", d / (k * k)) }
    return String(format: "%.1f GB", d / (k * k * k))
}
