import Foundation

// SessionCapture: per-session capture file lifecycle for the server.
//
// The server allocates one of these per accepted client when capture is
// enabled. Three states:
//
//   1. **In-progress.** Constructor opens a Recorder pointed at
//      `<directory>/.in-progress-<sessionId>.xtap`. Recorder buffers
//      frames in memory and only writes at finalize() time, so this
//      path is just a placeholder that gets replaced before any file
//      is actually written. The `.in-progress-` prefix is a backstop
//      for the rare case where setOutputPath fails (mkdir error) on
//      both the rename-to-identified and rename-to-unidentified paths
//      below — in that case the file lands at .in-progress-<id>.xtap
//      and a UI listing's "hidden file" filter can flag it.
//
//   2. **Identified.** When the session observes a useful client name
//      (WM_NAME first, WM_CLASS later if available), it calls
//      `rename(toClientName:)` which switches the Recorder's planned
//      output path to `<timestamp>-<client-name>.xtap`. May be called
//      multiple times — last call wins. The server gates this on a
//      source-priority enum so an early WM_NAME doesn't get overridden
//      by stale data, but the canonical WM_CLASS does override an
//      earlier WM_NAME fallback. Recorder buffers until finalize(), so
//      the rename is just a planned-path swap; no on-disk artifact
//      churn.
//
//   3. **Finalized.** Session disconnect calls `finalize()`, which
//      flushes the buffered frames. If `rename(toClientName:)` was
//      never called (client disconnected before identifying — e.g.,
//      xclock hitting an unimplemented opcode and bailing 41 requests
//      in), finalize first renames to a visible
//      `<timestamp>-unidentified-<sessionId>.xtap` so the file isn't
//      hidden behind a dot-prefix in Finder. Such sessions are still
//      complete, useful bug-report captures and shouldn't be invisible
//      to the user.
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
            listen: "MacXServer (in-process tee)",
            forward: "MacXServer (in-process tee)"
        )
    }

    /// Switch the planned output path to a named one derived from the
    /// client's identifier. May be called multiple times — last call
    /// wins. The server fires this first on WM_NAME (fallback) and
    /// again on WM_CLASS (canonical) so the second call overrides the
    /// first when a client publishes both. Recorder buffers frames
    /// until finalize(), so renames before finalize are just planned-
    /// path swaps with no on-disk file moves. The `renamed` flag stays
    /// set after the first successful call so finalize() doesn't apply
    /// the unidentified-N fallback.
    public func rename(toClientName name: String) {
        lock.lock()
        defer { lock.unlock() }
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
        // If the session never identified itself, rename to a visible
        // fallback so the file shows up in Finder. The `.in-progress-`
        // path's dot-prefix is meant for crashed sessions, not for
        // sessions that simply disconnected before sending WM_CLASS.
        lock.lock()
        let needsFallback = !renamed
        lock.unlock()
        if needsFallback {
            let timestamp = Self.timestampString()
            let fallback = (directory as NSString)
                .appendingPathComponent("\(timestamp)-unidentified-\(sessionId).xtap")
            // setOutputPath only throws on mkdir failure; we made the
            // dir in init so this is unlikely. If it does fail, the
            // capture lands at the in-progress path — better than
            // losing the buffered frames.
            do {
                try recorder.setOutputPath(fallback)
                lock.lock()
                renamed = true
                lock.unlock()
            } catch {
                // Best effort; recorder.finalize() below still runs.
            }
        }
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
