import Foundation

// User-editable swift-x resources file format. See THEMES.md for the
// design. Quick reminder:
//
//   [swiftx-config]
//   theme: quickplot
//
//   [global]
//   ! resources applied regardless of theme
//   ...
//
//   [theme:quickplot]
//   ! resources for this theme
//   ...
//
// One file, multiple themes, one active. Active theme = the `theme:`
// value in [swiftx-config], default `quickplot` if missing. The bytes
// we publish on RESOURCE_MANAGER are `[global]` ∪ `[theme:<active>]`.
//
// Parser is one-way (text → struct). We never serialize back to disk;
// dirty tracking in the editor saves the user's raw buffer verbatim
// instead, which preserves comments / blank lines / key order exactly.

public struct ResourceFile {

    /// What kind of section header a `[...]` line names.
    public enum SectionKind: Equatable {
        case config             // [swiftx-config]
        case global             // [global]
        case theme(String)      // [theme:NAME]
        case unknown(String)    // anything we don't recognize; preserved but unused
    }

    /// A parsed section. `bodyLines` excludes the header itself; comments
    /// and blank lines are preserved in order so we can publish them too
    /// (Xrm ignores `!` and blank lines, but the user's formatting stays
    /// readable on the wire if they ever dump the property).
    public struct Section {
        public let kind: SectionKind
        public let bodyLines: [String]
    }

    public let sections: [Section]

    /// Value of `[swiftx-config].theme`. Defaults to `quickplot` when
    /// the file has no config section or the key is missing.
    public var activeTheme: String {
        for section in sections {
            if case .config = section.kind {
                for line in section.bodyLines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("!") { continue }
                    // `key: value` — split on first colon.
                    if let colon = trimmed.firstIndex(of: ":") {
                        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                        let value = trimmed[trimmed.index(after: colon)...]
                            .trimmingCharacters(in: .whitespaces)
                        if key == "theme" { return value }
                    }
                }
            }
        }
        return "quickplot"
    }

    /// Names of every theme found in the file, in declaration order.
    /// Useful for populating the editor's theme dropdown.
    public var themeNames: [String] {
        sections.compactMap { section in
            if case .theme(let name) = section.kind { return name }
            return nil
        }
    }

    /// Build the bytes to publish on the X root's RESOURCE_MANAGER
    /// property: concatenated body of `[global]` then `[theme:<active>]`,
    /// terminated with LF + NUL (the STRING-property convention u5 Xsun
    /// used). Comments and blank lines from the user's file pass through;
    /// Xrm ignores them. Unknown sections (`[swiftx-config]`, anything
    /// else) are NOT published.
    public func resourceManagerBytes() -> [UInt8] {
        var lines: [String] = []
        for section in sections {
            if case .global = section.kind {
                lines.append(contentsOf: section.bodyLines)
            }
        }
        let active = activeTheme
        for section in sections {
            if case .theme(let name) = section.kind, name == active {
                lines.append(contentsOf: section.bodyLines)
            }
        }
        let body = lines.joined(separator: "\n")
        return Array(body.utf8) + [0x0A, 0x00]
    }

    /// Parse the file content. Never throws — malformed lines outside a
    /// section get attached to a leading synthetic `.unknown("")`
    /// section; unrecognized section headers become `.unknown(name)` and
    /// are preserved so the editor's text-view round-trip stays lossless
    /// even though `resourceManagerBytes()` ignores them.
    public static func parse(_ text: String) -> ResourceFile {
        var sections: [Section] = []
        var currentKind: SectionKind = .unknown("")    // lines before any header land here
        var currentBody: [String] = []

        @inline(__always) func flush() {
            // Drop the leading synthetic .unknown("") if it's empty OR
            // contains only blank/whitespace lines. Keeps the section
            // list clean for files that start with a real header,
            // empty files, and files that have only blank-line preamble.
            if case .unknown(let name) = currentKind, name.isEmpty,
               currentBody.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return
            }
            sections.append(Section(kind: currentKind, bodyLines: currentBody))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Section header?
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
                let inner = String(trimmed.dropFirst().dropLast())
                let kind = sectionKind(forHeader: inner)
                flush()
                currentKind = kind
                currentBody = []
                continue
            }
            currentBody.append(line)
        }
        flush()
        return ResourceFile(sections: sections)
    }

    private static func sectionKind(forHeader name: String) -> SectionKind {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "swiftx-config" { return .config }
        if trimmed == "global" { return .global }
        if trimmed.hasPrefix("theme:") {
            let themeName = String(trimmed.dropFirst("theme:".count))
                .trimmingCharacters(in: .whitespaces)
            return .theme(themeName)
        }
        return .unknown(trimmed)
    }
}

// MARK: - File I/O

public enum ResourceFileLoader {

    /// Standard location for the user's swift-x resources. Dotfile in
    /// `$HOME` per THEMES.md decision (own file, not stepping on
    /// `~/.Xresources` which xrdb and other servers consume).
    public static let defaultPath: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".swiftx-resources")

    /// Load the file at `path`. If it doesn't exist, write the seed
    /// content first and then load. Always returns a parsed result;
    /// on read or write failure it logs the issue and falls back to
    /// parsing the seed directly (so the server still has something
    /// to publish even when the disk is uncooperative).
    public static func loadOrSeed(
        path: String = defaultPath,
        seed: @autoclosure () -> String,
        log: ServerLogSink? = nil
    ) -> ResourceFile {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let seedContent = seed()
            do {
                try seedContent.write(toFile: path, atomically: true, encoding: .utf8)
                log?.log("ResourceFile: wrote seed to \(path) (first run)")
            } catch {
                log?.log("ResourceFile: could not write seed to \(path) (\(error)); using in-memory fallback")
                return ResourceFile.parse(seedContent)
            }
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return ResourceFile.parse(content)
        } catch {
            log?.log("ResourceFile: could not read \(path) (\(error)); using in-memory seed")
            return ResourceFile.parse(seed())
        }
    }

    /// Overwrite the user's resource file with fresh seed bytes. Optionally
    /// copies the existing file to `<path>.bak` first so a customization
    /// the user wanted to keep is recoverable. Returns the backup path
    /// when a backup was actually written (nil otherwise — either the
    /// caller passed `backup: false`, or there was nothing on disk to
    /// back up).
    ///
    /// Thrown errors come from `FileManager.copyItem` / `removeItem` or
    /// `String.write(toFile:)`. Callers should surface them to the user
    /// rather than silently swallow.
    @discardableResult
    public static func reseed(
        path: String = defaultPath,
        seed: String,
        backup: Bool = true,
        log: ServerLogSink? = nil
    ) throws -> String? {
        let fm = FileManager.default
        var backupPath: String? = nil
        if backup, fm.fileExists(atPath: path) {
            let bak = path + ".bak"
            // Replace any prior .bak — we keep one generation only,
            // matching the simplest "oh wait, I wanted that" recovery
            // story without growing a chain of .bak.bak.bak files.
            if fm.fileExists(atPath: bak) {
                try fm.removeItem(atPath: bak)
            }
            try fm.copyItem(atPath: path, toPath: bak)
            backupPath = bak
            log?.log("ResourceFile: backed up \(path) → \(bak)")
        }
        try seed.write(toFile: path, atomically: true, encoding: .utf8)
        log?.log("ResourceFile: reseeded \(path) from defaults")
        return backupPath
    }
}
