import SwiftUI
import SwiftXCaptureCore

// Record mode (step 6). Proxy capture between an X client and a
// real X server — bytes pass through faithfully, both directions
// land in a `.xtap` file, and the UI shows live progress.
//
// The Record screen shows the proxy as a three-stop flow so the
// user can see at a glance: which machine runs the X client,
// what this Mac is listening on, and which X server the bytes go
// to. The middle and right cards are editable; the left card
// auto-derives its DISPLAY hint from the others.

struct RecordView: View {

    @StateObject private var model = RecordModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .top, spacing: 16) {
                BackToMenuButton(from: .record, disabled: model.status.isRunning)
                Image(systemName: "recordingtape")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record").font(.largeTitle)
                    Text("Capture the wire between an X client and the X server it talks to.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            // Three-stop flow
            HStack(alignment: .top, spacing: 0) {
                ClientCard(
                    macAddress: macDisplayAddress,
                    displayNumber: model.listenDisplay
                )
                FlowArrow()
                ProxyCard(
                    macAddress: macDisplayAddress,
                    displayNumber: $model.listenDisplay,
                    statusText: model.status.summary,
                    isError: model.statusIsError,
                    disabled: model.status.isRunning
                )
                FlowArrow()
                ServerCard(
                    forwardDisplay: $model.forwardDisplay,
                    placeholderExample: subnetExample,
                    disabled: model.status.isRunning
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Output row
            HStack(spacing: 10) {
                Text("Save capture to:")
                    .foregroundStyle(.secondary)
                TextField("", text: $model.outputPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.status.isRunning)
                Button("Choose\u{2026}") { model.chooseOutputPath() }
                    .disabled(model.status.isRunning)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
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
        .frame(minWidth: 820, idealWidth: 920, minHeight: 580, idealHeight: 680)
    }

    /// First non-loopback IPv4 to show in the client card so the user
    /// can copy-paste it into their DISPLAY env var. Falls back to a
    /// placeholder if all interfaces are down.
    private var macDisplayAddress: String {
        let ifaces = enumerateIPv4Interfaces().filter { !$0.isLoopback }
        return ifaces.first?.address ?? "your-mac-ip"
    }

    /// "192.168.7.42" → "192.168.7.X:0". Used as the server card's
    /// placeholder so the user sees a concrete example anchored to
    /// their actual subnet — just swap in the X server's last octet.
    /// Falls back to a generic hint when the Mac's IP can't be
    /// decomposed (rare; tunnel-only setups, etc.).
    private var subnetExample: String {
        let parts = macDisplayAddress.split(separator: ".")
        guard parts.count == 4 else { return "hostname:0" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).X:0"
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

// MARK: - Flow cards

/// ① The remote machine running the X client. Auto-derived: shows
/// the DISPLAY string and a sample command to run there.
private struct ClientCard: View {
    let macAddress: String
    let displayNumber: Int

    var body: some View {
        CardShell(stepNumber: 1, icon: "desktopcomputer", title: "Client machine") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run any X app there with its display pointed at this Mac:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("export DISPLAY=\(macAddress):\(displayNumber)")
                        .textSelection(.enabled)
                    Text("xterm")
                        .textSelection(.enabled)
                }
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                Text("(xterm here is just an example — could be xclock, a Motif app, anything.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ② This Mac, acting as the proxy. Composes the address + display
/// inline so the user reads the listen target as one continuous
/// "Capture listens on <ip>:[N]" sentence.
private struct ProxyCard: View {
    let macAddress: String
    @Binding var displayNumber: Int
    let statusText: String
    let isError: Bool
    let disabled: Bool

    var body: some View {
        CardShell(stepNumber: 2, icon: "recordingtape", title: "This Mac (capture)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Capture listens on")
                        .foregroundStyle(.secondary)
                    Text("\(macAddress):")
                        .textSelection(.enabled)
                    TextField("0", value: $displayNumber, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .disabled(disabled)
                        .frame(maxWidth: 50)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Text("(TCP port \(6000 + displayNumber))")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ③ The real X server the bytes get forwarded to. User types
/// host:N (display form); the port is shown below as the derived
/// value. Placeholder is anchored to the Mac's subnet so the user
/// sees a concrete starting point.
private struct ServerCard: View {
    @Binding var forwardDisplay: String
    let placeholderExample: String
    let disabled: Bool

    var body: some View {
        CardShell(stepNumber: 3, icon: "display", title: "X server") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Forward traffic to display:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(placeholderExample, text: $forwardDisplay)
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                if let (host, display) = parsedHostDisplay {
                    Text("(TCP port \(6000 + display) on \(host))")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("e.g., \(placeholderExample) — replace X with the X server's last octet.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "sun-b.lan:1" → ("sun-b.lan", 1). Used to show the derived
    /// port hint underneath the input.
    private var parsedHostDisplay: (host: String, display: Int)? {
        let s = forwardDisplay.trimmingCharacters(in: .whitespaces)
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        guard !host.isEmpty,
              let display = Int(s[s.index(after: colon)...]),
              display >= 0, display < 1000
        else { return nil }
        return (host, display)
    }
}

/// Shared chrome for the three flow cards: numbered chip, icon,
/// title, then arbitrary content.
private struct CardShell<Content: View>: View {
    let stepNumber: Int
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(stepNumber)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.tint))
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 180, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.8)
        )
    }
}

private struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 28)
            .padding(.top, 60)
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
