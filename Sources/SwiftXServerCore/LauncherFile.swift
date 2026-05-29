import Foundation

public struct LauncherEntry: Equatable, Sendable {
    public let name: String
    public let host: String
    public let command: String
    public let user: String
    public let port: UInt16
    public let verbose: Bool
    public let loginPrompt: String
    public let passwordPrompt: String
    public let shellPrompt: String
    /// Optional cleartext password from the launcher file. nil = none given,
    /// so the launch flow falls back to the macOS Keychain (and prompts if
    /// absent). Putting a password here is a development convenience to avoid
    /// re-typing it every launch; it lives in a plaintext dotfile, so it's
    /// not recommended on shared machines.
    public let password: String?

    public init(name: String, host: String, command: String, user: String,
                port: UInt16 = 23, verbose: Bool = false,
                loginPrompt: String = "ogin:",
                passwordPrompt: String = "assword:",
                shellPrompt: String = "$ ",
                password: String? = nil) {
        self.name = name; self.host = host; self.command = command
        self.user = user; self.port = port; self.verbose = verbose
        self.loginPrompt = loginPrompt; self.passwordPrompt = passwordPrompt
        self.shellPrompt = shellPrompt; self.password = password
    }
}

public struct LauncherFile: Sendable {
    public let entries: [LauncherEntry]

    public static func parse(_ text: String) -> LauncherFile {
        var entries: [LauncherEntry] = []
        var currentName: String?
        var pairs: [String: String] = [:]

        func flush() {
            guard let name = currentName,
                  let host = pairs["host"],
                  let user = pairs["user"],
                  let command = pairs["command"] else {
                currentName = nil; pairs.removeAll(); return
            }
            let port = pairs["port"].flatMap { UInt16($0) } ?? 23
            let verbose = ["true", "yes", "1"].contains(pairs["verbose"]?.lowercased() ?? "")
            let entry = LauncherEntry(
                name: name, host: host, command: command, user: user,
                port: port, verbose: verbose,
                loginPrompt: pairs["login_prompt"] ?? "ogin:",
                passwordPrompt: pairs["password_prompt"] ?? "assword:",
                shellPrompt: pairs["shell_prompt"] ?? "$ ",
                password: pairs["password"]
            )
            entries.append(entry)
            currentName = nil; pairs.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") { continue }
            if trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") {
                flush()
                let start = trimmed.index(after: trimmed.startIndex)
                currentName = String(trimmed[start..<close]).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty { pairs[key] = val }
        }
        flush()
        return LauncherFile(entries: entries)
    }
}

public enum LauncherFileLoader {
    public static let defaultPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".swiftx-launchers")
    }()

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
