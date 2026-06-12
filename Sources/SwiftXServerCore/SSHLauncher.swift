import Foundation

public enum SSHLaunchError: Error, LocalizedError, Sendable {
    case spawnFailed(String)
    case authenticationFailed
    case nonZeroExit(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let s): return "Failed to spawn ssh: \(s)"
        case .authenticationFailed:
            return "ssh authentication failed (BatchMode is on; this launcher needs key-based auth)"
        case .nonZeroExit(let code): return "ssh exited \(code)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Drives a remote launch over ssh by spawning `/usr/bin/ssh` and letting
/// it handle the protocol. Key-based auth only (BatchMode=yes refuses to
/// prompt for a password), so the user must have ssh keys set up to the
/// target host before this works. We don't use ssh's X11 forwarding
/// (`-X`/`-Y`): the wrapped command sets `DISPLAY` directly, matching the
/// telnet flow, so the X client opens a TCP connection back to our server
/// on port 6000 — same as everything else.
public final class SSHLauncher: @unchecked Sendable {
    private let entry: LauncherEntry
    private let displayString: String
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let queue = DispatchQueue(label: "swiftx.ssh-launcher")
    private var completion: ((Result<Void, Error>) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var textCallback: ((String, Bool) -> Void)?
    private var stderrBuffer = ""

    public init(entry: LauncherEntry, displayString: String) {
        self.entry = entry
        self.displayString = displayString
    }

    public func onStatus(_ callback: @escaping (String) -> Void) {
        self.statusCallback = callback
    }

    public func onText(_ callback: @escaping (String, Bool) -> Void) {
        self.textCallback = callback
    }

    public func launch(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        let args = Self.buildArguments(entry: entry, displayString: displayString)
        reportStatus("Spawning: ssh \(args.joined(separator: " "))")
        reportText("ssh " + args.joined(separator: " ") + "\n", bold: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // No stdin: with BatchMode=yes ssh won't prompt, but explicitly
        // closing stdin makes that contract obvious.
        p.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.handleChunk(data, isStderr: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.handleChunk(data, isStderr: true)
        }

        p.terminationHandler = { [weak self] proc in
            self?.queue.async {
                guard let self = self else { return }
                // Drain whatever's left in the pipes.
                if let outRest = try? outPipe.fileHandleForReading.readToEnd(), !outRest.isEmpty {
                    self.handleChunk(outRest, isStderr: false)
                }
                if let errRest = try? errPipe.fileHandleForReading.readToEnd(), !errRest.isEmpty {
                    self.handleChunk(errRest, isStderr: true)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                if proc.terminationReason == .uncaughtSignal {
                    self.finish(.failure(SSHLaunchError.cancelled))
                    return
                }
                let code = proc.terminationStatus
                if code == 0 {
                    self.reportStatus("Launched.")
                    self.finish(.success(()))
                } else if Self.stderrLooksLikeAuthFailure(self.stderrBuffer) {
                    self.finish(.failure(SSHLaunchError.authenticationFailed))
                } else {
                    self.finish(.failure(SSHLaunchError.nonZeroExit(code)))
                }
            }
        }

        self.process = p
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        do {
            try p.run()
            reportStatus("Connecting to \(entry.host):\(entry.port)...")
        } catch {
            finish(.failure(SSHLaunchError.spawnFailed(error.localizedDescription)))
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            self?.process?.terminate()
        }
    }

    // MARK: - Argument construction

    /// Build the ssh argv. Public so the unit test can pin the exact form;
    /// keeping it static and pure makes the construction trivially testable
    /// without driving an actual ssh process.
    public static func buildArguments(entry: LauncherEntry, displayString: String) -> [String] {
        // Wrap in /bin/sh -c '...' so the syntax is Bourne regardless of
        // the remote user's login shell. Without this, accounts whose
        // login shell is csh/tcsh (a common Unix-old-school setup) reject
        // `DISPLAY=...; export DISPLAY` outright -- csh wants `setenv`.
        // Same wrap as the telnet path; same single-quote gotcha applies
        // (a literal single quote inside `command` breaks the wrap; the
        // seed comment in DefaultLaunchers documents the workaround).
        let inner = "DISPLAY=\(displayString); export DISPLAY; " +
                    "nohup \(entry.command) </dev/null >/dev/null 2>&1 &"
        let remote = "/bin/sh -c '\(inner)'"
        return [
            "-T",                                          // no pseudo-TTY (we're not interactive)
            "-o", "BatchMode=yes",                         // refuse to prompt for a password
            "-o", "StrictHostKeyChecking=accept-new",      // TOFU: auto-accept new hosts, warn on change
            "-o", "ConnectTimeout=15",                     // give up after 15s
            "-p", String(entry.port),
            "\(entry.user)@\(entry.host)",
            remote
        ]
    }

    /// ssh's stderr text patterns that mean "couldn't authenticate." Used
    /// only to refine the error message; failure is still detected by the
    /// non-zero exit code.
    static func stderrLooksLikeAuthFailure(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("permission denied")
            || lower.contains("publickey")
            || lower.contains("no supported authentication methods")
            || lower.contains("host key verification failed")
    }

    // MARK: - I/O handling

    private func handleChunk(_ data: Data, isStderr: Bool) {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return }
        if isStderr {
            queue.async { [weak self] in self?.stderrBuffer.append(s) }
        }
        reportText(s)
    }

    private func reportStatus(_ message: String) {
        let cb = statusCallback
        DispatchQueue.main.async { cb?(message) }
    }

    private func reportText(_ text: String, bold: Bool = false) {
        let cb = textCallback
        DispatchQueue.main.async { cb?(text, bold) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard completion != nil else { return }
        let cb = completion
        completion = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        DispatchQueue.main.async { cb?(result) }
    }
}

extension SSHLauncher: RemoteLauncher {}
