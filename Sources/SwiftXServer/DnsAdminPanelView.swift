import SwiftUI
import AppKit
import SwiftXServerCore
import SwiftXCaptureUI

// First tier of the C6 guided-sysadmin GUI: edit the guest's /etc/resolv.conf
// over the Helios daemon. Reads the live file into the shared dark code editor
// (line numbers + resolv.conf syntax coloring), tracks dirty state, and writes
// it back when the user hits Apply. Same view/model/dirty shape as the
// Resources editor, but the file lives on the SPARCstation, not on disk here.

struct DnsAdminPanelView: View {

    @StateObject private var model: DnsAdminPanelModel

    init(secretProvider: @escaping () -> String?) {
        _model = StateObject(wrappedValue: DnsAdminPanelModel(secretProvider: secretProvider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CodeEditorView(
                text: $model.text,
                theme: .dark,
                makeHighlighter: { theme, font in
                    ResolvConfSyntaxHighlighter(theme: theme, baseFont: font)
                }
            )
            .frame(minHeight: 260)
            actionRow
            bannerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 600, minHeight: 440)
        .onAppear { model.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("DNS")
                    .font(.title2)
                Text("Edit /etc/resolv.conf on the running SPARCstation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Reload") { model.load() }
                .disabled(model.busy)
            Button("Apply") { model.apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty || model.busy)
        }
    }

    // MARK: - Banner

    private var bannerRow: some View {
        Text(model.banner.isEmpty ? " " : model.banner)
            .font(.caption)
            .foregroundStyle(model.bannerIsError ? .red : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - View model

@MainActor
final class DnsAdminPanelModel: ObservableObject {

    // nonisolated so the off-main Helios closures can name it without tripping
    // main-actor isolation (it's an immutable Sendable constant).
    nonisolated static let remotePath = "/etc/resolv.conf"

    @Published var text: String = "" {
        didSet { if !suppressDirty { dirty = true } }
    }
    @Published var dirty = false
    @Published var busy = false
    @Published var banner = ""
    @Published var bannerIsError = false

    // Breaks the dirty feedback loop when we replace the buffer from a load.
    private var suppressDirty = false
    // Preserved across a load so Apply writes the file back with its original
    // permission bits rather than guessing.
    private var loadedMode: Int?
    private let secretProvider: () -> String?

    init(secretProvider: @escaping () -> String?) {
        self.secretProvider = secretProvider
    }

    // MARK: - Helios I/O
    //
    // HeliosClient is blocking and one-request-in-flight, so each call runs on
    // a global queue with its own short-lived client (never shared across
    // threads) and hops back to the main actor for the UI. `busy` serializes
    // load/apply at the UI level so two ops can't overlap.

    func load() {
        guard !busy else { return }
        busy = true
        setBanner("Reading \(Self.remotePath) from the SPARCstation\u{2026}", error: false)
        let secret = secretProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<(String, Int), Error>
            let client = HeliosClient(secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                let content = try client.readFile(Self.remotePath)
                outcome = .success((String(decoding: content.data, as: UTF8.self), content.mode))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let (body, mode)):
                    self.suppressDirty = true
                    self.text = body
                    self.suppressDirty = false
                    self.dirty = false
                    self.loadedMode = mode
                    self.setBanner("Loaded \(Self.remotePath) (mode \(String(mode, radix: 8))).", error: false)
                case .failure(let error):
                    self.setBanner("Couldn\u{2019}t read \(Self.remotePath): \(Self.describe(error))", error: true)
                }
            }
        }
    }

    func apply() {
        guard dirty, !busy else { return }
        busy = true
        setBanner("Writing \(Self.remotePath) to the SPARCstation\u{2026}", error: false)
        let secret = secretProvider()
        let payload = Data(text.utf8)
        let mode = loadedMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Void, Error>
            let client = HeliosClient(secret: secret)
            defer { client.close() }
            do {
                try client.connect()
                _ = try client.writeFile(Self.remotePath, data: payload, mode: mode)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success:
                    self.dirty = false
                    self.setBanner("Applied. \(Self.remotePath) written to the SPARCstation.", error: false)
                case .failure(let error):
                    self.setBanner("Apply failed: \(Self.describe(error))", error: true)
                }
            }
        }
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }

    private static func describe(_ error: Error) -> String {
        (error as? HeliosClient.HeliosError)?.errorDescription ?? error.localizedDescription
    }
}
