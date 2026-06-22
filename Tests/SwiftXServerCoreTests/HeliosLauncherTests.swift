import XCTest
@testable import SwiftXServerCore

final class HeliosLauncherTests: XCTestCase {

    /// The /bin/sh command the daemon runs (as the target user via run_command's
    /// `user`): set the Solaris X PATH + DISPLAY, then nohup+background the
    /// client so it survives and run_command returns at once. The daemon runs it
    /// under /bin/sh, so the Bourne syntax is correct regardless of the user's
    /// login shell, and the client's own quotes survive a single shell parse.
    func testRemoteCommandShape() {
        let entry = LauncherEntry(
            name: "xterm", group: "sparc",
            host: "127.0.0.1",
            command: "xterm -fg \"#95efaf\" -fn 10x20",
            user: "tvernon",
            port: 2125,
            transport: .helios
        )
        let cmd = HeliosLauncher.remoteCommand(entry: entry, displayString: "10.0.2.2:0")
        XCTAssertEqual(cmd,
            "PATH=/usr/openwin/bin:/usr/dt/bin:/usr/bin/X11:$PATH; export PATH; " +
            "DISPLAY=10.0.2.2:0; export DISPLAY; " +
            "nohup xterm -fg \"#95efaf\" -fn 10x20 </dev/null >/dev/null 2>&1 &")
    }

    /// A nonzero exit from the launch command surfaces a descriptive error.
    func testNonzeroExitErrorMessage() {
        let error = HeliosLauncher.HeliosLauncherError.nonzeroExit(127)
        XCTAssertEqual(error.errorDescription, "the launch command exited with status 127")
    }
}
