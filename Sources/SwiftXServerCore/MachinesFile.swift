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
    /// box. Drives migration's emulatedVM-vs-externalHost inference.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "0.0.0.0", "::1"]

    static func isLoopback(_ host: String) -> Bool {
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
    public static func migrate(launchers: LauncherFile, bundledImagePath: String,
                               bundledUser: String) -> [Machine] {
        var machines: [Machine] = []

        for group in launchers.groups() {
            guard let first = group.entries.first else { continue }
            let loopback = MachinesFile.isLoopback(first.host)
            let kind: MachineKind = loopback ? .emulatedVM : .externalHost
            let os: MachineOS? = loopback ? .solaris26 : nil
            let machineTransport = first.transport
            let launchers = group.entries.map { entry -> MachineLauncher in
                MachineLauncher(
                    name: entry.name,
                    command: entry.command.isEmpty ? nil : entry.command,
                    // Only pin a transport when it differs from the machine's.
                    transport: entry.transport == machineTransport ? nil : entry.transport,
                    verbose: entry.verbose,
                    fileBrowser: entry.fileBrowser,
                    display: entry.display == first.display ? nil : entry.display,
                    password: entry.password)
            }
            machines.append(Machine(
                name: group.label, kind: kind, os: os,
                host: first.host, user: first.user, transport: machineTransport,
                display: first.display,
                ports: portsFor(kind: kind, os: os, transport: machineTransport, port: first.port),
                imagePath: (loopback && !bundledImagePath.isEmpty) ? bundledImagePath : nil,
                launchers: launchers))
        }
        return machines
    }

    /// The machines we ship: one bundled fixture per guest OS, imageless (the user
    /// attaches a disk image, then runs it). Stable identity is the `bundled` flag
    /// plus `os`, so `ensuringBundled` never duplicates a fixture the user has
    /// already attached an image to. All the per-OS behavior (ports, boot command,
    /// halt) derives from `os`, so this stays a terse list.
    public static func bundledFixtures(user: String) -> [Machine] {
        MachineOS.allCases.map { os in
            Machine(name: os.displayName, kind: .emulatedVM, os: os, bundled: true,
                    host: "127.0.0.1", user: user, transport: .helios,
                    display: "10.0.2.2:0", imagePath: nil)
        }
    }

    /// Guarantee every bundled fixture is present, injecting only the missing ones
    /// (matched by `bundled && os`, so an already-attached fixture is preserved).
    /// Returns nil when nothing was added, so the caller can skip a needless write.
    public static func ensuringBundled(_ machines: [Machine], user: String) -> [Machine]? {
        var result = machines
        var added = false
        for fixture in bundledFixtures(user: user)
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
    public static func loadOrMigrate(
        path: String = defaultPath,
        launchersPath: String = LauncherFileLoader.defaultPath,
        bundledImagePath: String,
        bundledUser: String,
        log: ServerLogSink? = nil
    ) -> MachinesFile {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let launchers: LauncherFile = (try? String(contentsOfFile: launchersPath, encoding: .utf8))
                .map { LauncherFile.parse($0) } ?? LauncherFile(entries: [], warnings: [])
            var machines = MachineMigrator.migrate(
                launchers: launchers, bundledImagePath: bundledImagePath, bundledUser: bundledUser)
            machines = MachineMigrator.ensuringBundled(machines, user: bundledUser) ?? machines
            let file = MachinesFile(machines: machines)
            do {
                try file.encoded().write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("machines: migrated \(launchers.entries.count) launcher entries -> \(path)")
            } catch {
                log?.log("machines: migration write failed: \(error)")
            }
            return file
        }
        do {
            let file = try MachinesFile.decode(String(contentsOfFile: path, encoding: .utf8))
            // Existing installs predate the bundled fixtures; inject any that are
            // missing and persist so their ids are stable from here on.
            guard let grown = MachineMigrator.ensuringBundled(file.machines, user: bundledUser)
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
