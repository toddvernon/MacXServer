import XCTest
@testable import SwiftXServerCore

final class LauncherFileTests: XCTestCase {

    func testPasswordParsedWhenPresent() {
        let file = LauncherFile.parse("""
        [xterm on u5]
        host = u5.example.com
        user = alice
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
        user = alice
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
        user = alice
        command = xterm

        [dtpad on u5]
        host = u5.example.com
        user = alice
        command = dtpad

        [xterm on ss2]
        host = ss2.example.com
        user = alice
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
        user = bob
        shell_prompt = myhost]
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
        XCTAssertEqual(file.entries[0].user, "bob")
        XCTAssertEqual(file.entries[0].shellPrompt, "myhost]")
        // The `verbose` keys above are legacy config the parser now ignores
        // (the progress window became a launch gesture 2026-07-08); entries
        // still parse fine around them.
    }

    // `password` inherits from the host block (dev-convenience field set on
    // the shared host block flows to every item under it, unless an item
    // overrides). Locking this in because a silent regression would force a
    // Keychain prompt on every launch.
    func testPasswordInheritsFromHostBlock() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice
        password = kemosabe

        [u5/xterm]
        command = xterm

        [u5/with-own-password]
        command = special
        password = override

        [host:ss2]
        host = ss2.example.com
        user = alice

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
        user = alice

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
        user = alice

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
        user = alice

        [u5/xterm]
        command = xterm

        [host:ss2]
        host = ss2.example.com
        user = alice

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

    // Default transport is telnet; explicit ssh is parsed; default port
    // shifts from 23 to 22 for ssh; explicit port wins over the default.
    func testTransportParsing() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice

        [u5/xterm]
        command = xterm

        [host:linux]
        host = linuxbox.local
        user = todd
        transport = ssh

        [linux/firefox]
        command = firefox

        [host:linux-alt]
        host = other.local
        user = todd
        transport = ssh
        port = 2222

        [linux-alt/xterm]
        command = xterm

        [host:sparc]
        host = 127.0.0.1
        user = root
        transport = helios

        [sparc/xterm]
        command = xterm
        """)
        let byKey = Dictionary(uniqueKeysWithValues: file.entries.map {
            ("\($0.group)/\($0.name)", $0)
        })
        XCTAssertEqual(byKey["u5/xterm"]?.transport, .telnet)
        XCTAssertEqual(byKey["u5/xterm"]?.port, 23)
        XCTAssertEqual(byKey["linux/firefox"]?.transport, .ssh)
        XCTAssertEqual(byKey["linux/firefox"]?.port, 22, "ssh default port is 22")
        XCTAssertEqual(byKey["linux-alt/xterm"]?.transport, .ssh)
        XCTAssertEqual(byKey["linux-alt/xterm"]?.port, 2222, "explicit port wins")
        XCTAssertEqual(byKey["sparc/xterm"]?.transport, .helios)
        XCTAssertEqual(byKey["sparc/xterm"]?.port, 2125, "helios default port is the daemon port")
    }

    // Mixing transport=ssh with a password set is a config mistake (ssh is
    // keys-only, so the password gets ignored). Surface a parse warning so
    // the loader can log it; entry still parses, password field passes through.
    func testSSHWithPasswordWarns() {
        let file = LauncherFile.parse("""
        [host:linux]
        host = linuxbox.local
        user = todd
        transport = ssh
        password = irrelevant

        [linux/xterm]
        command = xterm
        """)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertEqual(file.entries[0].transport, .ssh)
        XCTAssertEqual(file.entries[0].password, "irrelevant",
                       "password field still parses; warning is the only side effect")
        XCTAssertEqual(file.warnings.count, 1)
        XCTAssertTrue(file.warnings[0].contains("linux/xterm"))
        XCTAssertTrue(file.warnings[0].contains("transport=ssh"))

        // Telnet entry with a password is fine — no warning.
        let clean = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice
        password = ok

        [u5/xterm]
        command = xterm
        """)
        XCTAssertTrue(clean.warnings.isEmpty)
    }

    // filebrowser=true parses, defaults false, and warns (but still parses)
    // when set on a non-helios transport since the browser needs the daemon.
    func testFileBrowserFlag() {
        let file = LauncherFile.parse("""
        [host:sparc]
        host = 127.0.0.1
        user = tvernon
        transport = helios

        [sparc/xterm]
        command = xterm

        [sparc/Files]
        filebrowser = true
        """)
        let byKey = Dictionary(uniqueKeysWithValues: file.entries.map {
            ("\($0.group)/\($0.name)", $0)
        })
        XCTAssertEqual(byKey["sparc/Files"]?.fileBrowser, true, "filebrowser=true parses without a command")
        XCTAssertEqual(byKey["sparc/xterm"]?.fileBrowser, false, "defaults false when absent")
        XCTAssertTrue(file.warnings.isEmpty, "helios+filebrowser is the supported case, no warning")

        // filebrowser on a telnet launcher: still parses, but warns it's ignored.
        let nonHelios = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice

        [u5/Files]
        command = xterm
        filebrowser = true
        """)
        XCTAssertEqual(nonHelios.entries.first?.fileBrowser, true, "flag still parses")
        XCTAssertEqual(nonHelios.warnings.count, 1)
        XCTAssertTrue(nonHelios.warnings[0].contains("filebrowser"))
        XCTAssertTrue(nonHelios.warnings[0].contains("transport=helios"))
    }

    // An item can override its host-block's transport (rare, but the merge
    // table allows it for any field).
    func testTransportItemOverride() {
        let file = LauncherFile.parse("""
        [host:mixed]
        host = mixed.local
        user = alice
        transport = telnet

        [mixed/legacy]
        command = xterm

        [mixed/modern]
        command = firefox
        transport = ssh
        """)
        let byKey = Dictionary(uniqueKeysWithValues: file.entries.map {
            ("\($0.group)/\($0.name)", $0.transport)
        })
        XCTAssertEqual(byKey["mixed/legacy"], .telnet)
        XCTAssertEqual(byKey["mixed/modern"], .ssh)
    }

    // Mixing legacy entries with new host-block entries works -- both end up
    // in the same group when the host short-name matches the host-block key.
    func testLegacyAndHostBlockEntriesShareGroup() {
        let file = LauncherFile.parse("""
        [host:u5]
        host = u5.example.com
        user = alice

        [u5/xterm new]
        command = xterm

        [legacy entry]
        host = u5.example.com
        user = alice
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
