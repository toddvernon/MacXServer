import XCTest
@testable import SwiftXServerCore

final class LauncherFileTests: XCTestCase {

    func testPasswordParsedWhenPresent() {
        let file = LauncherFile.parse("""
        [xterm on u5]
        host = u5.example.com
        user = todd
        command = xterm
        password = hunter2
        """)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertEqual(file.entries[0].password, "hunter2")
    }

    func testPasswordNilWhenOmitted() {
        let file = LauncherFile.parse("""
        [xcalc on ss2]
        host = ss2.example.com
        user = todd
        command = xcalc
        """)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertNil(file.entries[0].password, "no password → keychain fallback")
    }

    // Guards the flush() refactor: optional prompts still parse, and defaults
    // hold when omitted.
    func testOptionalPromptsParseAndDefault() {
        let file = LauncherFile.parse("""
        [a]
        host = h
        user = u
        command = c
        login_prompt = Login:
        shell_prompt = %
        [b]
        host = h2
        user = u2
        command = c2
        """)
        XCTAssertEqual(file.entries.count, 2)
        XCTAssertEqual(file.entries[0].loginPrompt, "Login:")
        XCTAssertEqual(file.entries[0].shellPrompt, "%")
        XCTAssertEqual(file.entries[0].passwordPrompt, "assword:")   // default
        XCTAssertEqual(file.entries[1].loginPrompt, "ogin:")          // default
        XCTAssertEqual(file.entries[1].passwordPrompt, "assword:")
        XCTAssertEqual(file.entries[1].shellPrompt, "$ ")
    }
}
