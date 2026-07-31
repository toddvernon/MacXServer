import XCTest
@testable import SwiftXServerCore

/// A scripted guest for clock work: every runCommand is logged, and answers
/// come from an ordered prefix table (first match wins) so a test can hand
/// back exactly what a 4.1.4 / 2.6 / NetBSD date would say. File verbs are
/// unused by ClockAdmin and fail loudly if something reaches for them.
private final class MockClockGuest: UserAdminTransport {
    /// Ordered "run <cmd>" log -- command ordering is part of the design
    /// (year set before precise set, probe before either).
    var log: [String] = []
    /// (prefix, canned result); first prefix match answers the command.
    var responses: [(prefix: String, result: RunResult)] = []

    func respond(to prefix: String, exitCode: Int = 0, output: String = "",
                 timedOut: Bool = false) {
        responses.append((prefix, RunResult(exitCode: exitCode, output: output,
                                            timedOut: timedOut)))
    }

    func runCommand(_ cmd: String, cwd: String?, timeoutMs: Int?, user: String?) throws -> RunResult {
        log.append(cmd)
        for (prefix, result) in responses where cmd.hasPrefix(prefix) {
            return result
        }
        return RunResult(exitCode: 0, output: "", timedOut: false)
    }

    func readFile(_ path: String, user: String?) throws -> FileContent {
        XCTFail("ClockAdmin must not read files (asked for \(path))")
        throw HeliosClient.HeliosError.protocolError("unexpected readFile")
    }

    func writeFile(_ path: String, data: Data, mode: Int?, user: String?) throws -> WriteResult {
        XCTFail("ClockAdmin must not write files (asked for \(path))")
        throw HeliosClient.HeliosError.protocolError("unexpected writeFile")
    }
}

final class ClockAdminTests: XCTestCase {

    /// 2026-07-12 22:59:30 UTC -- the timestamp the live validation used.
    private let mac = Date(timeIntervalSince1970: 1_783_897_170)
    /// Same instant minus 7 days: a skewed guest clock in the same year.
    private var guestSameYear: Date { mac.addingTimeInterval(-7 * 86_400) }
    /// 1970-02-03: the dead-NVRAM-battery case, year differs.
    private let guestEpochYear = Date(timeIntervalSince1970: 2_851_200)

    // MARK: Pinned command strings (the wire grammar IS the contract;
    // each was validated against the live guest OS on 2026-07-12)

    func testNoYearSetCommandsPinned() {
        XCTAssertEqual(ClockAdmin.noYearSetCommand(os: .sunos414, utc: mac),
                       "/bin/date -u 07122259.30")
        XCTAssertEqual(ClockAdmin.noYearSetCommand(os: .solaris26, utc: mac),
                       "/usr/bin/date -u 07122259.30")
        XCTAssertEqual(ClockAdmin.noYearSetCommand(os: .netbsd, utc: mac),
                       "/bin/date -u 07122259.30")
    }

    func testYearSetCommandsPinned() {
        // BSD grammar: year leads (2-digit on SunOS, 4-digit on NetBSD).
        XCTAssertEqual(ClockAdmin.yearSetCommand(os: .sunos414, utc: mac),
                       "/bin/date -u 2607122259.30")
        XCTAssertEqual(ClockAdmin.yearSetCommand(os: .netbsd, utc: mac),
                       "/bin/date -u 202607122259.30")
        // SVR4 grammar: [cc]yy trails, no seconds field exists.
        XCTAssertEqual(ClockAdmin.yearSetCommand(os: .solaris26, utc: mac),
                       "/usr/bin/date -u 071222592026")
        // IRIX: SVR4 grammar off /sbin/date (both forms verified live on the
        // Indigo, 2026-07-31).
        XCTAssertEqual(ClockAdmin.yearSetCommand(os: .irix65, utc: mac),
                       "/sbin/date -u 071222592026")
        XCTAssertEqual(ClockAdmin.noYearSetCommand(os: .irix65, utc: mac),
                       "/sbin/date -u 07122259.30")
    }

    func testYearChangesComparesUTCYears() {
        XCTAssertFalse(ClockAdmin.yearChanges(guest: guestSameYear, mac: mac))
        XCTAssertTrue(ClockAdmin.yearChanges(guest: guestEpochYear, mac: mac))
    }

    // MARK: Y2K probe classification (answers captured from the live VM)

    func testProbeClassifiesPatchedDate() throws {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date '+%Y'", output: "2026\n")
        XCTAssertEqual(try ClockAdmin.probeY2KDate(transport: guest), .patched)
        XCTAssertEqual(guest.log, ["/bin/date '+%Y'"])
    }

    func testProbeClassifiesStockDate() throws {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date '+%Y'", exitCode: 64,
                      output: "date: bad format character - Y\n")
        guard case .stock = try ClockAdmin.probeY2KDate(transport: guest) else {
            return XCTFail("stock date answer must classify as .stock")
        }
    }

    func testProbeUnrecognizedAnswerIsInconclusive() throws {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date '+%Y'", exitCode: 1, output: "date: cannot fork\n")
        guard case .inconclusive = try ClockAdmin.probeY2KDate(transport: guest) else {
            return XCTFail("an unrecognized answer must classify as .inconclusive")
        }
    }

    // MARK: syncClock policy

    /// Answer the verify read-back with the Mac's own time. The prefix table
    /// is ordered, so the set forms ("<path> -u 07...", "-u 26...") get no-op
    /// entries BEFORE the bare "<path> -u" catch-all that feeds verify.
    private func respondToVerify(_ guest: MockClockGuest, os: MachineOS) {
        let path = ClockAdmin.datePath(os: os)
        guest.respond(to: "\(path) -u 2", output: "")
        guest.respond(to: "\(path) -u 0", output: "")
        guest.respond(to: "\(path) -u",
                      output: "Sun Jul 12 22:59:30 GMT 2026\n")
    }

    func testSyncSameYearRunsOneSetAndVerifies() throws {
        let guest = MockClockGuest()
        respondToVerify(guest, os: .sunos414)
        let skew = try ClockAdmin.syncClock(os: .sunos414, transport: guest,
                                            guest: guestSameYear, now: { self.mac })
        XCTAssertEqual(guest.log, ["/bin/date -u 07122259.30", "/bin/date -u"])
        XCTAssertEqual(skew, 0, accuracy: 0.5)
    }

    func testSyncYearChangeOnPatched414ProbesThenSetsTwice() throws {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date '+%Y'", output: "2026\n")
        respondToVerify(guest, os: .sunos414)
        try ClockAdmin.syncClock(os: .sunos414, transport: guest,
                                 guest: guestEpochYear, now: { self.mac })
        XCTAssertEqual(guest.log, ["/bin/date '+%Y'",
                                   "/bin/date -u 2607122259.30",
                                   "/bin/date -u 07122259.30",
                                   "/bin/date -u"])
    }

    func testSyncYearChangeOnStock414FailsClosedBeforeAnySet() {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date '+%Y'", exitCode: 64,
                      output: "date: bad format character - Y\n")
        XCTAssertThrowsError(try ClockAdmin.syncClock(
            os: .sunos414, transport: guest,
            guest: guestEpochYear, now: { self.mac })) { error in
            guard case ClockAdminError.y2kUnverified = error as! ClockAdminError else {
                return XCTFail("expected .y2kUnverified, got \(error)")
            }
        }
        // The probe ran; NO set command ever went to the box.
        XCTAssertEqual(guest.log, ["/bin/date '+%Y'"])
    }

    func testSyncYearChangeForcedSkipsProbe() throws {
        let guest = MockClockGuest()
        respondToVerify(guest, os: .sunos414)
        try ClockAdmin.syncClock(os: .sunos414, transport: guest,
                                 guest: guestEpochYear, force: true,
                                 now: { self.mac })
        XCTAssertEqual(guest.log, ["/bin/date -u 2607122259.30",
                                   "/bin/date -u 07122259.30",
                                   "/bin/date -u"])
    }

    func testSyncYearChangeOnSolarisNeedsNoProbe() throws {
        let guest = MockClockGuest()
        guest.respond(to: "/usr/bin/date -u 0", output: "")
        guest.respond(to: "/usr/bin/date -u",
                      output: "Sun Jul 12 22:59:30 GMT 2026\n")
        try ClockAdmin.syncClock(os: .solaris26, transport: guest,
                                 guest: guestEpochYear, now: { self.mac })
        XCTAssertEqual(guest.log, ["/usr/bin/date -u 071222592026",
                                   "/usr/bin/date -u 07122259.30",
                                   "/usr/bin/date -u"])
    }

    func testSyncFailedSetSurfacesCommand() {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date -u 0", exitCode: 1, output: "date: you must be root\n")
        XCTAssertThrowsError(try ClockAdmin.syncClock(
            os: .sunos414, transport: guest,
            guest: guestSameYear, now: { self.mac })) { error in
            guard case ClockAdminError.commandFailed = error as! ClockAdminError else {
                return XCTFail("expected .commandFailed, got \(error)")
            }
        }
    }

    // MARK: Verify read-back parsing

    func testParseCtimeHandlesEveryGuestDialect() {
        // Solaris / SunOS say GMT; NetBSD says UTC; SunOS pads single-digit
        // days to a double space. All are the same instant.
        for line in ["Sun Jul 12 22:59:30 GMT 2026",
                     "Sun Jul 12 22:59:30 UTC 2026",
                     "Sun Jul  5 22:59:30 GMT 2026"] {
            XCTAssertNotNil(ClockAdmin.parseCtime(line + "\n"), line)
        }
        XCTAssertEqual(ClockAdmin.parseCtime("Sun Jul 12 22:59:30 GMT 2026\n"), mac)
        XCTAssertNil(ClockAdmin.parseCtime("date: bad conversion\n"))
    }

    func testVerifyRejectsDriftBeyondTolerance() {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date -u",
                      output: "Sun Jul 12 23:59:30 GMT 2026\n")  // an hour off
        XCTAssertThrowsError(try ClockAdmin.verify(
            os: .sunos414, transport: guest, now: { self.mac })) { error in
            guard case ClockAdminError.verifyFailed = error as! ClockAdminError else {
                return XCTFail("expected .verifyFailed, got \(error)")
            }
        }
    }

    func testVerifyRejectsUnparseableOutput() {
        let guest = MockClockGuest()
        guest.respond(to: "/bin/date -u", output: "Sonntag 12. Juli 2026\n")
        XCTAssertThrowsError(try ClockAdmin.verify(
            os: .sunos414, transport: guest, now: { self.mac }))
    }
}
