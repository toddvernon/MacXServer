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

    // The whole UI talks in X display numbers (:0, :1, ...) — port
    // numbers are an implementation detail (port = 6000 + display).
    // Storage matches the UI so there's only one convention to track.
    @AppStorage("record.listenDisplay") var listenDisplay: Int = 0
    @AppStorage("record.forwardDisplay") var forwardDisplay: String = ""  // "host:N"
    @AppStorage("record.outputDirectory") var outputDirectory: String = ""

    /// TCP port the proxy actually binds to. Always 6000 + display.
    var listenPort: Int { 6000 + listenDisplay }

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

        let parsed = parseForwardDisplay(forwardDisplay)
        guard let (forwardHost, forwardPort) = parsed else {
            status = .failed("Forward target must be host:N (e.g., sun-b.lan:0).")
            return
        }
        guard listenDisplay >= 0, listenDisplay < 1000 else {
            status = .failed("Listen display must be 0 or higher.")
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
        let filename = "macxcapture-\(f.string(from: Date())).xtap"
        return (outputDirectory as NSString).appendingPathComponent(filename)
    }

    /// "host:N" (display-number form) → (host, port = 6000 + N).
    /// Returns nil on malformed input.
    private func parseForwardDisplay(_ s: String) -> (String, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard !host.isEmpty,
              let display = Int(trimmed[trimmed.index(after: colon)...]),
              display >= 0, display < 1000
        else { return nil }
        return (host, 6000 + display)
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
