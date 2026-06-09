import Foundation

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
    /// Hostname or address to telnet into.
    public let host: String
    /// Command line to run on the remote host (sets DISPLAY and launches the X client).
    public let command: String
    /// Login username for the telnet session.
    public let user: String
    /// Telnet port. Defaults to 23.
    public let port: UInt16
    /// Show the per-launch progress window with the telnet transcript.
    public let verbose: Bool
    /// Substring the telnet flow waits for before sending the username.
    public let loginPrompt: String
    /// Substring the telnet flow waits for before sending the password.
    public let passwordPrompt: String
    /// Substring that marks the remote shell is ready for the command.
    public let shellPrompt: String
    /// Optional cleartext password from the launcher file. nil = none given,
    /// so the launch flow falls back to the macOS Keychain (and prompts if
    /// absent). Putting a password here is a development convenience to avoid
    /// re-typing it every launch; it lives in a plaintext dotfile, so it's
    /// not recommended on shared machines.
    public let password: String?

    /// Build an entry. Prompts and port carry the documented defaults when omitted.
    public init(name: String, group: String, host: String, command: String, user: String,
                port: UInt16 = 23, verbose: Bool = false,
                loginPrompt: String = "ogin:",
                passwordPrompt: String = "assword:",
                shellPrompt: String = "$ ",
                password: String? = nil) {
        self.name = name; self.group = group
        self.host = host; self.command = command
        self.user = user; self.port = port; self.verbose = verbose
        self.loginPrompt = loginPrompt; self.passwordPrompt = passwordPrompt
        self.shellPrompt = shellPrompt; self.password = password
    }
}

/// The parsed contents of `~/.macxserver-launchers`: the flat list of
/// launcher entries in file order.
public struct LauncherFile: Sendable {
    /// Every entry parsed from the file, in file order.
    public let entries: [LauncherEntry]

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

            guard let host = merged["host"],
                  let user = merged["user"],
                  let command = merged["command"] else { continue }

            let port = merged["port"].flatMap { UInt16($0) } ?? 23
            let verbose = ["true", "yes", "1"].contains(merged["verbose"]?.lowercased() ?? "")
            entries.append(LauncherEntry(
                name: name, group: group,
                host: host, command: command, user: user,
                port: port, verbose: verbose,
                loginPrompt: merged["login_prompt"] ?? "ogin:",
                passwordPrompt: merged["password_prompt"] ?? "assword:",
                shellPrompt: merged["shell_prompt"] ?? "$ ",
                password: merged["password"]
            ))
        }

        return LauncherFile(entries: entries)
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
            return LauncherFile.parse(text)
        } catch {
            log?.log("launchers: read failed: \(error)")
            return LauncherFile.parse(seed())
        }
    }
}
