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

    // Legacy flat entries auto-group by the short form of `host`.
    func testLegacyEntriesGroupByHostShortName() {
        let file = LauncherFile.parse("""
        [xterm on u5]
        host = u5.example.com
        user = todd
        command = xterm

        [dtpad on u5]
        host = u5.example.com
        user = todd
        command = dtpad

        [xterm on ss2]
        host = ss2.example.com
        user = todd
        command = xterm
        """)
        XCTAssertEqual(file.entries.count, 3)
        XCTAssertEqual(file.entries[0].group, "u5")
        XCTAssertEqual(file.entries[1].group, "u5")
        XCTAssertEqual(file.entries[2].group, "ss2")

        let groups = file.groups()
        XCTAssertEqual(groups.map(\.label), ["u5", "ss2"])
        XCTAssertEqual(groups[0].entries.count, 2)
        XCTAssertEqual(groups[1].entries.count, 1)
    }

    // Host-block + items: defaults inherit, items override.
    func testHostBlockInheritance() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = tvernon
        shell_prompt = vernon]
        verbose = true

        [u5/xterm cyan]
        command = xterm -bg black -fg cyan

        [u5/xterm yellow]
        command = xterm -bg black -fg yellow

        [u5/dtpad]
        command = /usr/dt/bin/dtpad -standAlone
        verbose = false
        """)
        XCTAssertEqual(file.entries.count, 3)
        XCTAssertEqual(file.entries.map(\.name), ["xterm cyan", "xterm yellow", "dtpad"])
        XCTAssertEqual(file.entries.map(\.group), ["u5", "u5", "u5"])
        XCTAssertEqual(file.entries[0].host, "u5.example.com")
        XCTAssertEqual(file.entries[0].user, "tvernon")
        XCTAssertEqual(file.entries[0].shellPrompt, "vernon]")
        XCTAssertTrue(file.entries[0].verbose, "inherited verbose=true")
        XCTAssertTrue(file.entries[1].verbose, "inherited verbose=true")
        XCTAssertFalse(file.entries[2].verbose, "item override verbose=false")
    }

    // `password` inherits from the host block (dev-convenience field set on
    // the shared host block flows to every item under it, unless an item
    // overrides). Locking this in because a silent regression would force a
    // Keychain prompt on every launch.
    func testPasswordInheritsFromHostBlock() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = todd
        password = kemosabe

        [u5/xterm]
        command = xterm

        [u5/with-own-password]
        command = special
        password = override

        [host:ss2]
        host = ss2.example.com
        user = todd

        [ss2/xterm]
        command = xterm
        """)
        let byKey = Dictionary(uniqueKeysWithValues: file.entries.map {
            ("\($0.group)/\($0.name)", $0.password)
        })
        XCTAssertEqual(byKey["u5/xterm"], "kemosabe")
        XCTAssertEqual(byKey["u5/with-own-password"], "override")
        XCTAssertNil(byKey["ss2/xterm"] ?? nil, "no host-block password → Keychain fallback")
    }

    // Item that references an unknown host block is dropped.
    func testOrphanItemDropped() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = todd

        [u5/xterm]
        command = xterm

        [typo/xterm]
        command = xterm
        """)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertEqual(file.entries[0].name, "xterm")
        XCTAssertEqual(file.entries[0].group, "u5")
    }

    // Item missing `command` (no host-block default to fall back on) is dropped.
    func testItemMissingCommandDropped() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = todd

        [u5/no-command]
        # nothing here
        """)
        XCTAssertEqual(file.entries.count, 0)
    }

    // Multi-host two-stage menu rendering.
    func testGroupsAcrossMultipleHostBlocks() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = todd

        [u5/xterm]
        command = xterm

        [host:ss2]
        host = ss2.example.com
        user = todd

        [ss2/xterm]
        command = xterm

        [ss2/xcalc]
        command = xcalc
        """)
        let groups = file.groups()
        XCTAssertEqual(groups.map(\.label), ["u5", "ss2"])
        XCTAssertEqual(groups[0].entries.map(\.name), ["xterm"])
        XCTAssertEqual(groups[1].entries.map(\.name), ["xterm", "xcalc"])
    }

    // Mixing legacy entries with new host-block entries works -- both end up
    // in the same group when the host short-name matches the host-block key.
    func testLegacyAndHostBlockEntriesShareGroup() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = todd

        [u5/xterm new]
        command = xterm

        [legacy entry]
        host = u5.example.com
        user = todd
        command = oldthing
        """)
        XCTAssertEqual(file.entries.count, 2)
        XCTAssertEqual(file.entries[0].group, "u5")
        XCTAssertEqual(file.entries[1].group, "u5")
        let groups = file.groups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.map(\.name), ["xterm new", "legacy entry"])
    }
}
