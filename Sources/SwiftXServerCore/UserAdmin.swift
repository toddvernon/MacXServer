import Foundation
import Darwin
import CommonCrypto

// UserAdmin -- host-driven add/delete/list users on a guest, over the existing
// Helios verbs (HELIOS_USER_MANAGEMENT.md, ratified 2026-07-10).
//
// The design in one breath: all the per-OS knowledge (passwd/shadow/
// master.passwd formats, home paths, activation commands) lives HERE in pure,
// unit-testable builders keyed by exhaustive MachineOS switches; the pipeline
// composes them over read_file / run_command / write_file, ordered so the
// login-enabling write is the last, atomic step (write_file is temp+rename and
// preserves mode/owner on overwrite -- built for exactly this class of edit).
// No agent changes; works against every deployed agent today.
//
// The account scheme is the one the 2026-07-04 image convergence baked into
// all three guests (SPARCplug guest-config/README.md): gid 100 (users) for
// every human account, uid 1001+ reserved for macXserver-created users, homes
// at /home/<name> on every guest (Solaris physically /export/home behind the
// /home symlink), and a locked `template` account (uid 1999) whose home is the
// stamp new homes are copied from.

// MARK: - Transport

/// The slice of HeliosClient the pipeline drives, as a protocol so tests can
/// script every exchange without a guest. HeliosClient conforms as-is.
public protocol UserAdminTransport: AnyObject {
    func readFile(_ path: String, user: String?) throws -> FileContent
    @discardableResult
    func writeFile(_ path: String, data: Data, mode: Int?, user: String?) throws -> WriteResult
    @discardableResult
    func runCommand(_ cmd: String, cwd: String?, timeoutMs: Int?, user: String?) throws -> RunResult
}

extension HeliosClient: UserAdminTransport {}

// MARK: - Errors

public enum UserAdminError: Error, LocalizedError, Equatable {
    case invalidUsername(String)
    case userExists(String)
    case userNotFound(String)
    case refusedDelete(String)
    case malformedRecord(path: String, line: String)
    case commandFailed(cmd: String, exitCode: Int, output: String)
    case verifyFailed(String)
    case unsupportedHash(String)
    case planningFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUsername(let why):
            return why
        case .userExists(let name):
            return "\u{201C}\(name)\u{201D} already exists on the machine."
        case .userNotFound(let name):
            return "No account named \u{201C}\(name)\u{201D} on the machine."
        case .refusedDelete(let why):
            return why
        case .malformedRecord(let path, let line):
            return "Couldn't parse a record in \(path): \u{201C}\(line)\u{201D}. "
                + "The file may have been hand-edited; fix it before managing "
                + "users from here."
        case .commandFailed(let cmd, let exitCode, let output):
            let tail = output.isEmpty ? "" : ": \(output)"
            return "\u{201C}\(cmd)\u{201D} failed (exit \(exitCode))\(tail)"
        case .verifyFailed(let why):
            return "The account was written but verification failed: \(why)"
        case .unsupportedHash(let format):
            return "The account's password uses a hash format this app "
                + "can't check (\(format))."
        case .planningFailed(let why):
            return "Couldn't work out the machine's account conventions: \(why)"
        }
    }
}

// MARK: - Records

/// One 7-field passwd(5) entry: `name:password:uid:gid:gecos:home:shell`.
/// Covers /etc/passwd on all three guests. (NetBSD's /etc/master.passwd has
/// three extra fields -- class:change:expire -- handled by MasterPasswdEntry.)
public struct PasswdEntry: Equatable, Sendable {
    public var name: String
    public var passwordField: String
    public var uid: Int
    public var gid: Int
    public var gecos: String
    public var home: String
    public var shell: String

    public init(name: String, passwordField: String, uid: Int, gid: Int,
                gecos: String, home: String, shell: String) {
        self.name = name; self.passwordField = passwordField
        self.uid = uid; self.gid = gid; self.gecos = gecos
        self.home = home; self.shell = shell
    }

    /// Parse one line; nil for a malformed one (callers decide how loud to be).
    public static func parse(_ line: String) -> PasswdEntry? {
        let f = line.components(separatedBy: ":")
        guard f.count == 7, let uid = Int(f[2]), let gid = Int(f[3]) else { return nil }
        return PasswdEntry(name: f[0], passwordField: f[1], uid: uid, gid: gid,
                           gecos: f[4], home: f[5], shell: f[6])
    }

    public var line: String {
        "\(name):\(passwordField):\(uid):\(gid):\(gecos):\(home):\(shell)"
    }
}

/// One NetBSD master.passwd(5) entry:
/// `name:password:uid:gid:class:change:expire:gecos:home:shell`.
public struct MasterPasswdEntry: Equatable, Sendable {
    public var name: String
    public var passwordField: String
    public var uid: Int
    public var gid: Int
    public var loginClass: String
    public var change: Int
    public var expire: Int
    public var gecos: String
    public var home: String
    public var shell: String

    public static func parse(_ line: String) -> MasterPasswdEntry? {
        let f = line.components(separatedBy: ":")
        guard f.count == 10, let uid = Int(f[2]), let gid = Int(f[3]),
              let change = Int(f[5]), let expire = Int(f[6]) else { return nil }
        var e = MasterPasswdEntry()
        e.name = f[0]; e.passwordField = f[1]; e.uid = uid; e.gid = gid
        e.loginClass = f[4]; e.change = change; e.expire = expire
        e.gecos = f[7]; e.home = f[8]; e.shell = f[9]
        return e
    }

    public init() {
        name = ""; passwordField = ""; uid = 0; gid = 0
        loginClass = ""; change = 0; expire = 0
        gecos = ""; home = ""; shell = ""
    }

    public var line: String {
        "\(name):\(passwordField):\(uid):\(gid):\(loginClass):\(change):\(expire):\(gecos):\(home):\(shell)"
    }
}

// MARK: - The pure core

public enum UserAdmin {

    /// The convergence account scheme's constants.
    public static let usersGID = 100
    public static let firstUserUID = 1001
    public static let templateUID = 1999
    public static let templateHome = "/home/template"
    public static let loginShell = "/usr/local/bin/tcsh"

    // MARK: Username + password

    /// STOCK SYSTEM account names for each curated guest OS, plus our own
    /// `template` plumbing name (uid 1999; deleteUser refuses it too).
    /// Typing one into an add-user surface would collide at apply time with
    /// an opaque refusal -- the 2026-07-16 field find -- so the validator
    /// catches it at typing time. System accounts only, on purpose
    /// (2026-07-26): the authoritative list of what actually exists on a
    /// published image rides its catalog entry (`reservedUsernames`,
    /// captured from the stripped image's own passwd by strip-release.sh)
    /// and overrides this via usernameProblem's `reserved:`; this static
    /// list is only the fallback when no catalog data is at hand. Personal
    /// dev accounts (tvernon, fred, synology) don't belong here -- they're
    /// stripped from published images, and on dev machines where they do
    /// exist, addUser's live duplicate check is the backstop. nil OS = the
    /// union (the safe answer when the target system is unknown).
    public static func reservedNames(os: MachineOS?) -> Set<String> {
        let common: Set<String> = ["root", "daemon", "bin", "sys", "adm",
                                   "uucp", "nobody", "template"]
        let solaris: Set<String> = ["lp", "smtp", "nuucp", "listen",
                                    "noaccess", "nobody4"]
        let sunos: Set<String>   = ["news", "ingres", "audit", "sync",
                                    "sysdiag", "operator"]
        let netbsd: Set<String>  = ["toor", "operator", "games", "postfix",
                                    "named", "ntpd", "sshd"]
        switch os {
        case .solaris26: return common.union(solaris)
        case .sunos414:  return common.union(sunos)
        case .netbsd:    return common.union(netbsd)
        case nil:        return common.union(solaris).union(sunos).union(netbsd)
        }
    }

    /// Vintage-Unix username rules: 1-8 chars, `[a-z][a-z0-9]*` (the 4.1.4-era
    /// limit; also keeps NIS-ish tooling and 8-char utmp fields happy), and
    /// not a reserved system-account name for the target OS.
    /// Returns a user-facing reason, or nil when the name is fine.
    ///
    /// `reserved` overrides the static per-OS list with the ACTUAL account
    /// names of the target image (the catalog entry's `reservedUsernames`) --
    /// only names that really exist can collide, so a caller that has the
    /// real list should always pass it.
    public static func usernameProblem(_ name: String,
                                       os: MachineOS? = nil,
                                       reserved: Set<String>? = nil) -> String? {
        if name.isEmpty { return "Enter a username." }
        if name.count > 8 {
            return "Usernames on these systems are at most 8 characters."
        }
        let lower = "abcdefghijklmnopqrstuvwxyz"
        guard let first = name.first, lower.contains(first) else {
            return "Usernames must start with a lowercase letter."
        }
        let allowed = Set(lower + "0123456789")
        guard name.allSatisfy({ allowed.contains($0) }) else {
            return "Usernames may only contain lowercase letters and digits."
        }
        if (reserved ?? reservedNames(os: os)).contains(name) {
            return "\u{201C}\(name)\u{201D} is a system account on this "
                 + "machine \u{2014} pick another name."
        }
        return nil
    }

    /// Traditional DES crypt(3) of `password` -- the format all three guests
    /// read. DES only uses the first 8 characters (the UI says so out loud).
    /// The hash is computed HERE so the cleartext never crosses the wire.
    /// crypt(3) uses a static buffer, so this is not reentrant; every caller
    /// runs on the single user-admin flow at a time, which is fine.
    public static func desHash(password: String, salt: String? = nil) -> String {
        let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let s = salt ?? String([alphabet.randomElement()!, alphabet.randomElement()!])
        guard let out = crypt(password, s) else {
            // crypt(3) only fails on an invalid salt; ours is always valid.
            fatalError("crypt(3) returned NULL for a valid DES salt")
        }
        return String(cString: out)
    }

    /// First free uid >= 1001 that no existing account holds. (1999 belongs to
    /// `template`; being "taken" excludes it like any other.)
    public static func nextFreeUID(existing: [Int]) -> Int {
        let taken = Set(existing)
        var uid = firstUserUID
        while taken.contains(uid) { uid += 1 }
        return uid
    }

    // MARK: The add plan (conventions learned from the box itself)

    /// Everything box-specific about a new account, derived by planAddUser
    /// from what's actually on the machine -- our images and real hardware
    /// have different conventions (real boxes have no template account, may
    /// keep homes in /home2, may lack tcsh), so the plan is learned, not
    /// assumed. HELIOS_USER_MANAGEMENT.md decision #6.
    public struct AddPlan: Equatable, Sendable {
        public var uid: Int
        public var gid: Int
        /// The gid's name from /etc/group, when it has one (UI summary only).
        public var groupName: String?
        /// Home parent as it appears in the record (e.g. "/home", "/home2").
        public var homeParent: String
        /// Where mkdir/chown/rm actually operate (Solaris /home -> /export/home).
        public var homePhysicalParent: String
        public var shell: String

        public init(uid: Int, gid: Int, groupName: String?, homeParent: String,
                    homePhysicalParent: String, shell: String) {
            self.uid = uid; self.gid = gid; self.groupName = groupName
            self.homeParent = homeParent
            self.homePhysicalParent = homePhysicalParent
            self.shell = shell
        }

        public func homeRecordPath(name: String) -> String { "\(homeParent)/\(name)" }
        public func homePhysicalPath(name: String) -> String { "\(homePhysicalParent)/\(name)" }

        /// One quiet line for the Add sheet: what the account will be.
        public func summary(name: String) -> String {
            let group = groupName.map { "\($0) (\(gid))" } ?? "gid \(gid)"
            let who = name.isEmpty ? "<user>" : name
            return "uid \(uid) \u{00B7} group \(group) \u{00B7} "
                + "home \(homeParent)/\(who) \u{00B7} \(shell)"
        }
    }

    /// The name:uid:gid:home facts of every account in a records file,
    /// tolerant of both the 7-field passwd and 10-field master.passwd shapes
    /// (the accounts file differs per OS).
    public struct AccountFacts: Equatable, Sendable {
        public var name: String
        public var uid: Int
        public var gid: Int
        public var home: String
    }

    public static func accountFacts(_ content: String) -> [AccountFacts] {
        content.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: ":")
            if f.count == 7, let uid = Int(f[2]), let gid = Int(f[3]) {
                return AccountFacts(name: f[0], uid: uid, gid: gid, home: f[5])
            }
            if f.count == 10, let uid = Int(f[2]), let gid = Int(f[3]) {
                return AccountFacts(name: f[0], uid: uid, gid: gid, home: f[8])
            }
            return nil
        }
    }

    /// The accounts convention-learning looks at: real people, not plumbing.
    /// uid 100..<60000 covers every human on the fleet (ipc's tvernon is
    /// uid 100) while excluding daemons and the nobody family.
    public static func humanAccounts(_ facts: [AccountFacts]) -> [AccountFacts] {
        facts.filter { $0.uid >= 100 && $0.uid < 60000 && $0.name != "nobody" }
    }

    /// `(name, gid)` pairs from /etc/group content.
    public static func parseGroups(_ content: String) -> [(name: String, gid: Int)] {
        content.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: ":")
            guard f.count >= 3, let gid = Int(f[2]) else { return nil }
            return (f[0], gid)
        }
    }

    /// The gid a new account joins: the box's own convention -- the most
    /// common gid among human accounts (ties broken toward the smaller gid).
    /// System gids (< 10: wheel/root, daemon, kmem, bin, tty...) never count,
    /// even when a human account sits in one -- ipc's real /etc/passwd had a
    /// user parked in gid 1 (daemon), and adopting that would compound the
    /// mistake. Falls back to a group named "users" then "staff" from
    /// /etc/group; nil when there's no defensible answer.
    public static func deriveGID(humans: [AccountFacts],
                                 groupContent: String) -> (gid: Int, name: String?)? {
        let groups = parseGroups(groupContent)
        func name(of gid: Int) -> String? { groups.first { $0.gid == gid }?.name }

        var counts: [Int: Int] = [:]
        for h in humans where h.gid >= 10 && h.gid < 60000 {
            counts[h.gid, default: 0] += 1
        }
        if let topCount = counts.values.max() {
            let gid = counts.filter { $0.value == topCount }.keys.min()!
            return (gid, name(of: gid))
        }
        for candidate in ["users", "staff"] {
            if let g = groups.first(where: { $0.name == candidate }) {
                return (g.gid, g.name)
            }
        }
        return nil
    }

    /// The record-side home parent for a new account: where the box's human
    /// accounts already live (most common parent, ties broken toward the OS
    /// default then alphabetically). No humans to learn from -> "/home".
    public static func deriveHomeParent(humans: [AccountFacts],
                                        os: MachineOS) -> String {
        let fallback = "/home"
        var counts: [String: Int] = [:]
        for h in humans {
            let parent = (h.home as NSString).deletingLastPathComponent
            if parent.count > 1 { counts[parent, default: 0] += 1 }
        }
        guard let top = counts.values.max() else { return fallback }
        let tied = counts.filter { $0.value == top }.keys.sorted()
        return tied.contains(fallback) ? fallback : tied[0]
    }

    /// Where mkdir/chown/rm actually operate for a record-side parent. On
    /// Solaris the conventional /home is the automount/symlink view over
    /// /export/home; anywhere else (and any learned nonstandard parent) the
    /// record path IS the physical path.
    public static func physicalHomeParent(os: MachineOS, recordParent: String) -> String {
        switch os {
        case .solaris26: return recordParent == "/home" ? "/export/home" : recordParent
        case .sunos414, .netbsd: return recordParent
        }
    }

    /// Learn the box's conventions and produce the plan the Add sheet shows
    /// and addUser executes: reads the accounts file and /etc/group, probes
    /// for the preferred shell. Read-only -- nothing on the guest changes.
    public static func planAddUser(os: MachineOS,
                                   transport: UserAdminTransport) throws -> AddPlan {
        let accounts = try readString(accountsFile(os: os), transport: transport)
        let facts = accountFacts(accounts)
        let humans = humanAccounts(facts)

        let uid = nextFreeUID(existing: facts.map(\.uid))
        guard let group = deriveGID(humans: humans,
                                    groupContent: (try? readString("/etc/group",
                                                                   transport: transport)) ?? "")
        else {
            throw UserAdminError.planningFailed("no existing user accounts to "
                + "learn a group from, and no \u{201C}users\u{201D} or "
                + "\u{201C}staff\u{201D} group in /etc/group")
        }
        let homeParent = deriveHomeParent(humans: humans, os: os)

        // Preferred shell if the box has it, /bin/csh (universal) otherwise.
        let probe = try transport.runCommand("test -x \(loginShell)", cwd: nil,
                                             timeoutMs: 10_000, user: nil)
        let shell = probe.exitCode == 0 ? loginShell : "/bin/csh"

        return AddPlan(uid: uid, gid: group.gid, groupName: group.name,
                       homeParent: homeParent,
                       homePhysicalParent: physicalHomeParent(os: os,
                                                              recordParent: homeParent),
                       shell: shell)
    }

    /// The account-record files the add/delete pipeline edits, in COMMIT
    /// ORDER for add (the login-enabling file last). Delete walks it in
    /// reverse (login-disabling file first).
    public static func recordFiles(os: MachineOS) -> [String] {
        switch os {
        case .solaris26: return ["/etc/shadow", "/etc/passwd"]
        case .sunos414:  return ["/etc/passwd"]
        case .netbsd:    return ["/etc/master.passwd"]
        }
    }

    /// The file uid allocation and existence checks read (the authoritative
    /// account list). NetBSD's /etc/passwd is generated by pwd_mkdb, so the
    /// master file is the truth there.
    public static func accountsFile(os: MachineOS) -> String {
        switch os {
        case .solaris26, .sunos414: return "/etc/passwd"
        case .netbsd:               return "/etc/master.passwd"
        }
    }

    /// Post-write activation, if the OS needs one. NetBSD's login(1) consults
    /// the pwd.db files, not master.passwd itself; pwd_mkdb regenerates them
    /// (and /etc/passwd). Absolute path per the per-OS agent audit rule.
    public static func activationCommand(os: MachineOS) -> String? {
        switch os {
        case .solaris26, .sunos414: return nil
        case .netbsd: return "/usr/sbin/pwd_mkdb -p /etc/master.passwd"
        }
    }

    /// Commands that own the freshly staged home (mkdir + app-side dotfile
    /// writes happen first; see addUser). chown by numeric uid and a separate
    /// chgrp on purpose -- the owner.group vs owner:group separator differs
    /// across these systems (BSD dot vs SVR4 colon); two commands sidestep it.
    public static func homeOwnershipCommands(home: String, uid: Int, gid: Int) -> [String] {
        [
            "chown -R \(uid) \(home)",
            "chgrp -R \(gid) \(home)",
            "chmod 755 \(home)",
        ]
    }

    // MARK: Record building

    /// Days since the epoch, for the shadow lastchg field. Injectable for tests.
    public static func daysSinceEpoch(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// The new-account line for `file` (one of recordFiles). `hash` lands in
    /// whichever field the OS reads it from: shadow on Solaris, passwd field 2
    /// on 4.1.4, master.passwd field 2 on NetBSD. uid/gid/home/shell come
    /// from the plan (learned from the box, not assumed).
    public static func recordLine(os: MachineOS, file: String, name: String,
                                  plan: AddPlan, gecos: String, hash: String,
                                  lastChangedDays: Int) -> String {
        let home = plan.homeRecordPath(name: name)
        switch os {
        case .solaris26:
            if file == "/etc/shadow" {
                // name:hash:lastchg:min:max:warn:inactive:expire:flag
                return "\(name):\(hash):\(lastChangedDays)::::::"
            }
            return PasswdEntry(name: name, passwordField: "x", uid: plan.uid,
                               gid: plan.gid, gecos: gecos, home: home,
                               shell: plan.shell).line
        case .sunos414:
            return PasswdEntry(name: name, passwordField: hash, uid: plan.uid,
                               gid: plan.gid, gecos: gecos, home: home,
                               shell: plan.shell).line
        case .netbsd:
            var e = MasterPasswdEntry()
            e.name = name; e.passwordField = hash; e.uid = plan.uid; e.gid = plan.gid
            e.gecos = gecos; e.home = home; e.shell = plan.shell
            return e.line
        }
    }

    /// Append `line` to record-file `content`, preserving the trailing-newline
    /// convention (passwd files end with one; keep it that way).
    public static func appendingRecord(_ content: String, line: String) -> String {
        var body = content
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        return body + line + "\n"
    }

    /// Remove `name`'s record line from `content`. Returns nil when no line
    /// matched (caller decides whether that's an error).
    public static func removingRecord(_ content: String, name: String) -> String? {
        var found = false
        let kept = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                if line.hasPrefix("\(name):") { found = true; return false }
                return true
            }
        guard found else { return nil }
        // split/joined preserves the trailing newline (the final empty
        // subsequence survives the filter).
        return kept.joined(separator: "\n")
    }

    /// Every parseable 7-field entry in a passwd-format `content`. NetBSD's
    /// master.passwd lines (10 fields) don't parse here -- use the guest's
    /// /etc/passwd for LISTING on every OS; it exists everywhere.
    public static func parsePasswd(_ content: String) -> [PasswdEntry] {
        content.split(separator: "\n").compactMap { PasswdEntry.parse(String($0)) }
    }

    // MARK: - The pipelines

    public struct AddRequest: Sendable {
        public var name: String
        public var gecos: String
        /// Precomputed DES hash (`desHash(password:)`) -- the pipeline never
        /// sees the cleartext.
        public var hash: String

        public init(name: String, gecos: String = "", hash: String) {
            self.name = name
            // GECOS rides inside a colon-separated record; strip the one byte
            // that would corrupt it (plus newlines, same reason).
            self.gecos = gecos.replacingOccurrences(of: ":", with: " ")
                              .replacingOccurrences(of: "\n", with: " ")
            self.hash = hash
        }
    }

    /// Add a user. Ordering (HELIOS_USER_MANAGEMENT.md): everything fallible
    /// runs BEFORE the commit point; the login-enabling record write is last
    /// and atomic. Returns the allocated uid. `progress` gets one short line
    /// per step for the UI transcript.
    ///
    /// `plan` is the AddPlan the caller previewed (the Add sheet fetches one
    /// so what it shows is what runs); nil derives one here. Either way the
    /// uid is re-checked against the account list read at commit time -- a
    /// stale previewed uid is silently bumped to the next free one.
    @discardableResult
    public static func addUser(_ req: AddRequest, os: MachineOS,
                               transport: UserAdminTransport,
                               lastChangedDays: Int = daysSinceEpoch(),
                               plan: AddPlan? = nil,
                               progress: ((String) -> Void)? = nil) throws -> Int {
        if let problem = usernameProblem(req.name, os: os) {
            throw UserAdminError.invalidUsername(problem)
        }

        // 1. Read the authoritative account list and refuse duplicates BEFORE
        //    learning or adopting a plan (refusals shouldn't probe anything),
        //    then settle the uid against the list just read -- a stale
        //    previewed uid is silently bumped to the next free one.
        progress?("Reading the machine's account list\u{2026}")
        let accountsPath = accountsFile(os: os)
        let accounts = try readRecords(accountsPath, transport: transport)
        let names = accounts.map { $0.components(separatedBy: ":").first ?? "" }
        if names.contains(req.name) { throw UserAdminError.userExists(req.name) }
        var plan = try plan ?? planAddUser(os: os, transport: transport)
        let uids = accountFacts(accounts.joined(separator: "\n")).map(\.uid)
        if uids.contains(plan.uid) { plan.uid = nextFreeUID(existing: uids) }
        let uid = plan.uid

        // Read every record file up front (shadow too, on Solaris) so a
        // half-edited pair is caught before anything is staged.
        var contents: [String: String] = [accountsPath: accounts.joined(separator: "\n") + "\n"]
        for file in recordFiles(os: os) where contents[file] == nil {
            contents[file] = try readString(file, transport: transport)
            if contents[file]!.contains("\n\(req.name):") || contents[file]!.hasPrefix("\(req.name):") {
                throw UserAdminError.userExists(req.name)
            }
        }

        // 2. Stage the home (fallible, pre-commit): mkdir, populate with the
        //    app-side canonical dotfiles, then own it. No guest template
        //    needed -- real boxes don't have one.
        let home = plan.homePhysicalPath(name: req.name)
        progress?("Creating the home directory\u{2026}")
        try run("mkdir \(home)", transport: transport)
        progress?("Writing the standard dotfiles\u{2026}")
        for file in CanonicalDotfiles.files {
            _ = try transport.writeFile("\(home)/\(file.name)", data: file.data,
                                        mode: 0o644, user: nil)
        }
        for cmd in homeOwnershipCommands(home: home, uid: uid, gid: plan.gid) {
            try run(cmd, transport: transport)
        }

        // 3. Commit: write the record files in commit order (login-enabling
        //    file LAST). Each write is atomic and preserves mode/owner.
        for file in recordFiles(os: os) {
            progress?("Writing \(file)\u{2026}")
            let line = recordLine(os: os, file: file, name: req.name, plan: plan,
                                  gecos: req.gecos, hash: req.hash,
                                  lastChangedDays: lastChangedDays)
            let updated = appendingRecord(contents[file] ?? "", line: line)
            _ = try transport.writeFile(file, data: Data(updated.utf8),
                                        mode: nil, user: nil)
        }

        // 4. Activation finisher (NetBSD pwd_mkdb). Idempotent: if it fails,
        //    master.passwd is already correct and a retry just reruns it.
        if let activate = activationCommand(os: os) {
            progress?("Rebuilding the password database\u{2026}")
            try run(activate, transport: transport)
        }

        // 5. Verify: the record reads back, and the home exists.
        progress?("Verifying\u{2026}")
        let readBack = try readString(accountsFile(os: os), transport: transport)
        guard readBack.contains("\(req.name):") else {
            throw UserAdminError.verifyFailed("the new record didn't read back "
                + "from \(accountsFile(os: os))")
        }
        let check = try transport.runCommand("ls -ld \(home)", cwd: nil,
                                             timeoutMs: nil, user: nil)
        guard check.exitCode == 0 else {
            throw UserAdminError.verifyFailed("the home directory \(home) "
                + "didn't verify: \(check.output)")
        }
        progress?("Done \u{2014} \u{201C}\(req.name)\u{201D} (uid \(uid)) can log in.")
        return uid
    }

    /// Delete a user. Walks the record files in REVERSE commit order (the
    /// login-disabling edit happens first), then optionally removes the home.
    /// Refuses root, template, and system accounts (uid < 100).
    public static func deleteUser(name: String, os: MachineOS,
                                  removeHome: Bool,
                                  transport: UserAdminTransport,
                                  progress: ((String) -> Void)? = nil) throws {
        progress?("Reading the machine's account list\u{2026}")
        let accountsPath = accountsFile(os: os)
        let content = try readString(accountsPath, transport: transport)
        guard let record = content.split(separator: "\n")
                .first(where: { $0.hasPrefix("\(name):") }) else {
            throw UserAdminError.userNotFound(name)
        }
        let fields = record.components(separatedBy: ":")
        guard fields.count > 2, let uid = Int(fields[2]) else {
            throw UserAdminError.malformedRecord(path: accountsPath,
                                                 line: String(record))
        }
        if name == "root" || name == "template" {
            throw UserAdminError.refusedDelete(
                "\u{201C}\(name)\u{201D} is part of the machine's plumbing and "
                + "can't be deleted from here.")
        }
        if uid < 100 {
            throw UserAdminError.refusedDelete(
                "\u{201C}\(name)\u{201D} (uid \(uid)) is a system account.")
        }

        // Record home BEFORE the record disappears; only trust a sane path.
        let recordedHome = fields.count >= 6 ? fields[fields.count - 2] : ""

        // Login-disabling edit first (reverse commit order), each atomic.
        for file in recordFiles(os: os).reversed() {
            let current = try readString(file, transport: transport)
            guard let updated = removingRecord(current, name: name) else {
                continue   // e.g. a passwd entry whose shadow line was already gone
            }
            progress?("Writing \(file)\u{2026}")
            _ = try transport.writeFile(file, data: Data(updated.utf8),
                                        mode: nil, user: nil)
        }
        if let activate = activationCommand(os: os) {
            progress?("Rebuilding the password database\u{2026}")
            try run(activate, transport: transport)
        }

        if removeHome {
            // Guard the rm: only a "<parent>/<name>" path whose parent is a
            // home parent this box actually uses -- learned from the other
            // human accounts, plus the OS-default parents. A hand-edited
            // record pointing somewhere weird never gets an rm -rf.
            let others = humanAccounts(accountFacts(content)).filter { $0.name != name }
            var allowedParents = Set(others.map {
                ($0.home as NSString).deletingLastPathComponent
            }.filter { $0.count > 1 })
            allowedParents.formUnion(["/home", "/export/home"])
            let parent = (recordedHome as NSString).deletingLastPathComponent
            if recordedHome.hasSuffix("/\(name)") && allowedParents.contains(parent) {
                let home = physicalHomeParent(os: os, recordParent: parent) + "/\(name)"
                progress?("Removing \(home)\u{2026}")
                try run("rm -rf \(home)", transport: transport)
            } else {
                progress?("Skipping home removal: the account's home was "
                    + "\u{201C}\(recordedHome)\u{201D}, not a standard location.")
            }
        }
        progress?("Done \u{2014} \u{201C}\(name)\u{201D} removed.")
    }

    /// The guest's accounts, parsed from /etc/passwd (7-field format on every
    /// OS -- on NetBSD it's the pwd_mkdb-generated copy, fine for listing).
    public static func listUsers(transport: UserAdminTransport) throws -> [PasswdEntry] {
        parsePasswd(try readString("/etc/passwd", transport: transport))
    }

    // MARK: Password verification

    /// Where the OS keeps the login hash. Field 2 of the record in every case;
    /// only the file differs (same split as recordFiles' hash-bearing member).
    public static func hashFile(os: MachineOS) -> String {
        switch os {
        case .solaris26: return "/etc/shadow"
        case .sunos414:  return "/etc/passwd"
        case .netbsd:    return "/etc/master.passwd"
        }
    }

    /// `name`'s hash field out of a hashFile's content; nil when no record.
    public static func storedHash(in content: String, name: String) -> String? {
        for line in content.split(separator: "\n") where line.hasPrefix("\(name):") {
            let f = line.components(separatedBy: ":")
            return f.count > 1 ? f[1] : nil
        }
        return nil
    }

    /// NetBSD sha1crypt: `$sha1$<iterations>$<salt>$<digest>`. Ported from
    /// NetBSD lib/libcrypt/crypt-sha1.c (PBKDF1-shaped iterated HMAC-SHA1,
    /// RFC 2898 with hmac_sha1 as the PRF). Accounts that predate UserAdmin
    /// on the NetBSD image use this -- it's what the installer's passwd(1)
    /// writes -- so password checks must speak it, not just DES.
    /// Returns the full formatted hash, or nil for a spec we can't parse.
    public static func sha1Crypt(password: String, saltSpec: String) -> String? {
        // saltSpec may be the full stored hash; only $sha1$<iter>$<salt> is
        // read. components on "$sha1$19018$MMsmUCca$..." gives
        // ["", "sha1", "19018", "MMsmUCca", ...].
        let parts = saltSpec.components(separatedBy: "$")
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "sha1",
              let iterations = UInt32(parts[2]), iterations >= 1,
              !parts[3].isEmpty, !password.isEmpty else { return nil }
        let salt = parts[3]

        // Prime the pump with <salt><magic><iterations>, hmac with the
        // password as key, then iterate on the digest.
        let pw = Array(password.utf8)
        let prime = Array("\(salt)$sha1$\(iterations)".utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), pw, pw.count,
               prime, prime.count, &digest)
        for _ in 1..<iterations {
            var next = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), pw, pw.count,
                   digest, digest.count, &next)
            digest = next
        }

        // crypt64 output: 3 bytes -> 4 chars, LOW six bits first. The final
        // group covers bytes 18, 19 and pads with byte 0 -- exactly what
        // crypt-sha1.c does, quirk and all.
        let itoa64 = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var out = ""
        func to64(_ value: UInt32) {
            var v = value
            for _ in 0..<4 { out.append(itoa64[Int(v & 0x3f)]); v >>= 6 }
        }
        for i in stride(from: 0, to: 18, by: 3) {
            to64(UInt32(digest[i]) << 16 | UInt32(digest[i + 1]) << 8
                 | UInt32(digest[i + 2]))
        }
        to64(UInt32(digest[18]) << 16 | UInt32(digest[19]) << 8
             | UInt32(digest[0]))
        return "$sha1$\(iterations)$\(salt)$\(out)"
    }

    /// Whether `password` matches a stored hash -- classic DES (all three
    /// guests) or NetBSD sha1crypt (pre-UserAdmin accounts on the NetBSD
    /// image). Locked and passwordless fields ("*", "*LK*", "NP", "x",
    /// empty) never match: a real DES hash is exactly 13 chars with both
    /// salt bytes in the crypt alphabet, and we check that here rather than
    /// hand crypt(3) a salt it would reject.
    public static func passwordMatches(_ password: String, storedHash: String) -> Bool {
        if storedHash.hasPrefix("$sha1$") {
            return sha1Crypt(password: password, saltSpec: storedHash) == storedHash
        }
        guard storedHash.count == 13 else { return false }
        let alphabet = Set("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let salt = String(storedHash.prefix(2))
        guard salt.allSatisfy({ alphabet.contains($0) }) else { return false }
        return desHash(password: password, salt: salt) == storedHash
    }

    /// Verify `name`'s password: read the guest's hash-bearing file (as root,
    /// like everything here) and compare host-side. The cleartext never
    /// crosses the wire. False = wrong password OR an account that can't log
    /// in with a password at all (locked, NP). A modular-crypt hash in a
    /// format we don't speak (MD5 `$1$`, Blowfish `$2a$`, ...) throws
    /// unsupportedHash instead of lying "wrong password".
    public static func verifyPassword(name: String, password: String,
                                      os: MachineOS,
                                      transport: UserAdminTransport) throws -> Bool {
        let content = try readString(hashFile(os: os), transport: transport)
        guard let hash = storedHash(in: content, name: name) else {
            throw UserAdminError.userNotFound(name)
        }
        if hash.hasPrefix("$") && !hash.hasPrefix("$sha1$") {
            let tag = hash.components(separatedBy: "$").dropFirst().first ?? "?"
            throw UserAdminError.unsupportedHash("$\(tag)$")
        }
        return passwordMatches(password, storedHash: hash)
    }

    // MARK: Plumbing

    private static func readString(_ path: String,
                                   transport: UserAdminTransport) throws -> String {
        let file = try transport.readFile(path, user: nil)
        return String(decoding: file.data, as: UTF8.self)
    }

    private static func readRecords(_ path: String,
                                    transport: UserAdminTransport) throws -> [String] {
        try readString(path, transport: transport)
            .split(separator: "\n").map(String.init)
    }

    private static func run(_ cmd: String,
                            transport: UserAdminTransport) throws {
        let result = try transport.runCommand(cmd, cwd: nil, timeoutMs: 30_000,
                                              user: nil)
        guard result.exitCode == 0 else {
            throw UserAdminError.commandFailed(cmd: cmd,
                                               exitCode: result.exitCode,
                                               output: result.output
                                                   .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
