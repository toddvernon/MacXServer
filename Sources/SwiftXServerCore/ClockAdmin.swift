import Foundation

// ClockAdmin -- set a guest's clock from this Mac's (NTP-true) clock over the
// Helios agent, per-OS, without ever handing a year to a date(1) that can't
// take one.
//
// The reason this file exists at all is SunOS 4.1.4: its stock /bin/date
// mis-parses a year argument (Sun BugId 1086103), and a bad year lands in the
// Mostek TOD chip and can make the box UNBOOTABLE -- recovery is booting
// install media just to re-enter the time. Sun's fix is patch 105143-03. So
// the rules here are:
//
//   - The normal set NEVER carries a year. BSD date parses its digit string
//     right-to-left, so an 8-digit mmddhhmm(.ss) argument can't touch the
//     year field. Field-proven on the real fleet 2026-07-12.
//   - A set that must change the year is gated, on 4.1.4, behind a live
//     probe of the box's own date command: `date '+%Y'` exits 0 and prints a
//     4-digit year only on a Y2K-patched date (the %Y fix and the set-year
//     fix shipped in the same patch). Stock date answers
//     "bad format character - Y", exit 64.
//   - A failed probe throws `.y2kUnverified`; the UI turns that into an
//     explicit Force Set with a warning, so the human owns the gamble.
//
// Solaris 2.6 and NetBSD have no such trap; they get the year form directly
// when needed. Every set is followed by the precise no-year form (seconds
// resolution), and every sync ends with a read-back verification. All
// commands run as root over the admin connection, in UTC (-u) so the guest's
// TZ config can't skew the set.

// MARK: - Errors

public enum ClockAdminError: Error, LocalizedError, Equatable {
    case commandFailed(cmd: String, exitCode: Int, output: String)
    /// A year change is needed on SunOS 4.1.4 and the box's date command
    /// didn't prove itself Y2K-patched. The associated string says what the
    /// probe actually saw.
    case y2kUnverified(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let exitCode, let output):
            let tail = output.isEmpty ? "" : ": \(output)"
            return "\u{201C}\(cmd)\u{201D} failed (exit \(exitCode))\(tail)"
        case .y2kUnverified(let why):
            return why
        case .verifyFailed(let why):
            return "The clock was set but reading it back failed: \(why)"
        }
    }
}

// MARK: - ClockAdmin

public enum ClockAdmin {

    /// How far the verify read-back may sit from the Mac clock and still
    /// count as success. Generous: covers command spawn + LAN round trip on
    /// a 25MHz SPARC, while still catching a set that landed wrong.
    public static let verifyToleranceSeconds: TimeInterval = 15

    // MARK: Per-OS command table

    /// Absolute path to the date binary we drive (the daemon's PATH is
    /// minimal, same rule as MachineOS.shutdownCommand).
    public static func datePath(os: MachineOS) -> String {
        switch os {
        case .solaris26: return "/usr/bin/date"
        case .sunos414:  return "/bin/date"
        case .netbsd:    return "/bin/date"
        }
    }

    /// The always-safe set: `date -u mmddhhmm.ss`. No year field exists in
    /// the argument, so even a stock 4.1.4 date can't corrupt the TOD year.
    /// Validated live on all three guests 2026-07-12.
    public static func noYearSetCommand(os: MachineOS, utc: Date) -> String {
        "\(datePath(os: os)) -u \(format(utc, "MMddHHmm.ss"))"
    }

    /// The year-carrying set, for when the guest's year is actually wrong
    /// (dead NVRAM battery boots thinking it's 1970). Grammar differs per OS:
    /// BSD-style puts the year first, SVR4 appends [cc]yy (and takes no
    /// seconds -- the follow-up no-year set restores precision).
    public static func yearSetCommand(os: MachineOS, utc: Date) -> String {
        switch os {
        case .solaris26: return "\(datePath(os: os)) -u \(format(utc, "MMddHHmmyyyy"))"
        case .sunos414:  return "\(datePath(os: os)) -u \(format(utc, "yyMMddHHmm.ss"))"
        case .netbsd:    return "\(datePath(os: os)) -u \(format(utc, "yyyyMMddHHmm.ss"))"
        }
    }

    /// True when syncing would change the guest's calendar year (compared in
    /// UTC, which is also how we set).
    public static func yearChanges(guest: Date, mac: Date) -> Bool {
        utcYear(of: guest) != utcYear(of: mac)
    }

    // MARK: Y2K probe (SunOS 4.1.4)

    public enum Y2KProbe: Equatable, Sendable {
        /// `date '+%Y'` printed a 4-digit year: the box runs a Y2K-patched
        /// date (105143 or kin) and may take a year argument.
        case patched
        /// The command failed the way stock 4.1.4 date does.
        case stock(detail: String)
        /// Neither answer we recognize (agent hiccup, exotic date binary).
        /// Treated exactly like `.stock` for gating -- fail closed.
        case inconclusive(detail: String)

        public var isPatched: Bool { if case .patched = self { return true }; return false }
    }

    /// Ask the box's own date command whether it understands years: run
    /// `date '+%Y'` and classify. Purely read-only.
    public static func probeY2KDate(transport: UserAdminTransport) throws -> Y2KProbe {
        let cmd = "\(datePath(os: .sunos414)) '+%Y'"
        let r = try transport.runCommand(cmd, cwd: nil, timeoutMs: 30_000, user: nil)
        if r.timedOut {
            return .inconclusive(detail: "the probe timed out")
        }
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.exitCode == 0, out.count == 4, out.allSatisfy(\.isNumber) {
            return .patched
        }
        if r.output.contains("bad format character") {
            return .stock(detail: out)
        }
        return .inconclusive(detail: "exit \(r.exitCode): \(out)")
    }

    // MARK: Sync

    /// Set the guest clock to the Mac clock. `guest` is the guest's current
    /// time (from sysinfo) -- it only decides whether the year must change.
    /// Throws `.y2kUnverified` instead of running anything when a year change
    /// is needed on 4.1.4 and the probe can't prove the patch; pass
    /// `force: true` to run it anyway (the UI's Force Set).
    ///
    /// Returns the verified skew (guest minus Mac, seconds) after the set.
    @discardableResult
    public static func syncClock(os: MachineOS,
                                 transport: UserAdminTransport,
                                 guest: Date,
                                 force: Bool = false,
                                 now: () -> Date = Date.init) throws -> TimeInterval {
        let needsYear = yearChanges(guest: guest, mac: now())
        if needsYear && os == .sunos414 && !force {
            switch try probeY2KDate(transport: transport) {
            case .patched:
                break
            case .stock(let detail):
                throw ClockAdminError.y2kUnverified(
                    "The machine's date command failed the Year-2000 check "
                    + "(\u{201C}\(detail)\u{201D}) -- it looks like the stock SunOS 4.1.4 "
                    + "date, which corrupts the clock chip when given a year.")
            case .inconclusive(let detail):
                throw ClockAdminError.y2kUnverified(
                    "Couldn't confirm the machine's date command handles years "
                    + "(\(detail)).")
            }
        }
        // Year first (coarse, minute precision on Solaris), then the no-year
        // form for second precision. Each set is built from a fresh Mac
        // timestamp and runs as its own request (a compound set+read once
        // wedged a NetBSD guest).
        if needsYear {
            try run(yearSetCommand(os: os, utc: now()), transport: transport)
        }
        try run(noYearSetCommand(os: os, utc: now()), transport: transport)
        return try verify(os: os, transport: transport, now: now)
    }

    /// Read the clock back (`date -u`) and compare against the Mac.
    static func verify(os: MachineOS,
                       transport: UserAdminTransport,
                       now: () -> Date = Date.init) throws -> TimeInterval {
        let cmd = "\(datePath(os: os)) -u"
        let r = try transport.runCommand(cmd, cwd: nil, timeoutMs: 30_000, user: nil)
        guard r.exitCode == 0, !r.timedOut else {
            throw ClockAdminError.verifyFailed("exit \(r.exitCode): \(r.output)")
        }
        guard let readBack = parseCtime(r.output) else {
            throw ClockAdminError.verifyFailed(
                "unrecognized date output \u{201C}\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
        }
        let skew = readBack.timeIntervalSince(now())
        guard abs(skew) <= verifyToleranceSeconds else {
            throw ClockAdminError.verifyFailed(
                "the clock reads \(Int(skew))s from this Mac after the set")
        }
        return skew
    }

    // MARK: Helpers

    /// Parse the classic ctime line every guest date prints:
    /// "Sun Jul 12 22:59:30 GMT 2026" (SunOS/Solaris) or "... UTC 2026"
    /// (NetBSD). SunOS pads single-digit days with a double space, so the
    /// line is whitespace-normalized before parsing.
    static func parseCtime(_ output: String) -> Date? {
        let line = output
            .split(separator: "\n").first.map(String.init) ?? ""
        let normalized = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        return f.date(from: normalized)
    }

    private static func run(_ cmd: String, transport: UserAdminTransport) throws {
        let r = try transport.runCommand(cmd, cwd: nil, timeoutMs: 30_000, user: nil)
        guard r.exitCode == 0, !r.timedOut else {
            throw ClockAdminError.commandFailed(
                cmd: cmd, exitCode: r.timedOut ? -1 : r.exitCode, output: r.output)
        }
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func utcYear(of date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.year, from: date)
    }
}
