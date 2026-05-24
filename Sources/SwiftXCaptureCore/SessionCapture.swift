import Foundation

// SessionCapture: per-session capture file lifecycle for the server.
//
// The server allocates one of these per accepted client when capture is
// enabled. Three states:
//
//   1. **In-progress.** Constructor opens a Recorder pointed at
//      `<directory>/.in-progress-<sessionId>.xtap`. The `.in-progress-`
//      prefix marks the file as not-yet-named so UI listings can hide
//      it and a server crash leaves an obviously-incomplete artifact.
//
//   2. **Identified.** When the session observes a useful client name
//      (WM_CLASS, WM_NAME, or whatever signal fires first), it calls
//      `rename(toClientName:)` which switches the Recorder's planned
//      output path to `<timestamp>-<client-name>.xtap`. No disk I/O at
//      this point — Recorder writes only at finalize() — so the rename
//      is just a string update.
//
//   3. **Finalized.** Session disconnect calls `finalize()`, which
//      flushes the buffered frames to whatever path is currently set
//      (identified or still-in-progress) and writes the sidecar JSON.
//
// SessionCapture conforms to CaptureSink so the Listener's tee points
// don't care which sink they're feeding — Recorder for proxy capture,
// SessionCapture for server capture.
//
// Filename hygiene: `<client-name>` is sanitized to alphanumerics +
// underscore + dot + hyphen. Anything else becomes `_`. Empty names
// fall through to the in-progress filename so we never rename to
// nothing.

public final class SessionCapture: CaptureSink, @unchecked Sendable {

    public let sessionId: Int
    public let directory: String

    private let lock = NSLock()
    private let recorder: Recorder
    private let inProgressPath: String
    private var renamed: Bool = false

    /// Construct a capture for session `sessionId` rooted at
    /// `directory`. Creates the directory on first use if missing. The
    /// initial filename is `.in-progress-<sessionId>.xtap`; call
    /// `rename(toClientName:)` once the client identifies itself.
    public init(sessionId: Int, directory: String) throws {
        self.sessionId = sessionId
        self.directory = directory

        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        self.inProgressPath = (directory as NSString)
            .appendingPathComponent(".in-progress-\(sessionId).xtap")

        // listen/forward strings end up in the sidecar JSON. For
        // server-side capture they don't describe a proxy, so use the
        // tee-source phrasing.
        self.recorder = try Recorder(
            outputPath: inProgressPath,
            listen: "swiftx-server (in-process tee)",
            forward: "swiftx-server (in-process tee)"
        )
    }

    /// Switch the planned output path to a named one derived from the
    /// client's identifier. Idempotent: subsequent calls are no-ops, so
    /// the first signal wins (typically WM_CLASS arrives before
    /// WM_NAME). Safe to call after finalize() but has no effect.
    public func rename(toClientName name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !renamed else { return }
        let sanitized = Self.sanitize(name)
        guard !sanitized.isEmpty else { return }
        let timestamp = Self.timestampString()
        let newPath = (directory as NSString)
            .appendingPathComponent("\(timestamp)-\(sanitized).xtap")
        do {
            try recorder.setOutputPath(newPath)
            renamed = true
        } catch {
            // setOutputPath only throws on createDirectory failure;
            // we just created the parent in init, so this is unlikely.
            // Leave the in-progress path in place rather than crash.
        }
    }

    public func record(direction: Direction, bytes: [UInt8]) {
        recorder.record(direction: direction, bytes: bytes)
    }

    public func finalize() throws {
        try recorder.finalize()
    }

    // MARK: - Filename helpers

    /// Map an arbitrary client name to something safe for a filename:
    /// alphanumerics, underscore, dot, hyphen pass through; everything
    /// else collapses to `_`. Trims leading/trailing `_` so spaces in
    /// names don't produce ugly `_xterm_` artifacts.
    static func sanitize(_ name: String) -> String {
        let allowed = Set<Character>("abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let mapped = String(name.map { allowed.contains($0) ? $0 : "_" })
        return mapped.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// `YYYY-MM-DDTHH-MM-SS` in local time. Filename-safe (no colons),
    /// human-readable, sorts chronologically.
    static func timestampString(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: now)
    }
}
