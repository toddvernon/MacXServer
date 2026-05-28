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

    // The full prompt .cshrc emits once TERM=xterm: two OSC title pushes, a CR,
    // then the visible "[host:[user]:/cwd] ". The shell_prompt needle "vernon]"
    // (matching "[tvernon]") must survive stripping.
    func testStripANSIPreservesPromptNeedle() {
        let prompt = "\u{1B}]2;/home/tvernon\u{07}" +
                     "\u{1B}]1;ss2.example.com\u{07}\r" +
                     "[ss2.example.com:[tvernon]:/home/tvernon] "
        let stripped = TelnetLauncher.stripANSI(prompt)
        XCTAssertTrue(stripped.contains("vernon]"),
                      "prompt needle lost after stripping: \(stripped)")
        XCTAssertFalse(stripped.contains("\u{1B}"), "escape survived: \(stripped)")
    }
}
