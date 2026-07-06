import Foundation

/// Which remote-shell protocol the launcher drives. Telnet (the original
/// path) runs the IAC negotiation + login/password state machine in
/// TelnetLauncher; SSH (added 2026-06-12 for modern Linux/BSD boxes) just
/// spawns `/usr/bin/ssh` and lets it handle the protocol, key auth only;
/// Helios (added 2026-06-21, C7) runs the client via the Helios daemon's
/// `run_command` -- no prompt-scraping, no login-shell quirks, a clean exit
/// code, and no auth to manage. The least-brittle path once the daemon is up.
public enum LauncherTransport: String, Equatable, Sendable, Codable, CaseIterable {
    case telnet, ssh, helios
}

/// One launchable command parsed from `~/.macxserver-launchers`: a remote
/// host, the connection details, and the X client command to run there.
public struct LauncherEntry: Equatable, Sendable {
    /// Submenu label (the part after `/` in `[host-key/item-name]`, or the
    /// whole section name for legacy entries).
    public let name: String
    /// Top-level menu label. For `[host:X]` + `[X/item]` entries this is the
    /// host key. For legacy `[name]` entries it's the leftmost dotted part of
    /// the entry's `host` field (`u5.example.com` → `u5`).
    public let group: String
    /// Hostname or address to connect to.
    public let host: String
    /// Command line to run on the remote host (sets DISPLAY and launches the X client).
    public let command: String
    /// Login username for the remote session.
    public let user: String
    /// Remote port. Default 23 for telnet, 22 for ssh.
    public let port: UInt16
    /// Show the per-launch progress window with the session transcript.
    public let verbose: Bool
    /// Add a "Files…" item next to this launcher that opens a Helios file
    /// browser scoped to `user`'s home directory. Only meaningful for
    /// `transport = helios` (the daemon is the file-transfer mechanism); the
    /// parser warns and the menu ignores it on telnet/ssh launchers.
    public let fileBrowser: Bool
    /// Substring the telnet flow waits for before sending the username. (Unused for ssh.)
    public let loginPrompt: String
    /// Substring the telnet flow waits for before sending the password. (Unused for ssh.)
    public let passwordPrompt: String
    /// Substring that marks the remote shell is ready for the command. (Unused for ssh.)
    public let shellPrompt: String
    /// Optional cleartext password from the launcher file. nil = none given,
    /// so the launch flow falls back to the macOS Keychain (and prompts if
    /// absent). Putting a password here is a development convenience to avoid
    /// re-typing it every launch; it lives in a plaintext dotfile, so it's
    /// not recommended on shared machines. Ignored when `transport = ssh`:
    /// ssh is keys-only (BatchMode), so we never prompt or read Keychain.
    public let password: String?
    /// Remote-shell protocol. Default `.telnet` keeps the original behavior
    /// for every existing launcher; set `transport = ssh` on a host block to
    /// use ssh (key-based auth, no password injection).
    public let transport: LauncherTransport
    /// Optional override for the `DISPLAY` value the wrapper exports before
    /// running `command`. nil means "auto-compute from the Mac's primary
    /// LAN IPv4 + the server's display number," which is the right answer
    /// for any host that reaches the Mac directly. Set this when the host
    /// can't see the Mac at its LAN IP -- the canonical case is a QEMU/slirp
    /// guest, where the Mac is reachable as `10.0.2.2:0` from inside the
    /// VM regardless of what the Mac's real LAN IP is.
    public let display: String?

    /// Build one entry from an already-merged key/value dict (host-block or
    /// machine-block defaults ∪ per-item overrides). Returns nil when the item
    /// lacks the minimum -- host + user, and a command unless it's a filebrowser
    /// item (whose menu item opens the browser rather than launching anything).
    /// Appends non-fatal warnings (ssh-with-password, filebrowser-on-non-helios)
    /// to `warnings`. Shared by `LauncherFile` and `MachinesFile` so both parse
    /// launcher items identically.
    public static func build(merged: [String: String], name: String, group: String,
                             warnings: inout [String]) -> LauncherEntry? {
        let fileBrowser = ["true", "yes", "1"].contains(merged["filebrowser"]?.lowercased() ?? "")
        guard let host = merged["host"], let user = merged["user"] else { return nil }
        let command = merged["command"] ?? ""
        if command.isEmpty && !fileBrowser { return nil }

        let transport = LauncherTransport(rawValue: merged["transport"]?.lowercased() ?? "")
            ?? .telnet
        let port = merged["port"].flatMap { UInt16($0) }
            ?? (transport == .ssh ? 22 : transport == .helios ? 2125 : 23)
        let verbose = ["true", "yes", "1"].contains(merged["verbose"]?.lowercased() ?? "")
        if transport == .ssh, let pw = merged["password"], !pw.isEmpty {
            warnings.append("'\(group)/\(name)' has transport=ssh and a "
                + "password set; ssh is keys-only here, password ignored")
        }
        if fileBrowser && transport != .helios {
            warnings.append("'\(group)/\(name)' has filebrowser=true but "
                + "transport=\(transport.rawValue); the file browser only works over "
                + "transport=helios, so this key can't browse (wrong transport)")
        }
        return LauncherEntry(
            name: name, group: group,
            host: host, command: command, user: user,
            port: port, verbose: verbose, fileBrowser: fileBrowser,
            loginPrompt: merged["login_prompt"] ?? "ogin:",
            passwordPrompt: merged["password_prompt"] ?? "assword:",
            shellPrompt: merged["shell_prompt"] ?? "$ ",
            password: merged["password"],
            transport: transport,
            display: merged["display"])
    }

    /// Build an entry. Prompts and port carry the documented defaults when omitted.
    public init(name: String, group: String, host: String, command: String, user: String,
                port: UInt16 = 23, verbose: Bool = false, fileBrowser: Bool = false,
                loginPrompt: String = "ogin:",
                passwordPrompt: String = "assword:",
                shellPrompt: String = "$ ",
                password: String? = nil,
                transport: LauncherTransport = .telnet,
                display: String? = nil) {
        self.name = name; self.group = group
        self.host = host; self.command = command
        self.user = user; self.port = port; self.verbose = verbose
        self.fileBrowser = fileBrowser
        self.loginPrompt = loginPrompt; self.passwordPrompt = passwordPrompt
        self.shellPrompt = shellPrompt; self.password = password
        self.transport = transport
        self.display = display
    }
}

/// The parsed contents of `~/.macxserver-launchers`: the flat list of
/// launcher entries in file order.
public struct LauncherFile: Sendable {
    /// Every entry parsed from the file, in file order.
    public let entries: [LauncherEntry]
    /// Non-fatal issues the parser noticed (e.g. ssh entry with a password
    /// set, since ssh is keys-only). LauncherFileLoader emits these to the
    /// log sink so they're visible without forcing a parse error.
    public let warnings: [String]

    /// Entries grouped by `group`, preserving first-appearance order of groups
    /// and the file order of entries within each group. The menu builder uses
    /// this to construct one submenu per group.
    public func groups() -> [(label: String, entries: [LauncherEntry])] {
        var result: [(label: String, entries: [LauncherEntry])] = []
        var index: [String: Int] = [:]
        for entry in entries {
            if let i = index[entry.group] {
                result[i].entries.append(entry)
            } else {
                index[entry.group] = result.count
                result.append((label: entry.group, entries: [entry]))
            }
        }
        return result
    }

    /// Parse launcher-file text into entries. Honors `[host:X]` default
    /// blocks merged into `[X/item]` entries plus legacy `[name]` entries;
    /// skips blank/comment lines and entries missing host/user/command.
    public static func parse(_ text: String) -> LauncherFile {
        var hostBlocks: [String: [String: String]] = [:]
        var pendingItems: [(section: String, pairs: [String: String])] = []
        var currentSection: String?
        var pairs: [String: String] = [:]
        var warnings: [String] = []

        func flush() {
            guard let section = currentSection else { return }
            if section.hasPrefix("host:") {
                let key = String(section.dropFirst("host:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { hostBlocks[key] = pairs }
            } else {
                pendingItems.append((section, pairs))
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

        var entries: [LauncherEntry] = []
        for item in pendingItems {
            let section = item.section
            let merged: [String: String]
            let name: String
            let group: String

            if let slash = section.firstIndex(of: "/") {
                let key = String(section[..<slash])
                    .trimmingCharacters(in: .whitespaces)
                let itemName = String(section[section.index(after: slash)...])
                    .trimmingCharacters(in: .whitespaces)
                guard let defaults = hostBlocks[key] else { continue }
                var m = defaults
                for (k, v) in item.pairs { m[k] = v }
                merged = m
                name = itemName
                group = key
            } else {
                merged = item.pairs
                name = section
                let host = merged["host"] ?? ""
                group = host.split(separator: ".").first.map(String.init) ?? host
            }

            // A normal launcher needs a command; a filebrowser entry doesn't (its
            // menu item opens the browser, it doesn't launch anything). The shared
            // builder enforces that and returns nil for an unusable item.
            if let entry = LauncherEntry.build(merged: merged, name: name, group: group,
                                               warnings: &warnings) {
                entries.append(entry)
            }
        }

        return LauncherFile(entries: entries, warnings: warnings)
    }
}

/// Loads (and seeds on first run) the launcher file from disk.
public enum LauncherFileLoader {
    /// Default file location: `~/.macxserver-launchers`.
    public static let defaultPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".macxserver-launchers")
    }()

    /// Read and parse the launcher file. If it doesn't exist, write `seed()`
    /// to disk first, then parse. Falls back to parsing the seed on I/O error.
    public static func loadOrSeed(
        path: String = defaultPath,
        seed: @autoclosure () -> String,
        log: ServerLogSink? = nil
    ) -> LauncherFile {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let content = seed()
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("launchers: seeded \(path)")
            } catch {
                log?.log("launchers: seed write failed: \(error)")
                return LauncherFile.parse(content)
            }
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let parsed = LauncherFile.parse(text)
            for w in parsed.warnings { log?.log("launchers: \(w)") }
            return parsed
        } catch {
            log?.log("launchers: read failed: \(error)")
            return LauncherFile.parse(seed())
        }
    }
}
