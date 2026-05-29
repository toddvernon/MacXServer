import Foundation
import AppKit
import SwiftUI
import SwiftXCaptureCore
import SwiftXCaptureUI

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

    /// Where captures land by default. The wizard names files here
    /// unless the user types an absolute path of their own.
    static let captureDirectory = "/tmp/swift-x-captures"

    // MARK: - User-editable inputs (persisted)

    // The whole UI talks in X display numbers (:0, :1, ...) — port
    // numbers are an implementation detail (port = 6000 + display).
    // Storage matches the UI so there's only one convention to track.
    @AppStorage("record.listenDisplay") var listenDisplay: Int = 0
    @AppStorage("record.forwardHost") var forwardHost: String = ""
    @AppStorage("record.forwardDisplayNumber") var forwardDisplayNumber: Int = 0
    @AppStorage("record.captureName") var captureName: String = ""

    /// TCP port the proxy binds to (step 1). Always 6000 + display.
    var listenPort: Int { 6000 + listenDisplay }
    /// TCP port we forward to on the real X server (step 3).
    var forwardPort: Int { 6000 + forwardDisplayNumber }

    /// First non-loopback IPv4 — the address the client points its
    /// DISPLAY at (step 2). Best-guess primary; falls back to a
    /// placeholder when every interface is down.
    var macAddress: String {
        enumerateIPv4Interfaces().first { !$0.isLoopback }?.address ?? "your-mac-ip"
    }

    /// What the capture file will actually be written to, derived live
    /// from the name field (step 4): an absolute path (or ~) is used
    /// as-is; a bare filename lands in `captureDirectory`. The `.xtap`
    /// extension is appended if the user leaves it off.
    var resolvedOutputPath: String {
        var name = captureName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "macxcapture.xtap" }
        if !name.lowercased().hasSuffix(".xtap") { name += ".xtap" }
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (Self.captureDirectory as NSString).appendingPathComponent(expanded)
    }

    /// Gate for the Start button: need somewhere to forward to and not
    /// already running.
    var canStart: Bool {
        !status.isRunning && !forwardHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Observed state

    /// The path the most recent (or current) session writes to. Set at
    /// start(); read by step 6 for the "saved at" line and actions.
    @Published var outputPath: String = ""
    @Published var status: RecordStatus = .idle
    @Published var bytesIn: Int = 0
    @Published var bytesOut: Int = 0
    @Published var recentRequests: [String] = []

    // MARK: - Backing pieces (one set per active session)

    private var proxy: Proxy?
    private var sink: RecentRequestSink?
    private var pollTimer: Timer?

    /// Retains open viewer windows so they aren't deallocated the
    /// instant viewCapture() returns. Dropped on window close.
    private var viewers: [CaptureViewerWindowController] = []

    init() {
        if captureName.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            captureName = "macxcapture-\(f.string(from: Date())).xtap"
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }

        let host = forwardHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            status = .failed("Enter the X server host to forward to (step 3).")
            return
        }

        let outPath = resolvedOutputPath
        outputPath = outPath

        // Make sure the capture directory exists before the recorder
        // tries to open the file in it.
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        // Reset counters for the new session.
        bytesIn = 0
        bytesOut = 0
        recentRequests = []

        let recorder: Recorder
        do {
            recorder = try Recorder(
                outputPath: outPath,
                listen: ":\(listenPort)",
                forward: "\(host):\(forwardPort)"
            )
        } catch {
            status = .failed("Could not create recorder: \(error)")
            return
        }

        let teeSink = RecentRequestSink(wrapping: recorder)
        let proxy = Proxy(
            listenHost: "0.0.0.0",
            listenPort: UInt16(listenPort),
            forwardHost: host,
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

    // MARK: - Step 6 actions

    /// Reveal the finished capture in Finder, selected.
    func openCaptureFolder() {
        guard !outputPath.isEmpty else { return }
        let folder = (outputPath as NSString).deletingLastPathComponent
        NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: folder)
    }

    /// Decode the finished capture and open it in the read-only
    /// syntax viewer (same component the Open screen uses).
    func viewCapture() {
        guard !outputPath.isEmpty else { return }
        let text: String
        do {
            text = try ChronoDumper.dump(path: outputPath)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open capture"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        let controller = CaptureViewerWindowController(
            title: (outputPath as NSString).lastPathComponent,
            sourcePath: outputPath,
            text: text
        )
        controller.onClose = { [weak self, weak controller] in
            self?.viewers.removeAll { $0 === controller }
        }
        viewers.append(controller)
        controller.showWindow()
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
