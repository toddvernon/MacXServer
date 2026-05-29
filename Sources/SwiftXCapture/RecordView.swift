import SwiftUI
import SwiftXCaptureCore

// Record mode. macXcapture is a one-shot proxy: it sits between an
// X client and a real X server, records every frame both ways to a
// `.xtap` file, and shows live progress.
//
// The screen is a top-to-bottom wizard of six panels. Setup panels
// (1-4) stay live until a capture starts; once running they dim and
// the capture panel (5) lights up; when the session ends the done
// panel (6) lights up with the file path and follow-up actions.

struct RecordView: View {

    @StateObject private var model = RecordModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step1
                    step2
                    step3
                    step4
                    step5
                    step6
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 640, idealHeight: 860)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BackToMenuButton(from: .record, disabled: model.status.isRunning)
            Image(systemName: "recordingtape")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("Record").font(.largeTitle)
                Text("A one-shot proxy that records the wire between an X client and your X server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 1: listen

    private var step1: some View {
        StepPanel(number: 1, title: "Listen on this Mac", enabled: !model.status.isRunning) {
            Text("macXcapture acts as a proxy. Pick the X display it listens on:")
                .foregroundStyle(.secondary)
            Picker("", selection: $model.listenDisplay) {
                Text("Port 6000  —  X display :0").tag(0)
                Text("Port 6001  —  X display :1").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Don't forget to let the client connect to this Mac:")
                .foregroundStyle(.secondary)
            CodeBox(text: "xhost +              (allow any host)\nxhost + \(model.macAddress)   (allow just this Mac)")
        }
    }

    // MARK: - Step 2: client DISPLAY (read-only)

    private var step2: some View {
        StepPanel(number: 2, title: "Point the client's DISPLAY here", enabled: !model.status.isRunning) {
            Text("On the X client machine, set its DISPLAY to this Mac's capture proxy:")
                .foregroundStyle(.secondary)
            CodeBox(text: "setenv DISPLAY \(model.macAddress):\(model.listenDisplay)\nexport DISPLAY=\(model.macAddress):\(model.listenDisplay)")
            Text("Auto-filled from step 1 — \(model.macAddress) is this Mac's primary address.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Step 3: forward target

    private var step3: some View {
        StepPanel(number: 3, title: "Forward to your X server", enabled: !model.status.isRunning) {
            Text("Captured traffic is passed straight through to your real X server. Where is it?")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Host / IP:").foregroundStyle(.secondary)
                TextField(subnetExample, text: $model.forwardHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            Picker("", selection: $model.forwardDisplayNumber) {
                Text("X display :0  (port 6000)").tag(0)
                Text("X display :1  (port 6001)").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    // MARK: - Step 4: name + start

    private var step4: some View {
        StepPanel(number: 4, title: "Name & start", enabled: !model.status.isRunning) {
            Text("Name your capture (a filename, or a full path):")
                .foregroundStyle(.secondary)
            TextField("macxcapture.xtap", text: $model.captureName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Saves to:").foregroundStyle(.tertiary)
                Text(model.resolvedOutputPath)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Button("Start Capture") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!model.canStart)
                if case .failed(let msg) = model.status {
                    Text(msg).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Step 5: capturing

    private var step5: some View {
        StepPanel(number: 5, title: "Capture", enabled: model.status.isRunning) {
            Text("Start your X app on the client. Its window should appear on the X server, with stats below.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Stop Capture", role: .destructive) { model.stop() }
                Text("\(formatBytes(model.bytesIn)) in / \(formatBytes(model.bytesOut)) out")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.status.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            recentFeed
        }
    }

    private var recentFeed: some View {
        Group {
            if model.recentRequests.isEmpty {
                Text(model.status.isRunning
                     ? "Waiting for a client to send something\u{2026}"
                     : "No traffic yet.")
                    .foregroundStyle(.tertiary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recentRequests.enumerated()), id: \.offset) { _, name in
                            Text(name)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 160)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.textBackgroundColor))
                )
            }
        }
    }

    // MARK: - Step 6: done

    private var step6: some View {
        StepPanel(number: 6, title: "Done", enabled: isFinished) {
            if isFinished {
                Text("Your capture is saved at:")
                    .foregroundStyle(.secondary)
                Text(model.outputPath)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 12) {
                    Button("Open Capture Folder") { model.openCaptureFolder() }
                    Button("View Capture") { model.viewCapture() }
                }
                .padding(.top, 2)
            } else {
                Text("After you stop the capture, the file path and these actions appear here.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isFinished: Bool {
        if case .finished = model.status { return true }
        return false
    }

    // MARK: - Helpers

    /// "192.168.7.42" → "192.168.7.X"-style hint anchored to the
    /// Mac's subnet, shown as the forward-host placeholder. Falls back
    /// to a generic hint when the IP can't be decomposed.
    private var subnetExample: String {
        let parts = model.macAddress.split(separator: ".")
        guard parts.count == 4 else { return "x-server-host" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).X"
    }
}

// MARK: - Panel chrome

/// One wizard step: numbered chip, title, then content. Dims and
/// disables itself when `enabled` is false so the user sees which
/// step is live.
private struct StepPanel<Content: View>: View {
    let number: Int
    let title: String
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(enabled ? Color.accentColor : Color.secondary))
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
        )
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

/// Monospaced, selectable command block with a subtle background.
private struct CodeBox: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.textBackgroundColor))
            )
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
