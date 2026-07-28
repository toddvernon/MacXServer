import Foundation

extension ImagePorts {
    /// The host port for a given transport plane.
    func port(for transport: LauncherTransport) -> UInt16 {
        switch transport {
        case .telnet: return telnet
        case .ssh:    return ssh
        case .helios: return helios
        }
    }
}

/// The on-disk document: `{ "machines": [ ... ] }`. A wrapper (rather than a bare
/// top-level array) so the file can grow sibling keys later without a format
/// break. See MACHINE_MANAGER_REFACTOR.md.
public struct MachinesFile: Codable, Equatable, Sendable {
    public var machines: [Machine]

    public init(machines: [Machine]) { self.machines = machines }

    /// Hosts we treat as "the bundled emulator's loopback" rather than a real LAN
    /// box. Drives migration's emulatedVM-vs-externalHost inference, and (public
    /// since 2026-07-09) the app side's loopback checks -- one list, not two
    /// drifting copies.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "0.0.0.0", "::1"]

    public static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    // MARK: - JSON

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Decode from JSON text. Throws on malformed JSON so callers can log it.
    public static func decode(_ text: String) throws -> MachinesFile {
        try JSONDecoder().decode(MachinesFile.self, from: Data(text.utf8))
    }

    /// Encode to pretty, stable-ordered JSON text.
    public func encoded() -> String {
        (try? String(data: Self.encoder().encode(self), encoding: .utf8)) ?? "{\n  \"machines\": []\n}"
    }
}

/// One-shot migration from the old flat `~/.macxserver-launchers` world (plus the
/// single `sparcplug.diskImagePath` preference) into the machines model. Each
/// launcher group becomes a machine -- loopback host → the bundled emulated VM,
/// anything else → an external host -- and a bundled machine is always present
/// even when the old launchers named none.
public enum MachineMigrator {
    public static func migrate(launchers: LauncherFile, bundledImagePath: String) -> [Machine] {
        var machines: [Machine] = []

        for group in launchers.groups() {
            guard let first = group.entries.first else { continue }
            let loopback = MachinesFile.isLoopback(first.host)
            let kind: MachineKind = loopback ? .emulatedVM : .externalHost
            let os: MachineOS? = loopback ? .solaris26 : nil
            let machineTransport = first.transport
            // File-browser entries don't migrate: Admin Agents > File
            // Transfer covers them automatically now. Per-launcher DISPLAY
            // overrides don't either -- the machine's DISPLAY is the only
            // level since 2026-07-07 (the group default already lands there).
            let launchers = group.entries.filter { !$0.fileBrowser }.map { entry -> MachineLauncher in
                MachineLauncher(
                    name: entry.name,
                    command: entry.command.isEmpty ? nil : entry.command,
                    // Only pin a transport when it differs from the machine's.
                    // (Legacy verbose doesn't migrate: the progress window is a
                    // launch-time gesture now, not launcher config.)
                    transport: entry.transport == machineTransport ? nil : entry.transport)
            }
            machines.append(Machine(
                name: group.label, kind: kind, os: os,
                host: first.host, user: first.user, transport: machineTransport,
                display: first.display,
                // The password is machine-level now (one credential per
                // user@host); the old file carried it per-entry, so take the
                // first one set.
                password: group.entries.compactMap(\.password).first { !$0.isEmpty },
                ports: portsFor(kind: kind, os: os, transport: machineTransport, port: first.port),
                imagePath: (loopback && !bundledImagePath.isEmpty) ? bundledImagePath : nil,
                launchers: launchers))
        }
        return machines
    }

    /// The machines we ship: one bundled fixture per guest OS, imageless AND
    /// user-less (the user attaches a disk image, then the first-run flow
    /// creates their login and fills `user`). Seeding a user here would write
    /// a lie for anyone who isn't the developer -- the empty user is the
    /// signal the first-run "add a user" step keys on (FIRST_RUN_EXPERIENCE.md).
    /// Stable identity is the `bundled` flag plus `os`, so `ensuringBundled`
    /// never duplicates a fixture the user has already set up. All the per-OS
    /// behavior (ports, boot command, halt) derives from `os`, so this stays
    /// a terse list.
    public static func bundledFixtures() -> [Machine] {
        MachineOS.allCases.map { os in
            Machine(name: os.displayName, kind: .emulatedVM, os: os, bundled: true,
                    host: "127.0.0.1", user: "", transport: .helios,
                    display: "10.0.2.2:0", imagePath: nil,
                    launchers: defaultLaunchers(for: os))
        }
    }

    /// The full launcher seed for a bundled fixture: the color-xterm palette
    /// first, then the per-OS curated apps. One-shot seed data -- once a
    /// fixture exists, its launchers live in machines.json and are edited
    /// there.
    public static func defaultLaunchers(for os: MachineOS) -> [MachineLauncher] {
        defaultXtermLaunchers + curatedAppLaunchers(for: os)
    }

    /// The color-xterm set every bundled fixture starts with (mirrors Todd's
    /// curated set on the real hosts), so a freshly-attached guest has
    /// something to click immediately. Helios transport needs no password.
    /// Each xterm cascades +80+55 from the previous (about 6% of the nominal
    /// 1280x900 logical root) so launching several doesn't stack them.
    public static let defaultXtermLaunchers: [MachineLauncher] = [
        ("xterm cyan",   "cyan",    "yellow"),
        ("xterm green",  "#7ec97e", "#f0c674"),
        ("xterm blue",   "#6ab8ff", "#f0c674"),
        ("xterm amber",  "#e5c07b", "#6ab8ff"),
        ("xterm purple", "#c792ea", "#f0c674"),
        ("xterm orange", "#ff9966", "#7ec97e"),
        ("xterm mint",   "#95efaf", "#ff9966"),
    ].enumerated().map { (i, c: (name: String, fg: String, cursor: String)) -> MachineLauncher in
        let quote = { (c: String) in c.hasPrefix("#") ? "\"\(c)\"" : c }
        return MachineLauncher(
            name: c.name,
            command: "xterm -sb -bg black -fg \(quote(c.fg)) -cr \(quote(c.cursor)) "
                + "-geometry 100x40+\(30 + 80 * i)+\(30 + 55 * i)")
    }

    /// Per-OS curated app launchers: the apps verified working on each guest
    /// image (tested by hand, 2026-07-28). Ordering: alphabetical, except
    /// Solaris puts its CDE apps between the xterms and the classic X apps.
    /// Absolute paths on purpose -- the daemon's PATH is not the user's.
    /// Each app takes its position from `appScatter` so no two seed
    /// launchers land on the same spot. maze parses args with getopt
    /// (single-letter flags only), so it gets `-g`; everything else takes
    /// the standard toolkit `-geometry`.
    public static func curatedAppLaunchers(for os: MachineOS) -> [MachineLauncher] {
        let commands: [String]
        switch os {
        case .solaris26:
            commands = ["dtcalc", "dtfile", "dtmail", "dtpad -standAlone", "dtterm"]
                .map { "/usr/dt/bin/\($0)" }
                + ["bitmap", "oclock", "xbiff", "xcalc", "xclipboard", "xclock",
                   "xlogo", "xman"]
                .map { "/usr/openwin/bin/\($0)" }
        case .sunos414:
            commands = ["dogs", "ico", "maze", "motifanim", "oclock", "periodic",
                        "puzzle", "xcalc", "xclipboard", "xclock", "xeyes",
                        "xfontsel", "xman", "xmeditor", "xmfonts", "xmforc",
                        "xmlist", "xmmove"]
                .map { "/usr/bin/X11/\($0)" }
        case .netbsd:
            commands = ["bitmap", "ico", "uxterm", "xcalc", "xclock", "xditview",
                        "xedit", "xeyes", "xman", "xmore"]
                .map { "/usr/X11R7/bin/\($0)" }
        }
        return commands.enumerated().map { i, command in
            let binary = command.components(separatedBy: " ")[0]
            let name = (binary as NSString).lastPathComponent
            let flag = name == "maze" ? "-g" : "-geometry"
            let spot = appScatter[i]
            return MachineLauncher(name: name,
                                   command: "\(command) \(flag) +\(spot.x)+\(spot.y)")
        }
    }

    /// Hand-picked pseudo-random spread over the nominal 1280x900 logical
    /// root, consumed in list order by `curatedAppLaunchers`. No two entries
    /// within ~90px of each other, and everything stays inside x<=840 y<=560
    /// so positions survive the smaller display presets. Long enough for the
    /// longest curated list (SunOS 4.1.4, 18 apps) with room to grow.
    static let appScatter: [(x: Int, y: Int)] = [
        (620, 80), (140, 420), (760, 300), (330, 180), (60, 250),
        (520, 460), (830, 140), (250, 540), (450, 60), (700, 500),
        (90, 90), (560, 250), (360, 380), (800, 420), (180, 160),
        (640, 380), (280, 300), (440, 550), (740, 60), (40, 520),
    ]

    /// Guarantee every bundled fixture is present, injecting only the missing ones
    /// (matched by `bundled && os`, so an already-attached fixture is preserved).
    /// Returns nil when nothing was added, so the caller can skip a needless write.
    public static func ensuringBundled(_ machines: [Machine]) -> [Machine]? {
        var result = machines
        var added = false
        for fixture in bundledFixtures()
        where !machines.contains(where: { $0.bundled && $0.os == fixture.os }) {
            result.append(fixture)
            added = true
        }
        return added ? result : nil
    }

    /// Port triple for a migrated machine, or nil to derive (the common case).
    /// Emulated always derives (tracks its OS block). External derives too unless
    /// the entry used a non-standard port for its transport, in which case we pin
    /// just that plane -- so a plain helios/ssh/telnet box carries no ports block.
    static func portsFor(kind: MachineKind, os: MachineOS?,
                         transport: LauncherTransport, port: UInt16) -> ImagePorts? {
        if kind == .emulatedVM { return nil }   // derive from os / defaults
        let standard = ImagePorts(telnet: 23, ssh: 22, helios: 2125)
        if port == standard.port(for: transport) { return nil }   // nothing to override
        var ports = standard
        switch transport {
        case .telnet: ports.telnet = port
        case .ssh:    ports.ssh = port
        case .helios: ports.helios = port
        }
        return ports
    }
}

/// Loads the machines file, migrating from the legacy launchers file on first
/// run. AppDelegate wiring lands in P1b; this is the persistence surface.
public enum MachinesFileLoader {
    public static let defaultPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".macxserver-machines.json")
    }()

    /// Read + decode the machines file. If it's absent, migrate from the launcher
    /// file at `launchersPath` (parsing it if present) + the bundled image path,
    /// write the result, and return it. On a decode error, log and return empty
    /// (never clobber the user's file).
    ///
    /// The legacy launchers file is DELETED once machines.json exists (both
    /// right after a successful migration write and, for installs migrated
    /// before 2026-07-28, as a sweep on a normal load): nothing reads or
    /// seeds it anymore, so leaving it behind just parks a stale copy of the
    /// user's launchers in their home directory forever.
    public static func loadOrMigrate(
        path: String = defaultPath,
        launchersPath: String = LauncherFileLoader.defaultPath,
        bundledImagePath: String,
        log: ServerLogSink? = nil
    ) -> MachinesFile {
        let fm = FileManager.default
        func removeLegacyLaunchersFile() {
            guard fm.fileExists(atPath: launchersPath) else { return }
            do {
                try fm.removeItem(atPath: launchersPath)
                log?.log("machines: removed legacy launchers file \(launchersPath)")
            } catch {
                log?.log("machines: couldn't remove legacy launchers file: \(error)")
            }
        }
        if !fm.fileExists(atPath: path) {
            let launchers: LauncherFile = (try? String(contentsOfFile: launchersPath, encoding: .utf8))
                .map { LauncherFile.parse($0) } ?? LauncherFile(entries: [], warnings: [])
            var machines = MachineMigrator.migrate(
                launchers: launchers, bundledImagePath: bundledImagePath)
            machines = MachineMigrator.ensuringBundled(machines) ?? machines
            let file = MachinesFile(machines: machines)
            do {
                try file.encoded().write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("machines: migrated \(launchers.entries.count) launcher entries -> \(path)")
                removeLegacyLaunchersFile()
            } catch {
                log?.log("machines: migration write failed: \(error)")
            }
            return file
        }
        removeLegacyLaunchersFile()
        do {
            let file = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
            // Existing installs predate the bundled fixtures; inject any that are
            // missing and persist so their ids are stable from here on.
            guard let grown = MachineMigrator.ensuringBundled(file.machines)
            else { return file }
            let updated = MachinesFile(machines: grown)
            do {
                try updated.encoded().write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("machines: added \(grown.count - file.machines.count) bundled fixture(s) -> \(path)")
            } catch {
                log?.log("machines: bundled-fixture write failed: \(error)")
            }
            return updated
        } catch {
            log?.log("machines: read/decode failed (\(error)); ignoring file")
            return MachinesFile(machines: [])
        }
    }
}
