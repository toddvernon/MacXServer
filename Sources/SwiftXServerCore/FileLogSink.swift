import Foundation

// Per-session log sink. Writes every line to a file under
// `/tmp/macxserver/`, and optionally mirrors to stderr. The file is always
// written; stderr mirroring is off by default so a running server doesn't
// drown the terminal in per-op traces. Pass `alsoWriteStderr: true` (or
// run with `--verbose`) when you want the live trace too. The disk file is
// always available for `tail -F` when debugging.
//
// Each accepted connection gets its own sink and its own file — when
// WM_CLASS arrives the listener calls `rename` to retitle the file from a
// tentative `session-N-<timestamp>.log` to `<instance>-<timestamp>.log`
// (e.g. xterm-2026-05-08-13-58.log).

public final class FileLogSink: ServerLogSink, @unchecked Sendable {

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var currentURL: URL?
    private let alsoWriteStderr: Bool
    private let directory: URL
    private let timestampString: String

    /// Build a per-session log file. The file's initial name is
    /// `session-<n>-<timestamp>.log`; call `rename(toIdentified:)` once a
    /// real client identity is known.
    public init(sessionNumber: Int, alsoWriteStderr: Bool = false) {
        self.alsoWriteStderr = alsoWriteStderr
        self.directory = Self.logsDirectory()
        self.timestampString = Self.formatTimestamp(Date())
        let initialName = "session-\(sessionNumber)-\(timestampString).log"
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(initialName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.currentURL = url
    }

    deinit {
        try? fileHandle?.close()
    }

    public func log(_ line: String) {
        let lineWithNewline = line + "\n"
        let data = Data(lineWithNewline.utf8)
        lock.lock()
        try? fileHandle?.write(contentsOf: data)
        lock.unlock()
        if alsoWriteStderr {
            FileHandle.standardError.write(data)
        }
    }

    /// Rename the log file to use the supplied client instance name (from
    /// WM_CLASS). Idempotent — second/later calls are no-ops. Uses the
    /// timestamp captured at session start so a single client lifetime
    /// keeps the same file.
    public func rename(toIdentified instance: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let oldURL = currentURL else { return }
        let safe = sanitize(instance)
        let newName = "\(safe)-\(timestampString).log"
        let newURL = directory.appendingPathComponent(newName)
        guard newURL != oldURL else { return }
        // Close the handle, move the file, reopen the handle for append at
        // the new path. On macOS the FD-backed handle survives a rename
        // *most* of the time, but reopening is the bulletproof move and
        // we're not perf-bound here.
        try? fileHandle?.close()
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            currentURL = newURL
            fileHandle = try FileHandle(forWritingTo: newURL)
            try fileHandle?.seekToEnd()
        } catch {
            // Fall back to the old URL if the move failed (target already
            // exists, permissions, etc.). The session keeps logging there.
            fileHandle = try? FileHandle(forWritingTo: oldURL)
        }
    }

    /// Currently-active log file path. Useful for the menu-bar status item
    /// or test assertions.
    public var currentPath: String? {
        lock.lock(); defer { lock.unlock() }
        return currentURL?.path
    }

    // MARK: - Helpers

    private static func logsDirectory() -> URL {
        // /tmp is the project convention — ephemeral, no permission/sync
        // worries, easy to clean with rm -rf, easy to point an editor at.
        // Console.app won't index here automatically; that's fine since the
        // primary consumer is `tail -F` from a terminal.
        URL(fileURLWithPath: "/tmp/macxserver", isDirectory: true)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return f.string(from: date)
    }

    /// File-name-safe version of an X11 instance string. Strips anything
    /// that isn't a-z, A-Z, 0-9, or `-_`. Replaces with `_`.
    private func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = raw.map { allowed.contains($0) ? $0 : "_" }
        return mapped.isEmpty ? "client" : String(mapped)
    }
}
