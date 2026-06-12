import XCTest
@testable import SwiftXServerCore

final class SSHLauncherTests: XCTestCase {

    /// Pin the exact argv. The shape matters: BatchMode keeps ssh from
    /// hanging on a password prompt, accept-new is the friendly-first-launch
    /// host-key policy, the remote command must set DISPLAY + nohup so the
    /// X app survives the session close, and the whole inner command must
    /// be /bin/sh -c-wrapped so the syntax is Bourne even when the remote
    /// login shell is csh/tcsh.
    func testBuildArgumentsShape() {
        let entry = LauncherEntry(
            name: "firefox", group: "linux",
            host: "linuxbox.local",
            command: "firefox",
            user: "todd",
            port: 22,
            transport: .ssh
        )
        let args = SSHLauncher.buildArguments(entry: entry, displayString: "mac.local:0")
        XCTAssertEqual(args, [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            "-p", "22",
            "todd@linuxbox.local",
            "/bin/sh -c 'DISPLAY=mac.local:0; export DISPLAY; " +
                "nohup firefox </dev/null >/dev/null 2>&1 &'"
        ])
    }

    /// Non-default port is honored.
    func testBuildArgumentsCustomPort() {
        let entry = LauncherEntry(
            name: "xterm", group: "linux",
            host: "h", command: "xterm", user: "u",
            port: 2222,
            transport: .ssh
        )
        let args = SSHLauncher.buildArguments(entry: entry, displayString: "d:0")
        XCTAssertTrue(args.contains("2222"))
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
    }

    func testAuthFailureDetection() {
        XCTAssertTrue(SSHLauncher.stderrLooksLikeAuthFailure(
            "todd@linuxbox.local: Permission denied (publickey).\n"))
        XCTAssertTrue(SSHLauncher.stderrLooksLikeAuthFailure(
            "Host key verification failed.\n"))
        XCTAssertFalse(SSHLauncher.stderrLooksLikeAuthFailure(
            "Could not resolve hostname linuxbox.local\n"))
    }
}
