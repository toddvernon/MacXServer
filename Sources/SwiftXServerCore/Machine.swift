import Foundation

/// One machine macXserver manages: either an emulated qemu VM (full lifecycle we
/// own) or an external real host on the LAN (no lifecycle we own, but Helios +
/// launchers). See MACHINE_MANAGER_REFACTOR.md. The two kinds differ by
/// *capability set*, not a uniform interface -- a real Sun genuinely has no
/// QMP/start/stop -- so callers gate verbs on `kind` rather than assuming.
public enum MachineKind: String, Equatable, Sendable, Codable, CaseIterable {
    case emulatedVM
    case externalHost
}

/// Guest OS. Drives the per-OS port block, and later `-M`/guest bin dirs/Helios
/// quirks. Auto-detected from the image where possible; user-set for external
/// hosts. Nil when unknown (an external box we haven't classified).
public enum MachineOS: String, Equatable, Sendable, Codable, CaseIterable {
    case solaris26
    case sunos414
    case netbsd

    /// The historical per-OS host-port block. In P1 (one machine at a time) this
    /// is the machine's port triple; P2's dynamic allocator supersedes it for
    /// concurrency. Kept as the shape, per QemuEngine.ImagePorts.
    public var defaultPorts: ImagePorts {
        switch self {
        case .solaris26: return .solaris26
        case .sunos414:  return .sunos414
        case .netbsd:    return .netbsd
        }
    }

    /// Human label for UI (the console header, etc.) -- the `rawValue` is a terse
    /// JSON key, not something to show a user.
    public var displayName: String {
        switch self {
        case .solaris26: return "Solaris 2.6"
        case .sunos414:  return "SunOS 4.1.4"
        case .netbsd:    return "NetBSD"
        }
    }

    /// The qemu SCSI unit (= ESP target) the boot disk must attach at for this
    /// guest. SunOS 4.1.4's kernel reverses target<->sd naming (target 3 = sd0),
    /// and its fstab is written for sd0, so the disk must sit at unit 3; Solaris
    /// and NetBSD use unit 0. Mirrors the standalone run scripts (unit=3 in
    /// emu/sunos414-full.sh, unit=0 elsewhere). See expand_414_fs.md.
    public var bootDiskUnit: Int {
        switch self {
        case .sunos414: return 3
        case .solaris26, .netbsd: return 0
        }
    }

    /// The OpenBOOT `boot-command` to bake in (qemu's OpenBIOS ignores
    /// `boot-device` but honors `boot-command` on auto-boot). nil = default
    /// auto-boot (Solaris boots fine that way). SunOS 4.1.4 and NetBSD pin the
    /// explicit SCSI path, matching their run scripts.
    public var bootCommand: String? {
        switch self {
        case .solaris26: return nil
        case .sunos414:  return "boot /iommu/sbus/espdma/esp/sd@3,0"
        case .netbsd:    return "boot /iommu/sbus/espdma/esp/sd@0,0"
        }
    }

    // MARK: - Guest profile
    //
    // Everything the host does that DIFFERS by guest OS lives here, one exhaustive
    // `switch` per behavior, so adding an OS (or a new divergent behavior) won't
    // compile until every case is filled in -- the forcing function that turns a
    // silent per-OS gap into a build error. Grew out of the 2026-07-05 shutdown
    // bug, where a hardcoded Solaris `init 5` silently no-op'd on SunOS 4.1.4.
    // The OS × behavior matrix is documented in GUEST_OS_PROFILE.md.

    /// The command that halts the guest. Solaris uses SVR4 `init 5` (syncs +
    /// powers off); the BSD guests use `halt`. Consumed guest-side by the Helios
    /// daemon's `HELIOS_SHUTDOWN_CMD` (set per-OS at deploy) -- this is the
    /// host-side source of truth the deploy must match, and what a future
    /// pass-the-command shutdown verb would send.
    public var shutdownCommand: String {
        switch self {
        case .solaris26: return "/usr/sbin/init 5"
        case .sunos414:  return "/usr/etc/halt"
        case .netbsd:    return "/sbin/halt"
        }
    }

    /// Console phrases that positively signal a clean halt in progress, so the
    /// stop is labeled clean rather than a crash. Matched as substrings (any one).
    /// The authoritative "it stopped" signal is qemu exiting; this only refines
    /// the clean/unclean label. NOTE: the BSD phrases are best-effort and should
    /// be tightened against real console output; a miss just mislabels a clean
    /// stop, it doesn't hang anything.
    public var cleanHaltMarkers: [String] {
        switch self {
        case .solaris26: return ["syncing file systems"]
        case .sunos414:  return ["syncing file systems", "halted"]
        case .netbsd:    return ["syncing disks", "halted", "rebooting"]
        }
    }

    /// Console phrases that positively signal a boot has WEDGED at an
    /// interactive fsck prompt (multiuser never reached → the daemon never
    /// starts → `hello` never answers), so the host can declare the boot
    /// stalled immediately instead of waiting out the full readiness budget.
    /// Matched as substrings (any one). It's the *failure* phrase, not bare
    /// "fsck" — a clean boot runs a routine preen check too. Per-OS because the
    /// wording differs: SVR4 says "RUN fsck MANUALLY", NetBSD's fsck_ffs says
    /// "RUN fsck_ffs MANUALLY" (the Solaris literal silently never matched on
    /// NetBSD — same Solaris-default-on-all-guests class as the shutdown bug).
    public var fsckStallMarkers: [String] {
        switch self {
        case .solaris26: return ["RUN fsck MANUALLY"]
        case .sunos414:  return ["RUN fsck MANUALLY"]
        case .netbsd:    return ["RUN fsck_ffs MANUALLY", "RUN fsck MANUALLY"]
        }
    }

    /// Map a guest's own `uname` report (the sysinfo verb's `uname` field) to
    /// a MachineOS. The box itself is the source of truth for what it runs --
    /// same doctrine as image detection on emulated VMs -- so the prober uses
    /// this to auto-populate an external machine's OS. nil = something we
    /// don't profile (don't clobber a manual setting with a wrong guess).
    public static func detect(unameSysname sysname: String, release: String) -> MachineOS? {
        switch sysname {
        case "SunOS":
            if release.hasPrefix("4.") { return .sunos414 }
            if release.hasPrefix("5.") { return .solaris26 }
            return nil
        case "NetBSD":
            return .netbsd
        default:
            return nil
        }
    }

    /// PATH prefix so a bare `xterm` / `dtterm` resolves under the daemon's
    /// minimal env. Solaris ships OpenWindows + CDE; SunOS 4.1.4 has OpenWindows +
    /// MIT X but no CDE (`/usr/dt`); NetBSD ships X under `/usr/X11R7`.
    public var xBinDirs: String {
        switch self {
        case .solaris26: return "/usr/openwin/bin:/usr/dt/bin:/usr/bin/X11"
        case .sunos414:  return "/usr/openwin/bin:/usr/bin/X11"
        case .netbsd:    return "/usr/X11R7/bin"
        }
    }
}

// (No network-mode knob: every emulated VM is slirp user-mode NAT with its
// hostfwds bound to 127.0.0.1 -- the app on this Mac is the only thing that
// dials guest ports. The dead `networkMode` enum was deleted 2026-07-09; a
// legacy key in machines.json is ignored on decode. If LAN-exposed guests or
// a shared inter-VM segment ever become real needs, they get designed fresh
// with UI, not a dormant enum. See DECISIONS.md 2026-07-09.)

/// One launcher command belonging to a machine: a named X-client command that
/// runs *on that machine*. It carries only what's specific to the command;
/// host / user / transport / port / display come from the owning machine (the
/// launcher inherits them unless it sets an override). This is the persisted,
/// configured form. `Machine.resolved(_:)` turns it into the runtime
/// `LauncherEntry` the launch machinery consumes.
public struct MachineLauncher: Equatable, Sendable, Codable {
    /// Menu-item label.
    public var name: String
    /// The X client command line.
    public var command: String?
    /// Override the machine's transport for just this command. nil = inherit.
    public var transport: LauncherTransport?
    // (No `verbose` anymore, 2026-07-08: showing the progress window is a
    // launch-time gesture -- right-click > Run with Progress Window -- not
    // launcher config. A legacy `verbose` key is simply ignored on decode.)
    /// LEGACY (2026-07-07): file-browser launchers were replaced by the
    /// Overview's automatic Admin Agents > File Transfer. Decoded so old
    /// machines.json entries can be recognized and DROPPED on load (see
    /// Machine.init(from:)); never encoded, never editable. There is no
    /// per-launcher DISPLAY anymore either -- the machine's DISPLAY covers
    /// every launcher; a legacy `display` key is simply ignored on decode.
    public internal(set) var fileBrowser: Bool = false
    /// LEGACY (2026-07-08): the password moved to the machine (it's a
    /// credential for the machine's user@host, and launchers can't override
    /// either, so per-launcher copies were pure duplication -- the migrated
    /// file had the same password on every launcher of a box). Decoded so old
    /// machines.json entries can be lifted onto `Machine.password` (see
    /// Machine.init(from:)); never encoded, never editable.
    public internal(set) var password: String?

    public init(name: String, command: String? = nil, transport: LauncherTransport? = nil,
                password: String? = nil) {
        self.name = name; self.command = command; self.transport = transport
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case name, command, transport, fileBrowser, password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        transport = try c.decodeIfPresent(LauncherTransport.self, forKey: .transport)
        fileBrowser = try c.decodeIfPresent(Bool.self, forKey: .fileBrowser) ?? false
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    /// Emit only what's set, so a launcher reads as `{ "name": ..., "command": ... }`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(transport, forKey: .transport)
        // password is legacy: lifted to the machine on decode, never re-emitted.
    }
}

/// A configured machine. Value type -- the persisted config, not the runtime.
/// The runtime (a `MachineController` wrapping a `QemuEngine`) is held separately
/// by the registry, keyed by `id`, and is nil until the machine is started.
///
/// Persisted as JSON in `~/.macxserver-machines.json` (a flat, readable object;
/// see MachinesFile). Connection fields live directly on the machine -- no nested
/// "connection" object, no bracket-block inheritance -- and ports are derived
/// from `os` unless explicitly overridden, so the common case stays terse.
public struct Machine: Identifiable, Equatable, Sendable, Codable {
    /// Stable identity, the registry key. Never the image path or a host string,
    /// so a machine survives an image move or a rename. Persisted; generated if
    /// a hand-written entry omits it.
    public var id: UUID
    /// User-facing label. Doubles as the launcher menu group for this machine.
    public var name: String
    public var kind: MachineKind
    public var os: MachineOS?
    /// True for the machines we ship (the bundled fixtures: one per guest OS).
    /// Bundled machines are protected from removal and grouped in the "Bundled
    /// Machines" section; a machine you create in the editor is always false, so
    /// it sorts into Virtual (emulated) or External by its kind. Persisted only
    /// when true (see encode).
    public var bundled: Bool

    // Connection (flat -- how we reach this machine's Helios/ssh/telnet planes).
    public var host: String
    public var user: String
    public var transport: LauncherTransport
    /// DISPLAY override handed to launched clients; nil = auto-compute from the
    /// Mac's LAN IP + display number. The canonical override is a slirp guest's
    /// `10.0.2.2:0`.
    public var display: String?
    /// Shell-prompt needle for the telnet launcher: the substring that marks
    /// "logged in, shell ready" for THIS machine+account (e.g. "tvernon]" for
    /// the fleet's csh prompt). nil = built-in detection (classic $ % # >
    /// sigils and the bracket-wrapped fleet prompt). A property of the
    /// machine, not of each launcher -- reintroduced 2026-07-07 after the
    /// per-launcher `shell_prompt` key died with the old launchers file.
    public var shellPrompt: String?
    /// Login password for telnet launches, cleartext in machines.json (a dev
    /// convenience -- the file is the user's own config, same trust level the
    /// old launchers file had). nil = ask on first launch and store in the
    /// macOS Keychain (the Debug dev-file fallback included; see
    /// KeychainHelper). A machine credential (user@host), not per-launcher --
    /// moved up 2026-07-08, same slimming as display/fileBrowser/shellPrompt.
    public var password: String?
    /// Explicit port triple. nil = derive from `os` (emulated) or 23/22/2125
    /// (external). Set only when a machine needs non-standard ports.
    public var ports: ImagePorts?

    // emulatedVM-only (nil / defaulted for external hosts).
    /// qcow2 path (raw string; `~` expanded by `image`). The lifecycle identity.
    /// (No memory setting: every VM gets the SS-5's full 256MB -- see
    /// QemuEngineConfig.memoryMB. The old per-machine knob was removed
    /// 2026-07-07; a legacy `memoryMB` key in machines.json is ignored.)
    public var imagePath: String?
    /// Unique per machine (a duplicate MAC collides the moment two VMs share a
    /// segment). nil = derive from `id` (see `resolvedMacAddress`).
    public var macAddress: String?
    /// Keep a dated "last known good" copy of the disk image after each clean
    /// shutdown (the old global `sparcplug.autoBackupOnShutdown`, per-machine
    /// now that several images can run). Emulated VMs only.
    public var autoBackup: Bool

    /// This machine's launcher commands.
    public var launchers: [MachineLauncher]

    public init(id: UUID = UUID(), name: String, kind: MachineKind, os: MachineOS? = nil,
                bundled: Bool = false,
                host: String, user: String, transport: LauncherTransport = .helios,
                display: String? = nil, shellPrompt: String? = nil,
                password: String? = nil,
                ports: ImagePorts? = nil,
                imagePath: String? = nil, macAddress: String? = nil,
                autoBackup: Bool = true,
                launchers: [MachineLauncher] = []) {
        self.id = id; self.name = name; self.kind = kind; self.os = os
        self.bundled = bundled
        self.host = host; self.user = user; self.transport = transport
        self.display = display; self.shellPrompt = shellPrompt
        self.password = password; self.ports = ports
        self.imagePath = imagePath
        self.macAddress = macAddress
        self.autoBackup = autoBackup
        self.launchers = launchers
    }

    // MARK: Derived

    /// A copy of this machine for the "Clone" action: a fresh identity, the same
    /// connection + launchers, but **not the VM itself**. The disk image, MAC,
    /// and port block are dropped (you can't have two live openers on one qcow2,
    /// and a MAC / host-port block must be unique per machine -- the registry
    /// assigns the clone its own block on add), so a cloned emulated VM comes up
    /// "not installed" until you point it at its own image; a cloned external
    /// host is fully usable as soon as you set its host. Everything else -- kind,
    /// os, user, transport, display, password, and every launcher command --
    /// carries over. `name` defaults to "<name> copy".
    public func cloned(named newName: String? = nil) -> Machine {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) copy"
        copy.bundled = false        // a clone is your machine, never a shipped fixture
        copy.imagePath = nil
        copy.macAddress = nil
        if kind == .emulatedVM { copy.ports = nil }   // external ports are real LAN ports; keep those
        return copy
    }

    /// The image URL (tilde-expanded), or nil when unset.
    public var image: URL? {
        guard let p = imagePath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// The effective port triple: the explicit override, else the OS block for
    /// an emulated VM, else the standard external defaults.
    public var resolvedPorts: ImagePorts {
        if let ports = ports { return ports }
        if kind == .emulatedVM { return os?.defaultPorts ?? .solaris26 }
        return ImagePorts(telnet: 23, ssh: 22, helios: 2125)
    }

    /// The effective guest MAC: the explicit override, else derived from `id` in
    /// the locally-administered range (02:xx:...). Deterministic -- the same
    /// machine keeps the same MAC across boots (stable guest identity) -- and
    /// unique per machine, so two guests on one segment (or one Mac's slirp)
    /// never collide the way the old single hardcoded MAC did.
    public var resolvedMacAddress: String {
        if let mac = macAddress, !mac.isEmpty { return mac }
        let b = id.uuid
        return String(format: "02:%02X:%02X:%02X:%02X:%02X", b.0, b.1, b.2, b.3, b.4)
    }

    /// True for an emulated VM whose disk image actually exists on disk
    /// (i.e. it can really run). A set-but-missing imagePath counts as NOT
    /// installed on purpose: deleting the image honestly returns the machine
    /// to its imageless state -- starter hero pane, "Not installed" row --
    /// per DECISIONS 2026-07-16 (found broken in wizard re-testing
    /// 2026-07-26: the old path-is-set check kept a deleted install looking
    /// stopped forever). An image on an unmounted volume reads the same way;
    /// truthful, and it recovers the moment the file is back.
    public var isInstalledEmulatedVM: Bool {
        guard kind == .emulatedVM, let image else { return false }
        return FileManager.default.fileExists(atPath: image.path)
    }

    // MARK: Runtime resolution

    /// Reconstruct the `QemuEngineConfig` for an emulated VM. Helper + firmware
    /// come from the app bundle (via `defaultConfig`); this machine overrides the
    /// disk image and ports. Memory is not per-machine: every VM gets the SS-5
    /// maximum (defaultConfig's 256MB). Returns nil for an external host or an
    /// image-less emulated VM. Mirrors the old AppDelegate.makeSparcConfig, now
    /// driven by the machine instead of globals.
    public func makeEngineConfig(bundle: Bundle = .main) -> QemuEngineConfig? {
        guard kind == .emulatedVM, let image = image else { return nil }
        var config = QemuEngine.defaultConfig(bundle: bundle)
        // The dev escape hatch wins over the machine's value: defaultConfig has
        // already applied SPARCPLUG_DISK_IMAGE from the env, so only overwrite
        // when the env DIDN'T set it. Before this the per-machine value always
        // clobbered the env var, making it dead on the app path (it only worked
        // in tests). See CODE_AUDIT §2a.
        let env = ProcessInfo.processInfo.environment
        if (env["SPARCPLUG_DISK_IMAGE"]?.isEmpty ?? true) { config.diskImage = image }
        config.ports = resolvedPorts
        config.macAddress = resolvedMacAddress
        config.os = os
        return config
    }

    /// Resolve one launcher to the runtime `LauncherEntry`, filling host / user /
    /// transport / port / display from this machine (the launcher's own overrides
    /// win). Returns nil if the result is unusable (no command and not a
    /// filebrowser). Warnings (ssh-with-password etc.) accrue to `warnings`.
    public func resolved(_ launcher: MachineLauncher,
                         warnings: inout [String]) -> LauncherEntry? {
        let transport = launcher.transport ?? self.transport
        var merged: [String: String] = [
            "host": host, "user": user, "transport": transport.rawValue,
            "port": String(resolvedPorts.port(for: transport)),
        ]
        if let d = display { merged["display"] = d }
        if let sp = shellPrompt, !sp.isEmpty { merged["shell_prompt"] = sp }
        if let c = launcher.command { merged["command"] = c }
        // The password is a machine credential; only the telnet flow injects
        // it (ssh is keys-only, helios has its own secret), so a telnet
        // machine's ssh launchers don't trip the ssh-with-password warning.
        if transport == .telnet, let pw = password, !pw.isEmpty {
            merged["password"] = pw
        }
        return LauncherEntry.build(merged: merged, name: launcher.name,
                                   group: name, warnings: &warnings)
    }

    /// All of this machine's launchers as runtime entries, plus any warnings.
    public func resolvedEntries() -> (entries: [LauncherEntry], warnings: [String]) {
        var warnings: [String] = []
        var entries: [LauncherEntry] = []
        for l in launchers {
            if let e = resolved(l, warnings: &warnings) { entries.append(e) }
        }
        return (entries, warnings)
    }

    /// The Admin Agents File Transfer entry: this machine's connection facts
    /// with the helios transport and the file-browser flag, no launcher
    /// involved (file access stopped being launcher config on 2026-07-07 --
    /// it appears automatically whenever the box has helios).
    public func fileTransferEntry(warnings: inout [String]) -> LauncherEntry? {
        let merged: [String: String] = [
            "host": host, "user": user,
            "transport": LauncherTransport.helios.rawValue,
            "port": String(resolvedPorts.helios),
            "filebrowser": "true",
        ]
        return LauncherEntry.build(merged: merged, name: "File Transfer",
                                   group: name, warnings: &warnings)
    }

    // MARK: Codable (forgiving decode + terse encode)

    enum CodingKeys: String, CodingKey {
        case id, name, kind, os, bundled, host, user, transport, display, shellPrompt
        case password, ports
        case imagePath = "image", macAddress = "mac"
        case autoBackup, launchers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(MachineKind.self, forKey: .kind)
        os = try c.decodeIfPresent(MachineOS.self, forKey: .os)
        bundled = try c.decodeIfPresent(Bool.self, forKey: .bundled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host)
            ?? (kind == .emulatedVM ? "127.0.0.1" : "")
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        transport = try c.decodeIfPresent(LauncherTransport.self, forKey: .transport) ?? .helios
        display = try c.decodeIfPresent(String.self, forKey: .display)
        shellPrompt = try c.decodeIfPresent(String.self, forKey: .shellPrompt)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        ports = try c.decodeIfPresent(ImagePorts.self, forKey: .ports)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        autoBackup = try c.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? true
        launchers = try c.decodeIfPresent([MachineLauncher].self, forKey: .launchers) ?? []
        // One-shot migration (2026-07-07): legacy file-browser launchers are
        // superseded by Admin Agents > File Transfer, which appears
        // automatically whenever the box has helios. Drop them on load; the
        // next save writes the file without them.
        launchers.removeAll { $0.fileBrowser }
        // One-shot migration (2026-07-08): the password moved up to the
        // machine (one credential per user@host, not a copy on every
        // launcher). Lift the first non-empty legacy per-launcher password if
        // the machine has none, then drop them all; the next save writes the
        // file in the new shape.
        if password == nil {
            password = launchers.compactMap(\.password).first { !$0.isEmpty }
        }
        for i in launchers.indices { launchers[i].password = nil }
    }

    /// Emit a clean, flat object: always id/name/kind/host/user; the emulated-only
    /// fields and any non-default values only when they apply.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(os, forKey: .os)
        if bundled { try c.encode(true, forKey: .bundled) }
        try c.encode(host, forKey: .host)
        try c.encode(user, forKey: .user)
        if transport != .helios { try c.encode(transport, forKey: .transport) }
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(shellPrompt, forKey: .shellPrompt)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encodeIfPresent(ports, forKey: .ports)
        if kind == .emulatedVM {
            try c.encodeIfPresent(imagePath, forKey: .imagePath)
            try c.encodeIfPresent(macAddress, forKey: .macAddress)
            if !autoBackup { try c.encode(false, forKey: .autoBackup) }
        }
        if !launchers.isEmpty { try c.encode(launchers, forKey: .launchers) }
    }
}
