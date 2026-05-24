import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftXCaptureCore

// ObservableObject for the Replay window. Owns one ReplayEngine
// per active session, polls progress callbacks (which fire on
// background threads from the engine) and mirrors them onto
// @Published fields on main.

enum ReplayPacing: String, CaseIterable, Identifiable, Sendable {
    case realtime
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .realtime: return "Real-time (timestamps from the capture)"
        case .fast:     return "Fast pump (no pacing)"
        }
    }
}

enum ReplayStatus: Equatable {
    case idle
    case running
    case finished(framesSent: Int, totalFrames: Int)
    case cancelled(framesSent: Int, totalFrames: Int)
    case failed(String)

    var summary: String {
        switch self {
        case .idle:                              return "Idle"
        case .running:                           return "Replaying\u{2026}"
        case .finished(let s, let t):            return "Done — \(s) of \(t) frames sent"
        case .cancelled(let s, let t):           return "Stopped — \(s) of \(t) frames sent"
        case .failed(let msg):                   return "Failed: \(msg)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class ReplayModel: ObservableObject {

    // Inputs (persisted across launches).
    @AppStorage("replay.targetHost") var targetHost: String = "localhost"
    @AppStorage("replay.targetPort") var targetPort: Int = 6000
    @AppStorage("replay.holdOpen") var holdOpen: Bool = true
    @AppStorage("replay.pacingRaw") private var pacingRaw: String = ReplayPacing.fast.rawValue

    var pacing: ReplayPacing {
        get { ReplayPacing(rawValue: pacingRaw) ?? .fast }
        set { pacingRaw = newValue.rawValue }
    }

    // Loaded capture state.
    @Published var capturePath: String?

    // Live progress.
    @Published var status: ReplayStatus = .idle
    @Published var framesSent: Int = 0
    @Published var totalFrames: Int = 0
    @Published var bytesSent: Int = 0
    @Published var bytesReceived: Int = 0

    private var engine: ReplayEngine?

    // MARK: - File picking

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Capture to Replay"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xtap") ?? .data
        ]
        let defaultDir = "/tmp/swift-x-captures"
        if FileManager.default.fileExists(atPath: defaultDir) {
            panel.directoryURL = URL(fileURLWithPath: defaultDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        capturePath = url.path
        // Reset counters for the new file.
        framesSent = 0
        totalFrames = 0
        bytesSent = 0
        bytesReceived = 0
        status = .idle
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }
        guard let path = capturePath else {
            status = .failed("No capture file selected.")
            return
        }
        guard targetPort > 0, targetPort < 65536 else {
            status = .failed("Target port must be 1–65535.")
            return
        }
        guard !targetHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = .failed("Target host must not be empty.")
            return
        }

        let frames: [CaptureFrame]
        do {
            frames = try CaptureReader.read(from: path)
        } catch {
            status = .failed("Could not read \(path): \(error)")
            return
        }

        framesSent = 0
        bytesSent = 0
        bytesReceived = 0
        totalFrames = frames.filter { $0.direction == .clientToServer }.count
        status = .running

        let engine = ReplayEngine(
            frames: frames,
            targetHost: targetHost,
            targetPort: UInt16(targetPort),
            realtime: pacing == .realtime,
            hold: holdOpen,
            onProgress: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.framesSent = p.framesSent
                    self.bytesSent = p.bytesSent
                    self.bytesReceived = p.bytesReceived
                    if self.totalFrames == 0 { self.totalFrames = p.totalFrames }
                }
            },
            onComplete: { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch outcome {
                    case .finished(let p):
                        self.applyProgress(p)
                        self.status = .finished(framesSent: p.framesSent, totalFrames: p.totalFrames)
                    case .cancelled(let p):
                        self.applyProgress(p)
                        self.status = .cancelled(framesSent: p.framesSent, totalFrames: p.totalFrames)
                    case .failed(let msg, let p):
                        self.applyProgress(p)
                        self.status = .failed(msg)
                    }
                    self.engine = nil
                }
            }
        )
        self.engine = engine
        engine.start()
    }

    func stop() {
        engine?.stop()
    }

    // MARK: - Helpers

    private func applyProgress(_ p: ReplayEngine.Progress) {
        framesSent = p.framesSent
        totalFrames = p.totalFrames
        bytesSent = p.bytesSent
        bytesReceived = p.bytesReceived
    }
}
