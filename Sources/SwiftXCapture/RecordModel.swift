import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftXCaptureCore

// ObservableObject backing the Record window. Owns the Proxy +
// Recorder + RecentRequestSink for one session, exposes the
// observable state SwiftUI needs, and polls the sink ~10x/second
// to refresh on-screen counters and the recent-requests list.

enum RecordStatus: Equatable {
    case idle
    case running       // proxy started; client may or may not be connected
    case finished      // session ended cleanly
    case failed(String)

    var summary: String {
        switch self {
        case .idle:                 return "Idle"
        case .running:              return "Running — waiting for or serving a client"
        case .finished:             return "Session ended"
        case .failed(let message):  return "Failed: \(message)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class RecordModel: ObservableObject {

    // MARK: - User-editable inputs (persisted)

    @AppStorage("record.listenPort") var listenPort: Int = 6001
    @AppStorage("record.forwardTarget") var forwardTarget: String = ""
    @AppStorage("record.outputDirectory") var outputDirectory: String = ""

    // MARK: - Observed state

    @Published var outputPath: String = ""
    @Published var status: RecordStatus = .idle
    @Published var bytesIn: Int = 0
    @Published var bytesOut: Int = 0
    @Published var recentRequests: [String] = []

    // MARK: - Backing pieces (one set per active session)

    private var proxy: Proxy?
    private var sink: RecentRequestSink?
    private var pollTimer: Timer?

    init() {
        if outputDirectory.isEmpty {
            outputDirectory = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        }
        outputPath = defaultOutputPath()
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }

        let parsed = parseForwardTarget(forwardTarget)
        guard let (forwardHost, forwardPort) = parsed else {
            status = .failed("Forward target must be host:port (e.g., sun-b.lan:6000).")
            return
        }
        guard listenPort > 0 else {
            status = .failed("Listen port must be > 0.")
            return
        }

        // Reset counters for the new session.
        bytesIn = 0
        bytesOut = 0
        recentRequests = []

        let recorder: Recorder
        do {
            recorder = try Recorder(
                outputPath: outputPath,
                listen: ":\(listenPort)",
                forward: "\(forwardHost):\(forwardPort)"
            )
        } catch {
            status = .failed("Could not create recorder: \(error)")
            return
        }

        let teeSink = RecentRequestSink(wrapping: recorder)
        let proxy = Proxy(
            listenHost: "0.0.0.0",
            listenPort: UInt16(listenPort),
            forwardHost: forwardHost,
            forwardPort: UInt16(forwardPort),
            sink: teeSink
        )
        do {
            _ = try proxy.start()
        } catch {
            status = .failed("Could not bind :\(listenPort): \(error)")
            return
        }

        self.proxy = proxy
        self.sink = teeSink
        self.status = .running

        startPolling()

        // Pump the proxy on a background queue; main thread keeps
        // running the UI. When run() returns, finalize and update
        // state back on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var runError: Error?
            do {
                try proxy.run()
            } catch {
                runError = error
            }
            do {
                try teeSink.finalize()
            } catch {
                runError = runError ?? error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopPolling()
                self.refreshFromSnapshot()
                if let err = runError {
                    self.status = .failed("Session error: \(err)")
                } else {
                    self.status = .finished
                }
            }
        }
    }

    func stop() {
        guard status.isRunning else { return }
        proxy?.stop()
        // proxy.run() will return on the background queue; the
        // completion block transitions status and finalises the
        // recorder. Nothing else to do here.
    }

    // MARK: - Output path

    func refreshDefaultOutputPath() {
        outputPath = defaultOutputPath()
    }

    func chooseOutputPath() {
        let panel = NSSavePanel()
        panel.title = "Save Capture As"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xtap") ?? .data
        ]
        panel.nameFieldStringValue = (outputPath as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (outputPath as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
            outputDirectory = (url.path as NSString).deletingLastPathComponent
        }
    }

    // MARK: - Helpers

    /// Default output path under the user's chosen directory, named
    /// with the current timestamp so successive runs don't clobber
    /// each other.
    private func defaultOutputPath() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let filename = "swiftx-capture-\(f.string(from: Date())).xtap"
        return (outputDirectory as NSString).appendingPathComponent(filename)
    }

    /// "host:port" → (host, port). Returns nil on malformed input.
    private func parseForwardTarget(_ s: String) -> (String, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard !host.isEmpty,
              let port = Int(trimmed[trimmed.index(after: colon)...]),
              port > 0, port < 65536
        else { return nil }
        return (host, port)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Timer fires on the runloop it was scheduled on (main).
            DispatchQueue.main.async { self?.refreshFromSnapshot() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshFromSnapshot() {
        guard let snap = sink?.snapshot() else { return }
        if snap.bytesIn != bytesIn { bytesIn = snap.bytesIn }
        if snap.bytesOut != bytesOut { bytesOut = snap.bytesOut }
        if snap.recent != recentRequests { recentRequests = snap.recent }
    }
}
