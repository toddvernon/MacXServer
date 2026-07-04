import Foundation

// HeliosLauncher -- launch an X client on the guest via the Helios daemon
// (Phase C, C7). The least-brittle transport: no telnet IAC/prompt state
// machine, no ssh login-shell quirks, no password/Keychain.
//
// It's a single `run_command` with a `user`: the daemon (root) drops privileges
// to that user, then runs the command under /bin/sh. So the client runs AS the
// configured user (with their identity + home/shell), and the Bourne wrapper
// (`DISPLAY=...; nohup ... &`) is always correct -- no tcsh/csh problem, because
// the daemon's shell is /bin/sh regardless of the user's login shell. The `&`
// backgrounds the client so run_command returns immediately while it keeps
// running. Connection: HeliosClient to `entry.host:entry.port` (port defaults
// to 2125) -- 127.0.0.1 over the qemu hostfwd for the bundled emulator, or a
// real Sun's address.

public final class HeliosLauncher: @unchecked Sendable {

    public enum HeliosLauncherError: Error, LocalizedError {
        case cancelled
        case nonzeroExit(Int)

        public var errorDescription: String? {
            switch self {
            case .cancelled:           return "launch cancelled"
            case .nonzeroExit(let c):  return "the launch command exited with status \(c)"
            }
        }
    }

    private let entry: LauncherEntry
    private let displayString: String
    /// The running guest's per-launch Helios secret (from `QemuEngine.currentSecret`).
    private let secret: String?
    /// Serializes the launcher's own state (callbacks, completion, cancelled);
    /// the blocking daemon call runs off this queue so cancel() stays responsive.
    private let queue = DispatchQueue(label: "swiftx.helios-launcher")
    private var completion: ((Result<Void, Error>) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var textCallback: ((String, Bool) -> Void)?
    private var cancelled = false

    public init(entry: LauncherEntry, displayString: String, secret: String? = nil) {
        self.entry = entry
        self.displayString = displayString
        self.secret = secret
    }

    public func onStatus(_ callback: @escaping (String) -> Void) {
        statusCallback = callback
    }

    public func onText(_ callback: @escaping (String, Bool) -> Void) {
        textCallback = callback
    }

    /// The /bin/sh command the daemon runs (as the target user). Prepends the
    /// Solaris X bin dirs (OpenWindows/CDE) so a bare `xterm` etc. resolves under
    /// the daemon's minimal env, sets DISPLAY, and backgrounds the client
    /// detached so run_command returns at once. Static and pure for unit testing.
    public static func remoteCommand(entry: LauncherEntry, displayString: String) -> String {
        "PATH=/usr/openwin/bin:/usr/dt/bin:/usr/bin/X11:$PATH; export PATH; " +
        "DISPLAY=\(displayString); export DISPLAY; " +
        // The daemon's `run_command --user` is a bare setuid: it sets HOME but
        // leaves cwd at the daemon's `/`, so a launched xterm would open in /
        // instead of the user's home (its prompt then shows `/`, looking like a
        // root prompt). chdir into HOME first; `;` not `&&` so a bad HOME just
        // launches in place rather than not at all.
        "cd \"$HOME\" 2>/dev/null; " +
        "nohup \(entry.command) </dev/null >/dev/null 2>&1 &"
    }

    public func launch(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.completion = completion
            if self.cancelled { self.finish(.failure(HeliosLauncherError.cancelled)); return }

            let cmd = Self.remoteCommand(entry: self.entry, displayString: self.displayString)
            self.reportStatus("Connecting to Helios daemon at \(self.entry.host):\(self.entry.port)\u{2026}")
            self.reportText("# run as \(self.entry.user), DISPLAY=\(self.displayString)\n", bold: true)
            self.reportText("$ \(cmd)\n", bold: true)

            let host = self.entry.host, port = self.entry.port
            let user = self.entry.user, name = self.entry.name
            let secret = self.secret
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Self.run(host: host, port: port, user: user, cmd: cmd, secret: secret)
                self.queue.async {
                    guard !self.cancelled, self.completion != nil else { return }
                    switch outcome {
                    case .success(let result):
                        if !result.output.isEmpty { self.reportText(result.output, bold: false) }
                        if result.exitCode == 0 {
                            self.reportStatus("Launched \(name).")
                            self.finish(.success(()))
                        } else {
                            self.reportStatus("Command exited \(result.exitCode).")
                            self.finish(.failure(HeliosLauncherError.nonzeroExit(result.exitCode)))
                        }
                    case .failure(let error):
                        self.reportStatus("FAILED: \(error.localizedDescription)")
                        self.finish(.failure(error))
                    }
                }
            }
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelled = true
            self.finish(.failure(HeliosLauncherError.cancelled))
        }
    }

    // MARK: - Internals

    /// One-shot connect + run_command as `user`. The `&` in `cmd` makes the
    /// daemon's shell return at once, so a short timeout is ample. Returns the
    /// daemon's result, or any transport error (incl. an unknown-user error).
    private static func run(host: String, port: UInt16,
                            user: String, cmd: String, secret: String?) -> Result<RunResult, Error> {
        let client = HeliosClient(host: host, port: port, timeout: 15, secret: secret)
        defer { client.close() }
        do {
            try client.connect()
            return .success(try client.runCommand(cmd, timeoutMs: 10_000, user: user))
        } catch {
            return .failure(error)
        }
    }

    private func reportStatus(_ message: String) {
        let cb = statusCallback
        DispatchQueue.main.async { cb?(message) }
    }

    private func reportText(_ text: String, bold: Bool) {
        let cb = textCallback
        DispatchQueue.main.async { cb?(text, bold) }
    }

    /// Fire the completion exactly once, on the main queue.
    private func finish(_ result: Result<Void, Error>) {
        guard let cb = completion else { return }
        completion = nil
        DispatchQueue.main.async { cb(result) }
    }
}

extension HeliosLauncher: RemoteLauncher {}
