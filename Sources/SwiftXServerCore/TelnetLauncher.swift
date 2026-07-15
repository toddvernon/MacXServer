import Foundation
import Network

public enum TelnetLaunchError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case loginTimeout
    case passwordTimeout
    case shellPromptTimeout
    case authenticationFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .loginTimeout: return "Timed out waiting for login prompt"
        case .passwordTimeout: return "Timed out waiting for password prompt"
        case .shellPromptTimeout: return "Timed out waiting for shell prompt"
        case .authenticationFailed: return "Authentication failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public final class TelnetLauncher: @unchecked Sendable {

    private enum State {
        case connecting, waitingForLogin, waitingForPassword, waitingForShell
        case sendingCommand, exiting, done, failed(Error)
    }

    private let entry: LauncherEntry
    private let password: String
    private let displayString: String
    /// Login probe: stop at the shell prompt. The full flow proves the
    /// credentials as a side effect of launching; probe mode makes that proof
    /// the whole job -- connect, log in, see a shell, type exit. Nothing runs
    /// on the box. This is how the Overview's Change Login sheet verifies an
    /// account on a machine that has no Helios agent (the Users panel's
    /// hash-check needs the agent; this needs only the box's own telnetd).
    private let probeOnly: Bool
    private var connection: NWConnection?
    private var state: State = .connecting
    private var buffer = Data()
    private let queue = DispatchQueue(label: "swiftx.telnet-launcher")
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var textCallback: ((String, Bool) -> Void)?
    private let stateTimeout: TimeInterval = 15.0
    /// Probe mode's quiet window: output arrived after the password with no
    /// rejection and no recognized prompt in it; once the line stays quiet
    /// this long, the login counts as proven (see the waitingForShell doc).
    private let settleQuiet: TimeInterval = 2.5
    private var settleWork: DispatchWorkItem?
    /// Probe mode, settle path only: the last non-blank line on screen when
    /// the output went quiet -- our best guess at the box's shell prompt.
    /// The wizard shows it to the user to validate and stores the confirmed
    /// text as `Machine.shellPrompt`, which is exactly the needle launches
    /// wait for. nil when the prompt was recognized outright (no needle
    /// needed) or when no output followed the password. Read it after the
    /// completion fires.
    public private(set) var suspectedShellPrompt: String?
    private var pendingEcho: [UInt8] = []

    public init(entry: LauncherEntry, password: String, displayString: String,
                probeOnly: Bool = false) {
        self.entry = entry; self.password = password; self.displayString = displayString
        self.probeOnly = probeOnly
    }

    /// A login probe for one machine account: reaches the shell prompt and
    /// exits, running nothing. `shellPrompt` nil = the built-in detection
    /// (classic sigils + the fleet's bracket prompt).
    public static func loginProbe(host: String, port: UInt16, user: String,
                                  password: String,
                                  shellPrompt: String? = nil) -> TelnetLauncher {
        let entry = LauncherEntry(name: "login probe", group: host,
                                  host: host, command: "", user: user,
                                  port: port,
                                  shellPrompt: shellPrompt ?? "$ ")
        return TelnetLauncher(entry: entry, password: password,
                              displayString: "", probeOnly: true)
    }

    public func onStatus(_ callback: @escaping (String) -> Void) {
        self.statusCallback = callback
    }

    public func onText(_ callback: @escaping (String, Bool) -> Void) {
        self.textCallback = callback
    }

    private func reportStatus(_ message: String) {
        let cb = statusCallback
        DispatchQueue.main.async { cb?(message) }
    }

    private func reportText(_ text: String, bold: Bool = false) {
        let cb = textCallback
        DispatchQueue.main.async { cb?(text, bold) }
    }

    public func launch(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        reportStatus("Connecting to \(entry.host):\(entry.port)...")
        let host = NWEndpoint.Host(entry.host)
        guard let port = NWEndpoint.Port(rawValue: entry.port) else {
            finish(.failure(TelnetLaunchError.connectionFailed("Invalid port \(entry.port)")))
            return
        }
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.reportStatus("Connected.")
                self.state = .waitingForLogin
                self.scheduleTimeout()
                self.receiveLoop()
            case .failed(let err):
                self.finish(.failure(TelnetLaunchError.connectionFailed(err.localizedDescription)))
            case .waiting(let err):
                // NWConnection parks a refused/unreachable connect in .waiting
                // (it would retry when the network changes). For a LAN telnet
                // login that's a failure NOW -- without this the launch hung
                // with no timeout armed (none is scheduled until .ready).
                // Surfaced by the login-probe's dead-port test, 2026-07-14.
                self.finish(.failure(TelnetLaunchError.connectionFailed(err.localizedDescription)))
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    public func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(TelnetLaunchError.cancelled))
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.processReceived(data)
            }
            if isComplete || error != nil {
                self.finish(.success(()))
            } else {
                self.receiveLoop()
            }
        }
    }

    // MARK: - State machine

    private func processReceived(_ data: Data) {
        let cleaned = stripTelnetCommands(data)
        buffer.append(cleaned)

        // Echo suppression: consume bytes that match what we sent.
        var displayBytes = Data()
        for byte in cleaned {
            if !pendingEcho.isEmpty && byte == pendingEcho.first! {
                pendingEcho.removeFirst()
            } else {
                displayBytes.append(byte)
            }
        }
        let newText = String(data: displayBytes, encoding: .utf8)
            ?? String(data: displayBytes, encoding: .ascii) ?? ""
        let displayText = Self.stripANSI(newText)
            .replacingOccurrences(of: "\r", with: "")
        if !displayText.isEmpty {
            reportText(displayText)
        }

        let fullText = String(data: buffer, encoding: .utf8)
            ?? String(data: buffer, encoding: .ascii) ?? ""
        let text = Self.stripANSI(fullText)
        let lower = text.lowercased()
        let shellPromptNeedle = entry.shellPrompt.trimmingCharacters(in: .whitespaces)

        switch state {
        case .waitingForLogin:
            if lower.contains(entry.loginPrompt.lowercased()) {
                reportText(entry.user + "\n", bold: true)
                queueEcho("\(entry.user)\r\n")
                sendText("\(entry.user)\r\n")
                buffer.removeAll()
                state = .waitingForPassword
                scheduleTimeout()
            }
        case .waitingForPassword:
            if lower.contains(entry.passwordPrompt.lowercased()) {
                reportText("****\n", bold: true)
                sendText("\(password)\r\n")
                buffer.removeAll()
                state = .waitingForShell
                scheduleTimeout()
            }
        case .waitingForShell:
            // Rejection is authoritative in every mode: the message markers,
            // plus a bare re-presented login prompt -- what telnetd does on a
            // bad password regardless of message wording (SunOS 4.1.4 and
            // Solaris 2.6 both print "Login incorrect" AND re-prompt; the
            // re-prompt check covers a telnetd whose message we don't know).
            if lower.contains("ogin incorrect") || lower.contains("ermission denied")
                || lower.contains("authentication fail")
                || Self.looksLikeLoginReprompt(text, loginPrompt: entry.loginPrompt) {
                finish(.failure(TelnetLaunchError.authenticationFailed))
                return
            }
            // The configured needle first; else generic prompt detection. The
            // "$ " default is sh/ksh-only -- csh says "hostname% ", root says
            // "# " -- and machine launchers have no per-launcher prompt keys
            // (those died with the old launchers file; the defaults in
            // LauncherEntry.build are the only prompt config left). So
            // "telnet works by hand, launcher times out waiting for shell
            // prompt" was the symptom against the real SS5 (2026-07-07).
            if text.contains(shellPromptNeedle) || Self.looksLikeShellPrompt(text) {
                cancelTimeout()
                cancelSettle()
                if probeOnly {
                    // Credentials proven (telnetd gave us a shell). Leave
                    // without running anything.
                    finishProbeSuccess()
                    return
                }
                state = .sendingCommand
                let cmd = "/bin/sh -c 'DISPLAY=\(displayString); export DISPLAY; " +
                          "nohup \(entry.command) </dev/null >/dev/null 2>&1 &'"
                reportText(cmd + "\n", bold: true)
                queueEcho(cmd + "\r\n")
                sendText(cmd + "\r\n")
                queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    self.reportText("exit\n", bold: true)
                    self.queueEcho("exit\r\n")
                    self.sendText("exit\r\n")
                    self.state = .exiting
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.finish(.success(()))
                    }
                }
            } else if probeOnly {
                // Output after the password, no rejection in it, no prompt
                // shape we recognize -- probably a banner/motd ahead of a
                // custom prompt. Let the line go quiet, then call the login
                // proven (the less-aggressive probe, 2026-07-16): telnetd
                // only keeps a session open past the password by spawning
                // the shell, and every real rejection announces itself. A
                // wizard user can't be asked what their prompt looks like.
                scheduleSettle()
            }
        default:
            break
        }
    }

    /// A re-presented login prompt after the password went in: telnetd's
    /// language-independent "no". The last non-blank line must END with the
    /// login-prompt needle (the default "ogin:" matches login:/Login:, and
    /// the suffix rule also catches getty's hostname-prefixed "ipc login:"),
    /// with one explicit carve-out: a line ending in "Last login:" -- a motd
    /// line, or a receive chunk cut off right at those words -- is the
    /// SUCCESS banner, never a rejection. Internal for unit testing.
    static func looksLikeLoginReprompt(_ text: String, loginPrompt: String) -> Bool {
        guard let lastLine = text.components(separatedBy: .newlines)
                .filter({ !$0.isEmpty })
                .last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !lastLine.isEmpty else { return false }
        let lower = lastLine.lowercased()
        let needle = loginPrompt.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, lower.hasSuffix(needle) else { return false }
        return !lower.contains("last login")
    }

    /// Generic shell-prompt detection: the last non-blank line ends with one
    /// of the classic prompt sigils ($ sh/ksh, % csh, # root, > some rc
    /// shells), optionally followed by a space. Only consulted AFTER the
    /// password went in (waitingForShell), so banner text can't trip it
    /// mid-login; the state timeout stays as the backstop. Internal for
    /// unit testing.
    static func looksLikeShellPrompt(_ text: String) -> Bool {
        // components(separatedBy: .newlines), not split(separator: "\n"):
        // Swift treats "\r\n" as ONE grapheme, so a Character split never
        // breaks CRLF lines -- and telnetd streams are CRLF. The bug hid
        // because the fleet's machines carry an explicit shellPrompt needle;
        // the login probe's fake telnetd exposed it (2026-07-14).
        guard let lastLine = text.components(separatedBy: .newlines)
                .filter({ !$0.isEmpty })
                .last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !lastLine.isEmpty,
              let sigil = lastLine.last else { return false }
        if sigil == "$" || sigil == "%" || sigil == "#" || sigil == ">" { return true }
        // The fleet's canonical csh prompt is "[host:[user]:/cwd] " -- a
        // bracket-wrapped last line (the shape that beat the sigil check on
        // the real SS5, 2026-07-07).
        return lastLine.hasPrefix("[") && sigil == "]"
    }

    static func stripANSI(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1B}", text.index(after: i) < text.endIndex {
                let next = text[text.index(after: i)]
                if next == "[" {
                    // CSI: ESC [ ... final byte in @-~
                    i = text.index(i, offsetBy: 2)
                    while i < text.endIndex {
                        let c = text[i]
                        i = text.index(after: i)
                        if c >= "@" && c <= "~" { break }
                    }
                    continue
                } else if next == "]" {
                    // OSC: ESC ] ... terminated by BEL or ST (ESC \). The
                    // xterm-branch prompt in .cshrc sets the window title this
                    // way; strip it so the progress window stays readable.
                    i = text.index(i, offsetBy: 2)
                    while i < text.endIndex {
                        let c = text[i]
                        if c == "\u{07}" { i = text.index(after: i); break }
                        if c == "\u{1B}", text.index(after: i) < text.endIndex,
                           text[text.index(after: i)] == "\\" {
                            i = text.index(i, offsetBy: 2); break
                        }
                        i = text.index(after: i)
                    }
                    continue
                }
            }
            result.append(text[i])
            i = text.index(after: i)
        }
        return result
    }

    // MARK: - Telnet IAC handling

    private func stripTelnetCommands(_ data: Data) -> Data {
        var clean = Data()
        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            // RFC 854: in ASCII mode a bare CR is transmitted as CR NUL --
            // SunOS telnetd does exactly this -- so NUL is protocol padding,
            // never application data. Left in the buffer it forms invisible
            // "lines" that broke both the generic prompt detection and the
            // wizard's suspected-prompt capture (an empty-looking Prompt
            // field, Todd's SWS2 test 2026-07-16).
            if bytes[i] == 0x00 { i += 1; continue }
            guard bytes[i] == 0xFF, i + 1 < bytes.count else {
                clean.append(bytes[i]); i += 1; continue
            }
            let cmd = bytes[i + 1]
            switch cmd {
            case 0xFB: // WILL
                if i + 2 < bytes.count { respondToWill(bytes[i + 2]); i += 3 } else { i = bytes.count }
            case 0xFC: // WONT
                i += min(3, bytes.count - i)
            case 0xFD: // DO
                if i + 2 < bytes.count { respondToDo(bytes[i + 2]); i += 3 } else { i = bytes.count }
            case 0xFE: // DONT
                i += min(3, bytes.count - i)
            case 0xFA: // SB <option> ... IAC SE
                var j = i + 2
                var sub: [UInt8] = []
                while j + 1 < bytes.count {
                    if bytes[j] == 0xFF && bytes[j + 1] == 0xF0 { break }
                    sub.append(bytes[j]); j += 1
                }
                handleSubnegotiation(sub)
                i = j + 1 < bytes.count ? j + 2 : bytes.count
            case 0xFF: // escaped 0xFF
                clean.append(0xFF); i += 2
            default:
                i += 2
            }
        }
        return clean
    }

    private func respondToDo(_ option: UInt8) {
        // 1 = echo, 3 = suppress-go-ahead, 24 = terminal-type.
        // We accept terminal-type so SunOS telnetd sets TERM=xterm for the
        // login shell; otherwise .cshrc's `if ($TERM == "xterm")` block never
        // runs and the `setprompt` alias it defines goes missing.
        if option == 1 || option == 3 || option == 24 {
            sendBytes([0xFF, 0xFB, option]) // IAC WILL
        } else {
            sendBytes([0xFF, 0xFC, option]) // IAC WONT
        }
    }

    private func respondToWill(_ option: UInt8) {
        if option == 1 || option == 3 {
            sendBytes([0xFF, 0xFD, option]) // IAC DO
        } else {
            sendBytes([0xFF, 0xFE, option]) // IAC DONT
        }
    }

    private func handleSubnegotiation(_ sub: [UInt8]) {
        // TERMINAL-TYPE (24) SEND (1) -> reply with IS "xterm" (RFC 1091).
        if sub.count >= 2 && sub[0] == 24 && sub[1] == 1 {
            sendBytes(Self.terminalTypeSubnegotiation("xterm"))
        }
    }

    static func terminalTypeSubnegotiation(_ term: String) -> [UInt8] {
        // IAC SB TERMINAL-TYPE IS <term> IAC SE
        var bytes: [UInt8] = [0xFF, 0xFA, 24, 0x00]
        bytes.append(contentsOf: Array(term.utf8))
        bytes.append(contentsOf: [0xFF, 0xF0])
        return bytes
    }

    // MARK: - Send helpers

    private func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func queueEcho(_ text: String) {
        pendingEcho.append(contentsOf: Array(text.utf8))
    }

    private func sendBytes(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed({ _ in }))
    }

    // MARK: - Timeout

    private func scheduleTimeout() {
        cancelTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let err: TelnetLaunchError
            switch self.state {
            case .waitingForLogin: err = .loginTimeout
            case .waitingForPassword: err = .passwordTimeout
            case .waitingForShell:
                if self.probeOnly {
                    // The password went in and nothing rejected it for the
                    // whole window -- a silent shell is still a shell. Only
                    // reachable when literally no output followed the
                    // password (any output arms the shorter settle timer).
                    self.reportStatus("Login accepted (no output after the password).")
                    self.finishProbeSuccess()
                    return
                }
                err = .shellPromptTimeout
                let needle = self.entry.shellPrompt.trimmingCharacters(in: .whitespaces)
                self.reportStatus("Shell prompt \"\(needle)\" not found in remote output.")
            default: return
            }
            self.finish(.failure(err))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + stateTimeout, execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    /// Arm (or re-arm -- every fresh chunk restarts the clock) probe mode's
    /// quiet window. Fires only if the session is still sitting in
    /// waitingForShell: quiet after an accepted password, no rejection seen,
    /// prompt shape unrecognized -> the login is proven.
    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, case .waitingForShell = self.state else { return }
            // The line went quiet; whatever it ends with is our best guess
            // at the shell prompt. Offered to the caller so the user can
            // validate it instead of being asked to know it cold.
            let text = Self.stripANSI(String(data: self.buffer, encoding: .utf8)
                ?? String(data: self.buffer, encoding: .ascii) ?? "")
            // Control characters (bell, backspace, stray padding) can lurk in
            // real prompt lines; they'd make the wizard's field look empty or
            // subtly wrong, so only printable text survives into the guess.
            let lastLine = text.components(separatedBy: .newlines)
                .map { line in
                    String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                        .trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty }
                .last
            self.suspectedShellPrompt = lastLine
            self.reportStatus("Login accepted (shell prompt shape not recognized).")
            self.finishProbeSuccess()
        }
        settleWork = work
        queue.asyncAfter(deadline: .now() + settleQuiet, execute: work)
    }

    private func cancelSettle() {
        settleWork?.cancel()
        settleWork = nil
    }

    /// Probe mode's one success exit: credentials proven, log back out
    /// without running anything. The exit lands whenever the shell is ready
    /// to read it (type-ahead), so this works even when the prompt was never
    /// recognized.
    private func finishProbeSuccess() {
        cancelTimeout()
        cancelSettle()
        reportText("exit\n", bold: true)
        queueEcho("exit\r\n")
        sendText("exit\r\n")
        state = .exiting
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finish(.success(()))
        }
    }

    // MARK: - Completion

    private func finish(_ result: Result<Void, Error>) {
        guard completion != nil else { return }
        cancelTimeout()
        cancelSettle()
        connection?.cancel()
        connection = nil
        let cb = completion
        completion = nil
        DispatchQueue.main.async { cb?(result) }
    }
}
