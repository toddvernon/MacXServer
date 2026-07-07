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

/// How an emulated VM is put on the network. slirp is the zero-config default
/// (free outbound NAT, localhost hostfwds). See "Networking" in the refactor
/// doc. Only `.slirp` behavior is wired today; the other two are P2.
public enum MachineNetworkMode: String, Equatable, Sendable, Codable {
    case slirp             // user-mode, hostfwds bound to localhost (default)
    case slirpLanExposed   // slirp, a forward bound 0.0.0.0 for LAN reach
    case socketFabric      // slirp on le0 + a socket fabric on a second NIC
}

/// One launcher command belonging to a machine: a named X-client command that
/// runs *on that machine*. It carries only what's specific to the command;
/// host / user / transport / port / display come from the owning machine (the
/// launcher inherits them unless it sets an override). This is the persisted,
/// configured form. `Machine.resolved(_:)` turns it into the runtime
/// `LauncherEntry` the launch machinery consumes.
public struct MachineLauncher: Equatable, Sendable, Codable {
    /// Menu-item label.
    public var name: String
    /// The X client command line. Optional: a filebrowser item opens the Helios
    /// browser rather than running anything, so it needs no command.
    public var command: String?
    /// Override the machine's transport for just this command. nil = inherit.
    public var transport: LauncherTransport?
    /// Show the per-launch progress window with the session transcript.
    public var verbose: Bool
    /// Add a Helios file-browser item instead of a launch. Only meaningful on a
    /// helios-transport machine.
    public var fileBrowser: Bool
    /// Override the DISPLAY handed to this command. nil = inherit the machine's.
    public var display: String?
    /// Optional cleartext password (telnet dev convenience; ignored for ssh).
    public var password: String?

    public init(name: String, command: String? = nil, transport: LauncherTransport? = nil,
                verbose: Bool = false, fileBrowser: Bool = false,
                display: String? = nil, password: String? = nil) {
        self.name = name; self.command = command; self.transport = transport
        self.verbose = verbose; self.fileBrowser = fileBrowser
        self.display = display; self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case name, command, transport, verbose, fileBrowser, display, password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        transport = try c.decodeIfPresent(LauncherTransport.self, forKey: .transport)
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        fileBrowser = try c.decodeIfPresent(Bool.self, forKey: .fileBrowser) ?? false
        display = try c.decodeIfPresent(String.self, forKey: .display)
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    /// Emit only what's set, so a launcher reads as `{ "name": ..., "command": ... }`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(transport, forKey: .transport)
        if verbose { try c.encode(true, forKey: .verbose) }
        if fileBrowser { try c.encode(true, forKey: .fileBrowser) }
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(password, forKey: .password)
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
    /// Explicit port triple. nil = derive from `os` (emulated) or 23/22/2125
    /// (external). Set only when a machine needs non-standard ports.
    public var ports: ImagePorts?

    // emulatedVM-only (nil / defaulted for external hosts).
    /// qcow2 path (raw string; `~` expanded by `image`). The lifecycle identity.
    public var imagePath: String?
    public var memoryMB: Int
    /// Unique per machine (a duplicate MAC collides the moment two VMs share a
    /// segment). nil = derive from `id` (see `resolvedMacAddress`).
    public var macAddress: String?
    public var networkMode: MachineNetworkMode
    /// Keep a dated "last known good" copy of the disk image after each clean
    /// shutdown (the old global `sparcplug.autoBackupOnShutdown`, per-machine
    /// now that several images can run). Emulated VMs only.
    public var autoBackup: Bool

    /// This machine's launcher commands.
    public var launchers: [MachineLauncher]

    public init(id: UUID = UUID(), name: String, kind: MachineKind, os: MachineOS? = nil,
                bundled: Bool = false,
                host: String, user: String, transport: LauncherTransport = .helios,
                display: String? = nil, ports: ImagePorts? = nil,
                imagePath: String? = nil, memoryMB: Int = 128, macAddress: String? = nil,
                networkMode: MachineNetworkMode = .slirp, autoBackup: Bool = true,
                launchers: [MachineLauncher] = []) {
        self.id = id; self.name = name; self.kind = kind; self.os = os
        self.bundled = bundled
        self.host = host; self.user = user; self.transport = transport
        self.display = display; self.ports = ports
        self.imagePath = imagePath; self.memoryMB = memoryMB
        self.macAddress = macAddress; self.networkMode = networkMode
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
    /// os, user, transport, display, memory, network mode, and every launcher
    /// command -- carries over. `name` defaults to "<name> copy".
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

    /// True for an emulated VM with an image set (i.e. it can actually run).
    public var isInstalledEmulatedVM: Bool {
        kind == .emulatedVM && (imagePath?.isEmpty == false)
    }

    // MARK: Runtime resolution

    /// Reconstruct the `QemuEngineConfig` for an emulated VM. Helper + firmware
    /// come from the app bundle (via `defaultConfig`); this machine overrides the
    /// disk image, memory, ports, and (when on) the TFTP shared folder. Returns
    /// nil for an external host or an image-less emulated VM. Mirrors the old
    /// AppDelegate.makeSparcConfig, now driven by the machine instead of globals.
    public func makeEngineConfig(bundle: Bundle = .main,
                                 tftpDirectory: String? = nil) -> QemuEngineConfig? {
        guard kind == .emulatedVM, let image = image else { return nil }
        var config = QemuEngine.defaultConfig(bundle: bundle, memoryMB: memoryMB)
        config.diskImage = image
        config.ports = resolvedPorts
        config.macAddress = resolvedMacAddress
        config.tftpDirectory = tftpDirectory
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
        if let d = launcher.display ?? display { merged["display"] = d }
        if let c = launcher.command { merged["command"] = c }
        if launcher.fileBrowser { merged["filebrowser"] = "true" }
        if launcher.verbose { merged["verbose"] = "true" }
        if let pw = launcher.password { merged["password"] = pw }
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

    // MARK: Codable (forgiving decode + terse encode)

    enum CodingKeys: String, CodingKey {
        case id, name, kind, os, bundled, host, user, transport, display, ports
        case imagePath = "image", memoryMB, macAddress = "mac", networkMode
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
        ports = try c.decodeIfPresent(ImagePorts.self, forKey: .ports)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 128
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        networkMode = try c.decodeIfPresent(MachineNetworkMode.self, forKey: .networkMode) ?? .slirp
        autoBackup = try c.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? true
        launchers = try c.decodeIfPresent([MachineLauncher].self, forKey: .launchers) ?? []
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
        try c.encodeIfPresent(ports, forKey: .ports)
        if kind == .emulatedVM {
            try c.encodeIfPresent(imagePath, forKey: .imagePath)
            try c.encode(memoryMB, forKey: .memoryMB)
            try c.encodeIfPresent(macAddress, forKey: .macAddress)
            if networkMode != .slirp { try c.encode(networkMode, forKey: .networkMode) }
            if !autoBackup { try c.encode(false, forKey: .autoBackup) }
        }
        if !launchers.isEmpty { try c.encode(launchers, forKey: .launchers) }
    }
}
