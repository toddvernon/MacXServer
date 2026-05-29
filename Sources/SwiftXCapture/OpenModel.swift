import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftXCaptureCore
import Framer

// ObservableObject backing the Open window. Reads a `.xtap` via
// CaptureReader, decodes the byte stream through ChronoDumper, and
// surfaces one row per X11 packet for the UI to scroll through.
//
// Step 7's MVP: list-and-detail navigation, no phase-tree grouping
// and no timeline scrubber. Both of those layers go on top of what
// ChronoDumper already gives us and are deferred to post-v2 polish.

// CaptureRow + its split helper live in SwiftXCaptureCore so unit
// tests in that target can exercise them. See CaptureRow.swift.

/// Top-of-file summary the header bar shows when a capture is loaded.
struct CaptureSummary: Equatable {
    var filename: String
    var frameCount: Int
    var durationNs: UInt64
    var totalBytesC2S: Int
    var totalBytesS2C: Int

    var durationDescription: String {
        if durationNs == 0 { return "—" }
        let s = Double(durationNs) / 1_000_000_000
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.2f s", s) }
        return String(format: "%.0f min %.0f s", s / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

@MainActor
final class OpenModel: ObservableObject {

    @Published var loadedPath: String?
    @Published var summary: CaptureSummary?
    /// Full decoded chrono dump (same text the shared viewer / .txt export
    /// use). Built once per load.
    @Published var decodedText: String = ""
    @Published var errorMessage: String?

    /// Show the system Open panel and load whatever the user picks.
    func chooseFileAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Capture"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xtap") ?? .data
        ]
        // Default to /tmp/swift-x-captures if it exists — that's where
        // server-side capture lands today.
        let defaultDir = "/tmp/swift-x-captures"
        if FileManager.default.fileExists(atPath: defaultDir) {
            panel.directoryURL = URL(fileURLWithPath: defaultDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(path: url.path)
    }

    /// Programmatic load — used by tests and by Open → Replay handoff
    /// once step 8 wires it up.
    func load(path: String) {
        loadedPath = path
        errorMessage = nil

        let frames: [CaptureFrame]
        do {
            frames = try CaptureReader.read(from: path)
        } catch {
            errorMessage = "Could not read \(path): \(error)"
            decodedText = ""
            summary = nil
            return
        }

        do {
            decodedText = try ChronoDumper.dump(path: path)
        } catch {
            errorMessage = "Capture file parses but decode failed: \(error)"
            decodedText = ""
            summary = computeSummary(path: path, frames: frames)
            return
        }

        summary = computeSummary(path: path, frames: frames)
    }

    /// Build the header-bar summary from frame data plus the sidecar
    /// JSON if present. The sidecar carries authoritative durations
    /// and byte totals; without it we fall back to summing frame
    /// payloads and using first-to-last timestamps.
    private func computeSummary(path: String, frames: [CaptureFrame]) -> CaptureSummary {
        let filename = (path as NSString).lastPathComponent

        // Sidecar may or may not exist.
        let jsonPath = path + ".json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
           let meta = try? JSONDecoder().decode(Metadata.self, from: data) {
            return CaptureSummary(
                filename: filename,
                frameCount: frames.count,
                durationNs: meta.durationNs,
                totalBytesC2S: meta.totalBytesC2S,
                totalBytesS2C: meta.totalBytesS2C
            )
        }

        // Fallback: derive from frames.
        let first = frames.first?.timestamp ?? 0
        let last = frames.last?.timestamp ?? 0
        let c2s = frames.filter { $0.direction == .clientToServer }
            .reduce(0) { $0 + $1.bytes.count }
        let s2c = frames.filter { $0.direction == .serverToClient }
            .reduce(0) { $0 + $1.bytes.count }
        return CaptureSummary(
            filename: filename,
            frameCount: frames.count,
            durationNs: last >= first ? (last - first) : 0,
            totalBytesC2S: c2s,
            totalBytesS2C: s2c
        )
    }
}
