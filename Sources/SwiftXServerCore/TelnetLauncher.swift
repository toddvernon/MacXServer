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
    private var connection: NWConnection?
    private var state: State = .connecting
    private var buffer = Data()
    private let queue = DispatchQueue(label: "swiftx.telnet-launcher")
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var textCallback: ((String, Bool) -> Void)?
    private let stateTimeout: TimeInterval = 15.0
    private var pendingEcho: [UInt8] = []

    public init(entry: LauncherEntry, password: String, displayString: String) {
        self.entry = entry; self.password = password; self.displayString = displayString
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
            if lower.contains("ogin incorrect") || lower.contains("ermission denied")
                || lower.contains("authentication fail") {
                finish(.failure(TelnetLaunchError.authenticationFailed))
                return
            }
            if text.contains(shellPromptNeedle) {
                cancelTimeout()
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
            }
        default:
            break
        }
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

    // MARK: - Completion

    private func finish(_ result: Result<Void, Error>) {
        guard completion != nil else { return }
        cancelTimeout()
        connection?.cancel()
        connection = nil
        let cb = completion
        completion = nil
        DispatchQueue.main.async { cb?(result) }
    }
}
