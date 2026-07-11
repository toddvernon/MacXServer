import XCTest
@testable import SwiftXServerCore

/// A scripted guest: files live in a dictionary (writes update it, so the
/// pipeline's read-back verification exercises the real flow), commands are
/// logged and succeed unless told otherwise. The ordered `log` is what the
/// pipeline tests pin -- the commit ordering IS the design.
private final class MockGuest: UserAdminTransport {
    var files: [String: String]
    /// Ordered operations: "read <path>", "run <cmd>", "write <path>".
    var log: [String] = []
    /// Commands containing this substring exit nonzero.
    var failCommandsContaining: String?

    init(files: [String: String]) { self.files = files }

    func readFile(_ path: String, user: String?) throws -> FileContent {
        log.append("read \(path)")
        guard let content = files[path] else {
            throw HeliosClient.HeliosError.protocolError("no such file: \(path)")
        }
        return FileContent(data: Data(content.utf8), path: path,
                           size: content.utf8.count, mode: 0o644)
    }

    func writeFile(_ path: String, data: Data, mode: Int?, user: String?) throws -> WriteResult {
        log.append("write \(path)")
        files[path] = String(decoding: data, as: UTF8.self)
        return WriteResult(path: path, bytesWritten: data.count,
                           mode: 0o644, created: false)
    }

    func runCommand(_ cmd: String, cwd: String?, timeoutMs: Int?, user: String?) throws -> RunResult {
        log.append("run \(cmd)")
        if let needle = failCommandsContaining, cmd.contains(needle) {
            return RunResult(exitCode: 1, output: "mock failure", timedOut: false)
        }
        return RunResult(exitCode: 0, output: "", timedOut: false)
    }
}

final class UserAdminTests: XCTestCase {

    // MARK: Guest fixtures (the convergence account scheme)

    private func solarisGuest() -> MockGuest {
        MockGuest(files: [
            "/etc/passwd": """
                root:x:0:1:Super-User:/:/bin/sh
                daemon:x:1:1::/:
                tvernon:x:1000:100:Todd Vernon:/home/tvernon:/usr/local/bin/tcsh
                template:x:1999:100:Template:/home/template:/usr/local/bin/tcsh

                """,
            "/etc/shadow": """
                root:aaAAaaAAaaAAa:10000::::::
                daemon:NP:6445::::::
                tvernon:bbBBbbBBbbBBb:10000::::::
                template:*LK*:10000::::::

                """,
        ])
    }

    private func sunosGuest() -> MockGuest {
        MockGuest(files: [
            "/etc/passwd": """
                root:ccCCccCCccCCc:0:0:Operator:/:/bin/sh
                tvernon:ddDDddDDddDDd:1000:100:Todd Vernon:/home/tvernon:/usr/local/bin/tcsh
                template:*:1999:100:Template:/home/template:/usr/local/bin/tcsh

                """,
        ])
    }

    private func netbsdGuest() -> MockGuest {
        MockGuest(files: [
            "/etc/master.passwd": """
                root:eeEEeeEEeeEEe:0:0::0:0:Charlie &:/root:/bin/sh
                tvernon:ffFFffFFffFFf:1000:100::0:0:Todd Vernon:/home/tvernon:/usr/local/bin/tcsh
                template:*:1999:100::0:0:Template:/home/template:/usr/local/bin/tcsh

                """,
            "/etc/passwd": """
                root:*:0:0:Charlie &:/root:/bin/sh
                tvernon:*:1000:100:Todd Vernon:/home/tvernon:/usr/local/bin/tcsh
                template:*:1999:100:Template:/home/template:/usr/local/bin/tcsh

                """,
        ])
    }

    // MARK: Username + password + uid

    func testUsernameRules() {
        XCTAssertNil(UserAdmin.usernameProblem("todd"))
        XCTAssertNil(UserAdmin.usernameProblem("a1"))
        XCTAssertNil(UserAdmin.usernameProblem("abcdefgh"))     // exactly 8
        XCTAssertNotNil(UserAdmin.usernameProblem(""))
        XCTAssertNotNil(UserAdmin.usernameProblem("abcdefghi")) // 9
        XCTAssertNotNil(UserAdmin.usernameProblem("Todd"))      // uppercase
        XCTAssertNotNil(UserAdmin.usernameProblem("1todd"))     // digit first
        XCTAssertNotNil(UserAdmin.usernameProblem("to dd"))     // space
        XCTAssertNotNil(UserAdmin.usernameProblem("to:dd"))     // field separator
    }

    func testDesHashKnownVector() {
        // Pinned against crypt(3) on this platform (verified by hand
        // 2026-07-10) -- and DES ignores everything past 8 characters.
        XCTAssertEqual(UserAdmin.desHash(password: "testpass", salt: "ab"),
                       "abA5hjwYqm1.I")
        XCTAssertEqual(UserAdmin.desHash(password: "12345678", salt: "Zz"),
                       UserAdmin.desHash(password: "123456789overflow", salt: "Zz"))
    }

    func testDesHashRandomSaltShape() {
        let h = UserAdmin.desHash(password: "whatever")
        XCTAssertEqual(h.count, 13)   // 2-char salt + 11-char DES output
    }

    func testNextFreeUID() {
        XCTAssertEqual(UserAdmin.nextFreeUID(existing: [0, 1, 1000, 1999]), 1001)
        XCTAssertEqual(UserAdmin.nextFreeUID(existing: [1000, 1001, 1002, 1999]), 1003)
        XCTAssertEqual(UserAdmin.nextFreeUID(existing: []), 1001)
        // 1999 (template) is just another taken uid; allocation walks past it.
        XCTAssertEqual(UserAdmin.nextFreeUID(existing: Array(1001...1999)), 2000)
    }

    // MARK: Per-OS geometry

    func testPerOSGeometry() {
        XCTAssertEqual(UserAdmin.homePhysicalPath(os: .solaris26, name: "u"),
                       "/export/home/u")
        XCTAssertEqual(UserAdmin.homePhysicalPath(os: .sunos414, name: "u"), "/home/u")
        XCTAssertEqual(UserAdmin.homePhysicalPath(os: .netbsd, name: "u"), "/home/u")

        XCTAssertEqual(UserAdmin.recordFiles(os: .solaris26),
                       ["/etc/shadow", "/etc/passwd"])   // login-enabling last
        XCTAssertEqual(UserAdmin.recordFiles(os: .sunos414), ["/etc/passwd"])
        XCTAssertEqual(UserAdmin.recordFiles(os: .netbsd), ["/etc/master.passwd"])

        XCTAssertNil(UserAdmin.activationCommand(os: .solaris26))
        XCTAssertNil(UserAdmin.activationCommand(os: .sunos414))
        XCTAssertEqual(UserAdmin.activationCommand(os: .netbsd),
                       "/usr/sbin/pwd_mkdb -p /etc/master.passwd")
    }

    func testRecordLines() {
        // Solaris: x in passwd, hash in shadow with lastchg.
        XCTAssertEqual(
            UserAdmin.recordLine(os: .solaris26, file: "/etc/passwd", name: "hb",
                                 uid: 1001, gecos: "Homer B", hash: "abXYZ",
                                 lastChangedDays: 20614),
            "hb:x:1001:100:Homer B:/home/hb:/usr/local/bin/tcsh")
        XCTAssertEqual(
            UserAdmin.recordLine(os: .solaris26, file: "/etc/shadow", name: "hb",
                                 uid: 1001, gecos: "Homer B", hash: "abXYZ",
                                 lastChangedDays: 20614),
            "hb:abXYZ:20614::::::")
        // 4.1.4: hash inline in passwd.
        XCTAssertEqual(
            UserAdmin.recordLine(os: .sunos414, file: "/etc/passwd", name: "hb",
                                 uid: 1001, gecos: "Homer B", hash: "abXYZ",
                                 lastChangedDays: 20614),
            "hb:abXYZ:1001:100:Homer B:/home/hb:/usr/local/bin/tcsh")
        // NetBSD: 10-field master.passwd line.
        XCTAssertEqual(
            UserAdmin.recordLine(os: .netbsd, file: "/etc/master.passwd", name: "hb",
                                 uid: 1001, gecos: "Homer B", hash: "abXYZ",
                                 lastChangedDays: 20614),
            "hb:abXYZ:1001:100::0:0:Homer B:/home/hb:/usr/local/bin/tcsh")
    }

    func testAppendAndRemoveRecord() {
        let base = "root:x:0:1::/:/bin/sh\ntodd:x:1000:100::/home/todd:/bin/csh\n"
        let grown = UserAdmin.appendingRecord(base, line: "new:x:1001:100::/home/new:/bin/csh")
        XCTAssertTrue(grown.hasSuffix("new:x:1001:100::/home/new:/bin/csh\n"))
        // Append onto a file missing its trailing newline doesn't glue lines.
        let glued = UserAdmin.appendingRecord("a:x:1:1::/:/bin/sh", line: "b:x:2:1::/:/bin/sh")
        XCTAssertEqual(glued, "a:x:1:1::/:/bin/sh\nb:x:2:1::/:/bin/sh\n")

        XCTAssertEqual(UserAdmin.removingRecord(grown, name: "new"), base)
        XCTAssertNil(UserAdmin.removingRecord(base, name: "absent"))
        // Prefix discipline: removing "to" must not take "todd" with it.
        XCTAssertNil(UserAdmin.removingRecord(base, name: "to"))
    }

    func testParsePasswd() {
        let entries = UserAdmin.parsePasswd(
            "root:x:0:1:Super:/:/bin/sh\nnot a passwd line\ntodd:x:1000:100::/home/todd:/bin/csh\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1],
                       PasswdEntry(name: "todd", passwordField: "x", uid: 1000,
                                   gid: 100, gecos: "", home: "/home/todd",
                                   shell: "/bin/csh"))
        XCTAssertEqual(entries[1].line, "todd:x:1000:100::/home/todd:/bin/csh")
    }

    // MARK: Add pipeline

    func testAddUserSolarisOrderingAndContent() throws {
        let guest = solarisGuest()
        let uid = try UserAdmin.addUser(
            .init(name: "homer", gecos: "Homer B", hash: "abHASH"),
            os: .solaris26, transport: guest, lastChangedDays: 20614)

        XCTAssertEqual(uid, 1001)
        // The design's ordering: reads, then home staging, then shadow BEFORE
        // passwd (login-enabling file last), then verify.
        XCTAssertEqual(guest.log, [
            "read /etc/passwd",
            "read /etc/shadow",
            "run cp -r /home/template /export/home/homer",
            "run chown -R 1001 /export/home/homer",
            "run chgrp -R 100 /export/home/homer",
            "run chmod 755 /export/home/homer",
            "write /etc/shadow",
            "write /etc/passwd",
            "read /etc/passwd",
            "run ls -ld /export/home/homer",
        ])
        XCTAssertTrue(guest.files["/etc/passwd"]!
            .contains("homer:x:1001:100:Homer B:/home/homer:/usr/local/bin/tcsh\n"))
        XCTAssertTrue(guest.files["/etc/shadow"]!
            .contains("homer:abHASH:20614::::::\n"))
    }

    func testAddUserSunOSHashInPasswd() throws {
        let guest = sunosGuest()
        let uid = try UserAdmin.addUser(
            .init(name: "homer", hash: "abHASH"),
            os: .sunos414, transport: guest, lastChangedDays: 20614)
        XCTAssertEqual(uid, 1001)
        XCTAssertTrue(guest.files["/etc/passwd"]!
            .contains("homer:abHASH:1001:100::/home/homer:/usr/local/bin/tcsh\n"))
        XCTAssertFalse(guest.log.contains { $0.hasPrefix("write /etc/shadow") })
    }

    func testAddUserNetBSDRunsPwdMkdb() throws {
        let guest = netbsdGuest()
        _ = try UserAdmin.addUser(
            .init(name: "homer", hash: "abHASH"),
            os: .netbsd, transport: guest, lastChangedDays: 20614)
        XCTAssertTrue(guest.files["/etc/master.passwd"]!
            .contains("homer:abHASH:1001:100::0:0::/home/homer:/usr/local/bin/tcsh\n"))
        // pwd_mkdb runs AFTER the master.passwd write.
        let writeIdx = guest.log.firstIndex(of: "write /etc/master.passwd")!
        let mkdbIdx = guest.log.firstIndex(of: "run /usr/sbin/pwd_mkdb -p /etc/master.passwd")!
        XCTAssertLessThan(writeIdx, mkdbIdx)
    }

    func testAddUserRefusesDuplicate() {
        let guest = solarisGuest()
        XCTAssertThrowsError(try UserAdmin.addUser(
            .init(name: "tvernon", hash: "x"),
            os: .solaris26, transport: guest)) { error in
            XCTAssertEqual(error as? UserAdminError, .userExists("tvernon"))
        }
        // Nothing was staged or written.
        XCTAssertFalse(guest.log.contains { $0.hasPrefix("run") || $0.hasPrefix("write") })
    }

    func testAddUserRefusesBadName() {
        let guest = solarisGuest()
        XCTAssertThrowsError(try UserAdmin.addUser(
            .init(name: "Homer", hash: "x"), os: .solaris26, transport: guest))
        XCTAssertTrue(guest.log.isEmpty)   // refused before any wire traffic
    }

    func testAddUserHomeFailureLeavesRecordsUntouched() {
        let guest = solarisGuest()
        guest.failCommandsContaining = "cp -r"
        let before = guest.files
        XCTAssertThrowsError(try UserAdmin.addUser(
            .init(name: "homer", hash: "x"), os: .solaris26, transport: guest)) { error in
            guard case .commandFailed(let cmd, 1, _)? = error as? UserAdminError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(cmd.hasPrefix("cp -r"))
        }
        // The commit point was never reached: no record file changed.
        XCTAssertEqual(guest.files, before)
    }

    func testAddUserGecosSanitized() throws {
        let guest = sunosGuest()
        _ = try UserAdmin.addUser(
            .init(name: "homer", gecos: "Homer: B\nJr", hash: "h"),
            os: .sunos414, transport: guest)
        // Colons and newlines can't survive into a colon-separated record.
        XCTAssertTrue(guest.files["/etc/passwd"]!.contains(":Homer  B Jr:"))
    }

    // MARK: Delete pipeline

    func testDeleteUserSolarisReverseOrderAndHomeRemoval() throws {
        let guest = solarisGuest()
        _ = try UserAdmin.addUser(.init(name: "homer", hash: "h"),
                                  os: .solaris26, transport: guest)
        guest.log.removeAll()

        try UserAdmin.deleteUser(name: "homer", os: .solaris26,
                                 removeHome: true, transport: guest)
        // Reverse commit order: passwd (login-disabling) before shadow.
        XCTAssertEqual(guest.log, [
            "read /etc/passwd",
            "read /etc/passwd",
            "write /etc/passwd",
            "read /etc/shadow",
            "write /etc/shadow",
            "run rm -rf /export/home/homer",
        ])
        XCTAssertFalse(guest.files["/etc/passwd"]!.contains("homer:"))
        XCTAssertFalse(guest.files["/etc/shadow"]!.contains("homer:"))
    }

    func testDeleteUserKeepsHomeByDefaultFlag() throws {
        let guest = sunosGuest()
        _ = try UserAdmin.addUser(.init(name: "homer", hash: "h"),
                                  os: .sunos414, transport: guest)
        guest.log.removeAll()
        try UserAdmin.deleteUser(name: "homer", os: .sunos414,
                                 removeHome: false, transport: guest)
        XCTAssertFalse(guest.log.contains { $0.hasPrefix("run rm -rf") })
    }

    func testDeleteUserNetBSDRebuildsDatabase() throws {
        let guest = netbsdGuest()
        _ = try UserAdmin.addUser(.init(name: "homer", hash: "h"),
                                  os: .netbsd, transport: guest)
        // Keep the generated /etc/passwd listing in step for the delete read.
        try UserAdmin.deleteUser(name: "homer", os: .netbsd,
                                 removeHome: false, transport: guest)
        XCTAssertFalse(guest.files["/etc/master.passwd"]!.contains("homer:"))
        XCTAssertTrue(guest.log.filter { $0 == "run /usr/sbin/pwd_mkdb -p /etc/master.passwd" }
            .count >= 2)   // once for add, once for delete
    }

    func testDeleteRefusals() throws {
        let guest = solarisGuest()
        for name in ["root", "template", "daemon"] {
            XCTAssertThrowsError(try UserAdmin.deleteUser(
                name: name, os: .solaris26, removeHome: false, transport: guest),
                "expected refusal for \(name)")
        }
        XCTAssertThrowsError(try UserAdmin.deleteUser(
            name: "nobody9", os: .solaris26, removeHome: false, transport: guest)) { e in
            XCTAssertEqual(e as? UserAdminError, .userNotFound("nobody9"))
        }
        // The refusals never wrote anything.
        XCTAssertFalse(guest.log.contains { $0.hasPrefix("write") })
    }

    func testDeleteSkipsRmForNonStandardHome() throws {
        let guest = solarisGuest()
        // A hand-edited record whose home points somewhere weird.
        guest.files["/etc/passwd"]! +=
            "odd:x:1005:100:Odd:/var/tmp/oddball:/bin/csh\n"
        guest.files["/etc/shadow"]! += "odd:h:20000::::::\n"
        try UserAdmin.deleteUser(name: "odd", os: .solaris26,
                                 removeHome: true, transport: guest)
        // The record went away, but no rm -rf was risked.
        XCTAssertFalse(guest.files["/etc/passwd"]!.contains("odd:"))
        XCTAssertFalse(guest.log.contains { $0.hasPrefix("run rm -rf") })
    }

    // MARK: Listing

    func testListUsers() throws {
        let guest = solarisGuest()
        let users = try UserAdmin.listUsers(transport: guest)
        XCTAssertEqual(users.map(\.name), ["root", "daemon", "tvernon", "template"])
    }

    // MARK: Password verification

    func testHashFilePerOS() {
        XCTAssertEqual(UserAdmin.hashFile(os: .solaris26), "/etc/shadow")
        XCTAssertEqual(UserAdmin.hashFile(os: .sunos414), "/etc/passwd")
        XCTAssertEqual(UserAdmin.hashFile(os: .netbsd), "/etc/master.passwd")
    }

    func testStoredHashExtraction() {
        let shadow = "root:aaAAaaAAaaAAa:10000::::::\ntodd:bbBBbbBBbbBBb:10000::::::\n"
        XCTAssertEqual(UserAdmin.storedHash(in: shadow, name: "todd"),
                       "bbBBbbBBbbBBb")
        XCTAssertNil(UserAdmin.storedHash(in: shadow, name: "ghost"))
        // Prefix discipline: "to" must not read todd's hash.
        XCTAssertNil(UserAdmin.storedHash(in: shadow, name: "to"))
    }

    func testPasswordMatches() {
        // Against the pinned crypt(3) vector from testDesHashKnownVector.
        let hash = "abA5hjwYqm1.I"
        XCTAssertTrue(UserAdmin.passwordMatches("testpass", storedHash: hash))
        XCTAssertFalse(UserAdmin.passwordMatches("wrongpwd", storedHash: hash))
        // DES reads only the first 8 chars; a matching prefix still passes.
        XCTAssertTrue(UserAdmin.passwordMatches("testpassEXTRA", storedHash: hash))
        // Locked / passwordless / placeholder fields never match anything.
        for locked in ["*", "*LK*", "NP", "x", "", "*************"] {
            XCTAssertFalse(UserAdmin.passwordMatches("anything", storedHash: locked),
                           "\u{201C}\(locked)\u{201D} must never verify")
        }
    }

    func testVerifyPasswordPerOS() throws {
        let hash = UserAdmin.desHash(password: "secret1", salt: "ab")
        for (os, guest) in [(MachineOS.solaris26, solarisGuest()),
                            (.sunos414, sunosGuest()),
                            (.netbsd, netbsdGuest())] {
            _ = try UserAdmin.addUser(.init(name: "homer", hash: hash),
                                      os: os, transport: guest)
            guest.log.removeAll()
            XCTAssertTrue(try UserAdmin.verifyPassword(
                name: "homer", password: "secret1", os: os, transport: guest),
                "right password must verify on \(os)")
            XCTAssertFalse(try UserAdmin.verifyPassword(
                name: "homer", password: "nope", os: os, transport: guest),
                "wrong password must fail on \(os)")
            // It read the hash-bearing file and nothing else went on the wire.
            XCTAssertEqual(guest.log,
                           ["read \(UserAdmin.hashFile(os: os))",
                            "read \(UserAdmin.hashFile(os: os))"])
        }
    }

    func testVerifyPasswordUnknownUser() {
        let guest = solarisGuest()
        XCTAssertThrowsError(try UserAdmin.verifyPassword(
            name: "ghost", password: "x", os: .solaris26, transport: guest)) { e in
            XCTAssertEqual(e as? UserAdminError, .userNotFound("ghost"))
        }
    }

    func testSha1CryptAgainstGuestVectors() {
        // Minted on the live NetBSD 9.2 guest with pwhash(1) 2026-07-11 --
        // the guest's own libcrypt is the authority the port must match.
        let vectors = [
            ("xyzzy123", "$sha1$23235$dCNNxjl9$9vRbYJ5ySxceoVjBqnx71Xe/RuxW"),
            ("xyzzy123", "$sha1$4$t5BocVPb$jfqT2NwfPL44ktdsCYuDN4z0zVFW"),
            ("swordfish", "$sha1$96$o/1bTzb7$tJBWQsFChUZ5.9WEoXmm9bDM6qap"),
        ]
        for (password, hash) in vectors {
            XCTAssertEqual(UserAdmin.sha1Crypt(password: password, saltSpec: hash),
                           hash)
            XCTAssertTrue(UserAdmin.passwordMatches(password, storedHash: hash))
            XCTAssertFalse(UserAdmin.passwordMatches("wrong", storedHash: hash))
        }
        // Unparseable specs return nil rather than a bogus hash.
        XCTAssertNil(UserAdmin.sha1Crypt(password: "x", saltSpec: "$sha1$$salt$"))
        XCTAssertNil(UserAdmin.sha1Crypt(password: "x", saltSpec: "$sha1$0$salt$"))
        XCTAssertNil(UserAdmin.sha1Crypt(password: "x", saltSpec: "$1$ab$junk"))
        XCTAssertNil(UserAdmin.sha1Crypt(password: "", saltSpec: vectors[0].1))
    }

    func testVerifyPasswordSha1CryptAccount() throws {
        // A pre-UserAdmin NetBSD account (installer-era sha1crypt hash) must
        // verify -- the exact case the 2026-07-11 Set Active bug hit.
        let guest = netbsdGuest()
        guest.files["/etc/master.passwd"]! += "olduser:$sha1$4$t5BocVPb$"
            + "jfqT2NwfPL44ktdsCYuDN4z0zVFW:1000:100::0:0:Old:/home/olduser:/bin/sh\n"
        XCTAssertTrue(try UserAdmin.verifyPassword(
            name: "olduser", password: "xyzzy123", os: .netbsd, transport: guest))
        XCTAssertFalse(try UserAdmin.verifyPassword(
            name: "olduser", password: "nope", os: .netbsd, transport: guest))
    }

    func testVerifyPasswordUnsupportedFormatThrows() {
        // An honest error beats a false "wrong password" for formats we
        // don't speak (MD5 $1$, Blowfish $2a$).
        let guest = netbsdGuest()
        guest.files["/etc/master.passwd"]! += "md5user:$1$ab$0123456789abcdef"
            + ":1001:100::0:0:M:/home/md5user:/bin/sh\n"
        XCTAssertThrowsError(try UserAdmin.verifyPassword(
            name: "md5user", password: "x", os: .netbsd, transport: guest)) { e in
            XCTAssertEqual(e as? UserAdminError, .unsupportedHash("$1$"))
        }
    }

    func testVerifyPasswordLockedTemplateFails() throws {
        // template's field is *LK* / * on every guest -- must verify false,
        // not crash or match.
        XCTAssertFalse(try UserAdmin.verifyPassword(
            name: "template", password: "", os: .solaris26,
            transport: solarisGuest()))
    }
}
