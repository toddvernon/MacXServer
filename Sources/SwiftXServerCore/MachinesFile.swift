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

/// Parsed contents of `~/.macxserver-machines`: the machines in file order, each
/// with its nested launcher commands. The format extends the launcher file --
/// `[machine:KEY]` blocks carry the machine identity + connection defaults, and
/// `[KEY/item]` blocks are that machine's launchers (identical shape to the old
/// launcher items, which inherit the machine block's host/user/transport/port).
/// See MACHINE_MANAGER_REFACTOR.md ("Launchers become a machine's sub-list").
public struct MachinesFile: Sendable {
    public let machines: [Machine]
    public let warnings: [String]

    /// Hosts we treat as "the bundled emulator's loopback" rather than a real LAN
    /// box. Drives migration's emulatedVM-vs-externalHost inference.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "0.0.0.0", "::1"]

    static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    // MARK: - Parse

    public static func parse(_ text: String) -> MachinesFile {
        var machineBlocks: [(key: String, pairs: [String: String])] = []
        var itemBlocks: [(section: String, pairs: [String: String])] = []
        var currentSection: String?
        var pairs: [String: String] = [:]
        var warnings: [String] = []

        func flush() {
            guard let section = currentSection else { return }
            if section.hasPrefix("machine:") {
                let key = String(section.dropFirst("machine:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { machineBlocks.append((key, pairs)) }
            } else if section.contains("/") {
                itemBlocks.append((section, pairs))
            }
            currentSection = nil
            pairs = [:]
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") { continue }
            if trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") {
                flush()
                let start = trimmed.index(after: trimmed.startIndex)
                currentSection = String(trimmed[start..<close])
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty { pairs[key] = val }
        }
        flush()

        // Group item blocks by their machine key (the part before the slash).
        var itemsByMachine: [String: [(name: String, pairs: [String: String])]] = [:]
        for item in itemBlocks {
            guard let slash = item.section.firstIndex(of: "/") else { continue }
            let key = String(item.section[..<slash]).trimmingCharacters(in: .whitespaces)
            let name = String(item.section[item.section.index(after: slash)...])
                .trimmingCharacters(in: .whitespaces)
            itemsByMachine[key, default: []].append((name, item.pairs))
        }

        var machines: [Machine] = []
        for block in machineBlocks {
            let p = block.pairs
            let inferredKind: MachineKind = p["image"] != nil ? .emulatedVM : .externalHost
            let kind = p["kind"].flatMap { MachineKind(rawValue: $0) } ?? inferredKind
            let os = p["os"].flatMap { MachineOS(rawValue: $0) }
            let transport = p["transport"].flatMap { LauncherTransport(rawValue: $0.lowercased()) }
                ?? .helios
            let host = p["host"] ?? (kind == .emulatedVM ? "127.0.0.1" : "")
            let user = p["user"] ?? ""
            let ports = resolvePorts(p, kind: kind, os: os, transport: transport)
            let connection = MachineConnection(host: host, user: user, ports: ports,
                                               transport: transport, display: p["display"])
            let image = p["image"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

            // Build this machine's launchers, inheriting connection defaults.
            var launchers: [LauncherEntry] = []
            for item in itemsByMachine[block.key] ?? [] {
                let itemTransport = item.pairs["transport"].flatMap { LauncherTransport(rawValue: $0.lowercased()) }
                    ?? transport
                var merged: [String: String] = [
                    "host": host, "user": user,
                    "transport": itemTransport.rawValue,
                    "port": String(ports.port(for: itemTransport)),
                ]
                if let d = p["display"] { merged["display"] = d }
                for (k, v) in item.pairs { merged[k] = v }
                if let entry = LauncherEntry.build(merged: merged, name: item.name,
                                                   group: block.key, warnings: &warnings) {
                    launchers.append(entry)
                }
            }

            machines.append(Machine(
                id: p["id"].flatMap { UUID(uuidString: $0) } ?? UUID(),
                key: block.key, name: p["name"] ?? block.key,
                kind: kind, os: os, connection: connection, launchers: launchers,
                image: image, memoryMB: p["memory"].flatMap { Int($0) } ?? 128,
                macAddress: p["mac"],
                networkMode: p["networkmode"].flatMap { MachineNetworkMode(rawValue: $0) } ?? .slirp))
        }

        return MachinesFile(machines: machines, warnings: warnings)
    }

    /// Resolve the port triple. Emulated VMs default to the OS's historical block;
    /// external hosts to the standard 23/22/2125. `port` overrides the transport's
    /// plane; `telnet_port`/`ssh_port`/`helios_port` override individually.
    static func resolvePorts(_ p: [String: String], kind: MachineKind,
                             os: MachineOS?, transport: LauncherTransport) -> ImagePorts {
        let base: ImagePorts = (kind == .emulatedVM ? (os?.defaultPorts ?? .solaris26)
                                                     : ImagePorts(telnet: 23, ssh: 22, helios: 2125))
        var telnet = base.telnet, ssh = base.ssh, helios = base.helios
        if let v = p["telnet_port"].flatMap({ UInt16($0) }) { telnet = v }
        if let v = p["ssh_port"].flatMap({ UInt16($0) })    { ssh = v }
        if let v = p["helios_port"].flatMap({ UInt16($0) }) { helios = v }
        if let v = p["port"].flatMap({ UInt16($0) }) {
            switch transport {
            case .telnet: telnet = v
            case .ssh:    ssh = v
            case .helios: helios = v
            }
        }
        return ImagePorts(telnet: telnet, ssh: ssh, helios: helios)
    }

    // MARK: - Serialize

    /// Render machines back to file text. Launchers are written fully explicit
    /// (own host/user/transport/port) so a machine-written file round-trips
    /// exactly; hand-written files may instead lean on machine-block inheritance.
    public static func serialize(_ machines: [Machine]) -> String {
        var out = "# macXserver machines -- generated; hand-edits preserved on reparse.\n"
        for m in machines {
            out += "\n[machine:\(m.key)]\n"
            out += "  id          = \(m.id.uuidString)\n"
            out += "  name        = \(m.name)\n"
            out += "  kind        = \(m.kind.rawValue)\n"
            if let os = m.os { out += "  os          = \(os.rawValue)\n" }
            out += "  host        = \(m.connection.host)\n"
            if !m.connection.user.isEmpty { out += "  user        = \(m.connection.user)\n" }
            out += "  transport   = \(m.connection.transport.rawValue)\n"
            out += "  telnet_port = \(m.connection.ports.telnet)\n"
            out += "  ssh_port    = \(m.connection.ports.ssh)\n"
            out += "  helios_port = \(m.connection.ports.helios)\n"
            if let d = m.connection.display { out += "  display     = \(d)\n" }
            if m.kind == .emulatedVM {
                if let img = m.image { out += "  image       = \(img.path)\n" }
                out += "  memory      = \(m.memoryMB)\n"
                if let mac = m.macAddress { out += "  mac         = \(mac)\n" }
                out += "  networkmode = \(m.networkMode.rawValue)\n"
            }
            for e in m.launchers {
                out += "\n[\(m.key)/\(e.name)]\n"
                out += "  host        = \(e.host)\n"
                out += "  user        = \(e.user)\n"
                out += "  transport   = \(e.transport.rawValue)\n"
                out += "  port        = \(e.port)\n"
                if !e.command.isEmpty { out += "  command     = \(e.command)\n" }
                if e.fileBrowser { out += "  filebrowser = true\n" }
                if e.verbose { out += "  verbose     = true\n" }
                if let d = e.display { out += "  display     = \(d)\n" }
                if let pw = e.password { out += "  password    = \(pw)\n" }
            }
        }
        return out
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
        var haveBundled = false

        for group in launchers.groups() {
            guard let first = group.entries.first else { continue }
            let loopback = MachinesFile.isLoopback(first.host)
            let kind: MachineKind = loopback ? .emulatedVM : .externalHost
            let os: MachineOS? = loopback ? .solaris26 : nil
            let ports = portsFor(kind: kind, os: os, transport: first.transport, port: first.port)
            let connection = MachineConnection(host: first.host, user: first.user,
                                               ports: ports, transport: first.transport,
                                               display: first.display)
            let image: URL? = (loopback && !bundledImagePath.isEmpty)
                ? URL(fileURLWithPath: (bundledImagePath as NSString).expandingTildeInPath) : nil
            machines.append(Machine(key: group.label, name: group.label, kind: kind, os: os,
                                    connection: connection, launchers: group.entries, image: image))
            if loopback { haveBundled = true }
        }

        if !haveBundled {
            let image: URL? = bundledImagePath.isEmpty ? nil
                : URL(fileURLWithPath: (bundledImagePath as NSString).expandingTildeInPath)
            let connection = MachineConnection(host: "127.0.0.1", user: bundledUser,
                                               ports: .solaris26, transport: .helios,
                                               display: "10.0.2.2:0")
            machines.insert(Machine(key: "solaris", name: "Solaris 2.6", kind: .emulatedVM,
                                    os: .solaris26, connection: connection, launchers: [],
                                    image: image), at: 0)
        }
        return machines
    }

    /// Port triple for a migrated machine: the OS block for emulated, else the
    /// standard defaults with the entry's own port dropped into its transport.
    static func portsFor(kind: MachineKind, os: MachineOS?,
                         transport: LauncherTransport, port: UInt16) -> ImagePorts {
        if kind == .emulatedVM { return os?.defaultPorts ?? .solaris26 }
        var ports = ImagePorts(telnet: 23, ssh: 22, helios: 2125)
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
        (NSHomeDirectory() as NSString).appendingPathComponent(".macxserver-machines")
    }()

    /// Read + parse the machines file. If it's absent, migrate from the launcher
    /// file at `launchersPath` (parsing it if present) + the bundled image path,
    /// write the result, and return it.
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
            let machines = MachineMigrator.migrate(launchers: launchers,
                                                   bundledImagePath: bundledImagePath,
                                                   bundledUser: bundledUser)
            let content = MachinesFile.serialize(machines)
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("machines: migrated \(launchers.entries.count) launcher entries -> \(path)")
            } catch {
                log?.log("machines: migration write failed: \(error)")
            }
            return MachinesFile.parse(content)
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let parsed = MachinesFile.parse(text)
            for w in parsed.warnings { log?.log("machines: \(w)") }
            return parsed
        } catch {
            log?.log("machines: read failed: \(error)")
            return MachinesFile(machines: [], warnings: [])
        }
    }
}
