import XCTest
import Network
@testable import SwiftXServerCore

// The login probe (TelnetLauncher probeOnly): connect, log in, see a shell,
// type exit -- and NEVER run a command. It's the proof mechanism behind the
// Overview's Change Login sheet (agent-less boxes), so the two invariants
// under test are (1) good credentials succeed without a command reaching the
// wire, (2) "Login incorrect" comes back as authenticationFailed.
//
// The peer is a scripted fake telnetd on a loopback NWListener: it plays a
// login/password/prompt transcript and records every byte the probe sends.
final class TelnetLoginProbeTests: XCTestCase {

    /// A one-connection scripted telnet server. Sends `banner` on connect,
    /// then walks `script`: each step waits for a line from the client and
    /// answers with the step's response. Everything received is appended to
    /// `received` (thread-safe via its own queue).
    private final class FakeTelnetd: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "fake-telnetd")
        private var connection: NWConnection?
        private var script: [(expect: String, respond: String)]
        private var pending = ""
        private var receivedBytes = Data()
        private(set) var port: UInt16 = 0

        init(banner: String, script: [(expect: String, respond: String)]) throws {
            self.script = script
            listener = try NWListener(using: .tcp, on: .any)
            // All stored properties are set; self may be captured now.
            let started = expectationHolder()
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.connection = conn
                conn.start(queue: self.queue)
                self.send(banner, on: conn)
                self.receiveLoop(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state { started.fulfill() }
            }
            listener.start(queue: queue)
            started.wait(timeout: 5)
            guard let p = listener.port?.rawValue else {
                throw NSError(domain: "FakeTelnetd", code: 1)
            }
            port = p
        }
        // (port stays 0 only if the guard above throws.)

        func stop() {
            queue.sync {
                connection?.cancel()
                listener.cancel()
            }
        }

        /// Everything the client sent, as one string (telnet IAC bytes and all).
        var received: String {
            queue.sync { String(data: receivedBytes, encoding: .utf8) ?? "" }
        }

        private func send(_ text: String, on conn: NWConnection) {
            conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        private func receiveLoop(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receivedBytes.append(data)
                    // Telnet IAC negotiation bytes (0xFF ...) never appear in
                    // the line the script matches on; strip anything >= 0xF0
                    // plus the option byte noise by keeping printable ASCII.
                    let printable = data.filter { $0 == 0x0A || $0 == 0x0D || (0x20...0x7E).contains($0) }
                    self.pending += String(data: printable, encoding: .utf8) ?? ""
                    self.playScript(conn)
                }
                if isComplete || error != nil { return }
                self.receiveLoop(conn)
            }
        }

        private func playScript(_ conn: NWConnection) {
            while let step = script.first, pending.contains(step.expect) {
                pending = ""
                script.removeFirst()
                send(step.respond, on: conn)
            }
        }
    }

    /// XCTestExpectation needs a test instance; the listener-start wait
    /// happens in FakeTelnetd's init, so use a bare semaphore holder.
    private final class expectationHolder: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        func fulfill() { sem.signal() }
        func wait(timeout: TimeInterval) {
            _ = sem.wait(timeout: .now() + timeout)
        }
    }

    func testProbeSucceedsAndSendsNoCommand() throws {
        let server = try FakeTelnetd(
            banner: "SunOS UNIX (ipc)\r\n\r\nlogin: ",
            script: [
                (expect: "fred", respond: "Password:"),
                (expect: "kemosabe", respond: "Last login: Tue Jul 14\r\n[ipc:[fred]:/home2/fred] "),
            ])
        defer { server.stop() }

        let probe = TelnetLauncher.loginProbe(host: "127.0.0.1", port: server.port,
                                              user: "fred", password: "kemosabe")
        let done = XCTestExpectation(description: "probe completes")
        var outcome: Result<Void, Error>?
        probe.launch { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        guard case .success = outcome else {
            return XCTFail("probe failed: \(String(describing: outcome))")
        }
        // The probe's whole contract: nothing ran on the box. The launch
        // path would have sent "/bin/sh -c 'DISPLAY=..." and "nohup".
        let sent = server.received
        XCTAssertFalse(sent.contains("/bin/sh"), "probe sent a command: \(sent)")
        XCTAssertFalse(sent.contains("nohup"), "probe sent a command: \(sent)")
        XCTAssertTrue(sent.contains("exit"), "probe never logged out: \(sent)")
        // Recognized outright -- no suspected prompt to hand back (launches
        // will recognize it the same way; no needle needed).
        XCTAssertNil(probe.suspectedShellPrompt)
    }

    func testProbeWrongPasswordIsAuthenticationFailed() throws {
        let server = try FakeTelnetd(
            banner: "SunOS UNIX (ipc)\r\n\r\nlogin: ",
            script: [
                (expect: "fred", respond: "Password:"),
                (expect: "wrongpw", respond: "Login incorrect\r\nlogin: "),
            ])
        defer { server.stop() }

        let probe = TelnetLauncher.loginProbe(host: "127.0.0.1", port: server.port,
                                              user: "fred", password: "wrongpw")
        let done = XCTestExpectation(description: "probe completes")
        var outcome: Result<Void, Error>?
        probe.launch { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        guard case .failure(let error) = outcome else {
            return XCTFail("probe should have failed: \(String(describing: outcome))")
        }
        guard case TelnetLaunchError.authenticationFailed = error else {
            return XCTFail("expected authenticationFailed, got \(error)")
        }
    }

    func testProbeUnrecognizedPromptStillSucceeds() throws {
        // The less-aggressive probe (2026-07-16): a shell prompt shaped like
        // nothing we know must NOT read as a failed login. Todd's field test:
        // a real 4.1.4 box with a custom prompt beat both the "$ " needle and
        // the generic sigil detection, and the probe called a correct
        // password a failure. Success = the password went in, output arrived,
        // no rejection, line went quiet.
        let server = try FakeTelnetd(
            banner: "SunOS UNIX (ipc)\r\n\r\nlogin: ",
            script: [
                (expect: "fred", respond: "Password:"),
                (expect: "kemosabe",
                 respond: "Last login: Tue Jul 14\r\nYou have mail.\r\nipc*"),
            ])
        defer { server.stop() }

        let probe = TelnetLauncher.loginProbe(host: "127.0.0.1", port: server.port,
                                              user: "fred", password: "kemosabe")
        let done = XCTestExpectation(description: "probe completes")
        var outcome: Result<Void, Error>?
        probe.launch { result in
            outcome = result
            done.fulfill()
        }
        // Settle window (2.5s) + exit grace (0.5s) + slack.
        wait(for: [done], timeout: 10)

        guard case .success = outcome else {
            return XCTFail("unrecognized prompt must not fail the probe: "
                           + "\(String(describing: outcome))")
        }
        let sent = server.received
        XCTAssertFalse(sent.contains("/bin/sh"), "probe sent a command: \(sent)")
        XCTAssertTrue(sent.contains("exit"), "probe never logged out: \(sent)")
        // The settle path's souvenir: the last quiet line is the suspected
        // shell prompt, offered to the wizard for user validation.
        XCTAssertEqual(probe.suspectedShellPrompt, "ipc*")
    }

    func testProbeSilentRepromptIsAuthenticationFailed() throws {
        // A telnetd that re-presents "login:" after the password without any
        // message: the language-independent rejection. (The whole fleet also
        // prints "Login incorrect"; this covers a box that doesn't.)
        let server = try FakeTelnetd(
            banner: "login: ",
            script: [
                (expect: "fred", respond: "Password:"),
                (expect: "wrongpw", respond: "\r\nlogin: "),
            ])
        defer { server.stop() }

        let probe = TelnetLauncher.loginProbe(host: "127.0.0.1", port: server.port,
                                              user: "fred", password: "wrongpw")
        let done = XCTestExpectation(description: "probe completes")
        var outcome: Result<Void, Error>?
        probe.launch { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        guard case .failure(let error) = outcome else {
            return XCTFail("silent re-prompt should fail: \(String(describing: outcome))")
        }
        guard case TelnetLaunchError.authenticationFailed = error else {
            return XCTFail("expected authenticationFailed, got \(error)")
        }
    }

    func testLoginRepromptDetectorShapes() {
        // The default needle is "ogin:" (matches login:/Login:). Suffix rule
        // with the one carve-out: "Last login:" -- a motd line, or a receive
        // chunk cut off exactly at those words -- is the SUCCESS banner and
        // must never read as a rejection.
        XCTAssertTrue(TelnetLauncher.looksLikeLoginReprompt("\r\nlogin: ",
                                                            loginPrompt: "ogin:"))
        XCTAssertTrue(TelnetLauncher.looksLikeLoginReprompt("Login incorrect\r\nLogin:",
                                                            loginPrompt: "ogin:"))
        XCTAssertTrue(TelnetLauncher.looksLikeLoginReprompt("\r\nipc login: ",
                                                            loginPrompt: "ogin:"))
        XCTAssertFalse(TelnetLauncher.looksLikeLoginReprompt("Last login:",
                                                             loginPrompt: "ogin:"))
        XCTAssertFalse(TelnetLauncher.looksLikeLoginReprompt("Last Login:",
                                                             loginPrompt: "ogin:"))
        XCTAssertFalse(TelnetLauncher.looksLikeLoginReprompt(
            "Last login: Tue Jul 14 on ttyp0\r\n[ipc:[fred]:/home2/fred] ",
            loginPrompt: "ogin:"))
        XCTAssertFalse(TelnetLauncher.looksLikeLoginReprompt("", loginPrompt: "ogin:"))
    }

    func testProbeRefusedConnectionFails() throws {
        // A port nothing listens on: the probe must fail (connection error or
        // login timeout), never hang past its own state timeouts, and never
        // succeed. Genesis: this is the "box is fully down" path of the
        // Change Login sheet.
        let probe = TelnetLauncher.loginProbe(host: "127.0.0.1", port: 1,
                                              user: "fred", password: "pw")
        let done = XCTestExpectation(description: "probe completes")
        var outcome: Result<Void, Error>?
        probe.launch { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        guard case .failure = outcome else {
            return XCTFail("probe against a dead port must fail, got \(String(describing: outcome))")
        }
    }
}
