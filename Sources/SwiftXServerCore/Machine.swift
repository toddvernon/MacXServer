import Foundation

/// One machine macXserver manages: either an emulated qemu VM (full lifecycle we
/// own) or an external real host on the LAN (no lifecycle we own, but Helios +
/// launchers). See MACHINE_MANAGER_REFACTOR.md. The two kinds differ by
/// *capability set*, not a uniform interface -- a real Sun genuinely has no
/// QMP/start/stop -- so callers gate verbs on `kind` rather than assuming.
public enum MachineKind: String, Equatable, Sendable {
    case emulatedVM
    case externalHost
}

/// Guest OS. Drives the per-OS port block, and later `-M`/guest bin dirs/Helios
/// quirks. Auto-detected from the image where possible; user-set for external
/// hosts. Nil when unknown (an external box we haven't classified).
public enum MachineOS: String, Equatable, Sendable {
    case solaris26
    case sunos414
    case netbsd

    /// The historical per-OS host-port block. In P1 (one machine at a time) this
    /// is the machine's static port triple; P2's dynamic allocator supersedes it
    /// for concurrency. Kept as the shape, per QemuEngine.ImagePorts.
    public var defaultPorts: ImagePorts {
        switch self {
        case .solaris26: return .solaris26
        case .sunos414:  return .sunos414
        case .netbsd:    return .netbsd
        }
    }
}

/// How an emulated VM is put on the network. slirp is the zero-config default
/// (free outbound NAT, localhost hostfwds). See "Networking" in the refactor
/// doc. Only `.slirp` behavior is wired today; the other two are P2.
public enum MachineNetworkMode: String, Equatable, Sendable {
    /// User-mode networking, hostfwds bound to localhost. The default.
    case slirp
    /// slirp, but a forward is bound `0.0.0.0` so the LAN can reach the guest.
    case slirpLanExposed
    /// slirp on le0 plus a `-netdev socket` fabric on a second NIC so VMs can
    /// talk to each other.
    case socketFabric
}

/// Connection identity: how we reach a machine's Helios/ssh/telnet planes, and
/// the DISPLAY we hand its launched X clients. For an emulated VM these are the
/// loopback hostfwd ports; for an external host they're the real LAN ports.
public struct MachineConnection: Equatable, Sendable {
    public var host: String
    public var user: String
    public var ports: ImagePorts
    public var transport: LauncherTransport
    /// DISPLAY override; nil = auto-compute from the Mac's LAN IP + display
    /// number. The canonical override is a slirp guest's `10.0.2.2:0`.
    public var display: String?

    public init(host: String, user: String, ports: ImagePorts,
                transport: LauncherTransport, display: String? = nil) {
        self.host = host; self.user = user; self.ports = ports
        self.transport = transport; self.display = display
    }
}

/// A configured machine. Value type -- the persisted config, not the runtime.
/// The runtime (a `MachineController` wrapping a `QemuEngine`) is held separately
/// by the registry, keyed by `id`, and is nil until the machine is started.
public struct Machine: Identifiable, Equatable, Sendable {
    /// Stable identity, the registry key. Never the image path or a host string,
    /// so a machine survives an image move or a rename. Persisted in the file.
    public let id: UUID
    /// The `[machine:KEY]` key -- also the `group` on this machine's launcher
    /// entries, so a launcher item ties back to its machine by string.
    public var key: String
    /// User-facing label. Defaults to `key` when unset.
    public var name: String
    public var kind: MachineKind
    public var os: MachineOS?
    public var connection: MachineConnection
    /// This machine's launcher commands (the `[KEY/item]` entries). Their `group`
    /// equals `key`.
    public var launchers: [LauncherEntry]

    // MARK: emulatedVM-only (nil / defaulted for external hosts)

    /// Path to the qcow2 -- the lifecycle identity of an emulated VM.
    public var image: URL?
    public var memoryMB: Int
    /// Unique per machine (a duplicate MAC collides the moment two VMs share a
    /// segment). Nil = derive at start from `id`. Wired in P2.
    public var macAddress: String?
    public var networkMode: MachineNetworkMode

    public init(id: UUID = UUID(), key: String, name: String? = nil,
                kind: MachineKind, os: MachineOS? = nil,
                connection: MachineConnection, launchers: [LauncherEntry] = [],
                image: URL? = nil, memoryMB: Int = 128,
                macAddress: String? = nil,
                networkMode: MachineNetworkMode = .slirp) {
        self.id = id; self.key = key; self.name = name ?? key
        self.kind = kind; self.os = os
        self.connection = connection; self.launchers = launchers
        self.image = image; self.memoryMB = memoryMB
        self.macAddress = macAddress; self.networkMode = networkMode
    }

    /// True for an emulated VM with an image path set (i.e. it can actually run).
    /// An emulatedVM with no image is "not installed."
    public var isInstalledEmulatedVM: Bool {
        kind == .emulatedVM && image != nil
    }

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
        config.ports = connection.ports
        config.tftpDirectory = tftpDirectory
        return config
    }
}
