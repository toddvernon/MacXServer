import XCTest
@testable import SwiftXServerCore

final class TelnetLauncherTests: XCTestCase {

    // IAC SB TERMINAL-TYPE IS "xterm" IAC SE
    func testTerminalTypeSubnegotiationBytes() {
        let bytes = TelnetLauncher.terminalTypeSubnegotiation("xterm")
        XCTAssertEqual(bytes, [0xFF, 0xFA, 24, 0x00,
                               0x78, 0x74, 0x65, 0x72, 0x6D, // "xterm"
                               0xFF, 0xF0])
    }

    func testStripANSIRemovesCSI() {
        let input = "\u{1B}[1;32mhello\u{1B}[0m"
        XCTAssertEqual(TelnetLauncher.stripANSI(input), "hello")
    }

    func testStripANSIRemovesBELTerminatedOSC() {
        // ESC ] 2 ; <title> BEL  (window title set by the xterm-branch prompt)
        let input = "\u{1B}]2;~/work\u{07}prompt"
        XCTAssertEqual(TelnetLauncher.stripANSI(input), "prompt")
    }

    func testStripANSIRemovesSTTerminatedOSC() {
        // ESC ] 1 ; <icon> ESC \   (string terminator instead of BEL)
        let input = "\u{1B}]1;ss2\u{1B}\\done"
        XCTAssertEqual(TelnetLauncher.stripANSI(input), "done")
    }

    // Generic shell-prompt detection: the fallback when the configured needle
    // (the "$ " default -- sh/ksh-only) doesn't match. Genesis: the real
    // SS5's csh prompt "ipc% " timed out the launcher (2026-07-07); machine
    // launchers have no prompt keys, so the default must cover real shells.
    func testGenericShellPromptDetection() {
        // The four classic sigils, with and without trailing space.
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt("Last login: Tue Jul  7\nipc% "))
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt("motd line\n$ "))
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt("banner\nipc# "))
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt("banner\nhost>"))
        // The fleet's canonical csh prompt: bracket-wrapped, ends "] " -- the
        // shape that beat the sigil-only check on the real SS5 (2026-07-07).
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt(
            "SunOS Release 4.1.4 (GENERIC) #2\n[ipc:[tvernon]:/home2/tvernon] "))
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt(
            "SunOS Release 4.1.4\n[ss2.example.com:[bob]:/home/bob] %"))
        // CRLF streams -- what telnetd actually sends. Swift's "\r\n" is ONE
        // grapheme, so a Character split on "\n" never broke these lines and
        // the bracket check saw the banner as line one (the 2026-07-14 bug,
        // caught by the login probe's fake telnetd).
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt(
            "Last login: Tue Jul 14\r\n[ipc:[fred]:/home2/fred] "))
        XCTAssertTrue(TelnetLauncher.looksLikeShellPrompt(
            "SunOS Release 4.1.4\r\nbanner line\r\nipc% "))
        // Non-prompts: login/password prompts, empty, banner-only output.
        XCTAssertFalse(TelnetLauncher.looksLikeShellPrompt("login: "))
        XCTAssertFalse(TelnetLauncher.looksLikeShellPrompt("Password:"))
        XCTAssertFalse(TelnetLauncher.looksLikeShellPrompt(""))
        XCTAssertFalse(TelnetLauncher.looksLikeShellPrompt("Last login: Tue Jul  7 14:02:11"))
    }

    // The full prompt .cshrc emits once TERM=xterm: two OSC title pushes, a CR,
    // then the visible "[host:[user]:/cwd] ". The shell_prompt needle "bob]"
    // (matching "[bob]") must survive stripping.
    func testStripANSIPreservesPromptNeedle() {
        let prompt = "\u{1B}]2;/home/bob\u{07}" +
                     "\u{1B}]1;ss2.example.com\u{07}\r" +
                     "[ss2.example.com:[bob]:/home/bob] "
        let stripped = TelnetLauncher.stripANSI(prompt)
        XCTAssertTrue(stripped.contains("bob]"),
                      "prompt needle lost after stripping: \(stripped)")
        XCTAssertFalse(stripped.contains("\u{1B}"), "escape survived: \(stripped)")
    }
}
