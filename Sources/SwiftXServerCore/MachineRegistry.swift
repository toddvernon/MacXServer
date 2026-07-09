import Foundation

/// A read-only view of one machine's identity + run state, safe to hand across
/// actor boundaries (e.g. to the MCP bridge). The registry is the discovery
/// layer the golden-master workflow rides on (see MACHINE_MANAGER_REFACTOR.md);
/// this is its read surface, so Claude can learn the fleet without reaching into
/// AppDelegate state.
public struct MachineSnapshot: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let kind: MachineKind
    public let os: MachineOS?
    public let host: String
    /// nil for an external host (no lifecycle we own). For an emulated VM: true
    /// once its qemu process is up (still true while booting/shutting down).
    public let running: Bool?
    /// The guest answered `hello` -- daemon is up. nil for external hosts.
    public let ready: Bool?
    /// An emulated VM with an image set (can actually run).
    public let installed: Bool
    /// The Mac-side port this machine's Helios daemon answers on (the hostfwd
    /// for an emulated VM, the real port for an external host). The MCP bridge
    /// hands this to Claude as the dial-here half of machine discovery.
    public let heliosPort: UInt16
}

/// Owns the configured machines and their live controllers. Replaces AppDelegate's
/// single `qemuEngine?`/`controller?` with a keyed collection: the machine list
/// (persisted as JSON), the runtime controller per running machine (nil until
/// started), and the invariants. AppDelegate talks to the registry; the
/// god-object shrinks.
///
/// P1 scope: the registry is loaded and is the machine data's home + the MCP read
/// surface, but only one machine (the bundled emulated VM) has its lifecycle wired
/// to UI, and only one runs at a time. Concurrency (N controllers, dynamic ports,
/// per-machine secrets) is P2. `@MainActor` because it holds `MachineController`s
/// and AppDelegate drives it from the main thread.
@MainActor
public final class MachineRegistry {
    public private(set) var machines: [Machine]
    private var controllers: [UUID: MachineController] = [:]
    private let path: String
    private let logSink: ServerLogSink?

    public init(machines: [Machine], path: String = MachinesFileLoader.defaultPath,
                log: ServerLogSink? = nil) {
        self.machines = machines
        self.path = path
        self.logSink = log
    }

    /// Load the registry, migrating from the legacy launchers file on first run.
    public static func load(path: String = MachinesFileLoader.defaultPath,
                            launchersPath: String = LauncherFileLoader.defaultPath,
                            bundledImagePath: String,
                            bundledUser: String,
                            log: ServerLogSink? = nil) -> MachineRegistry {
        let file = MachinesFileLoader.loadOrMigrate(
            path: path, launchersPath: launchersPath,
            bundledImagePath: bundledImagePath, bundledUser: bundledUser, log: log)
        let registry = MachineRegistry(machines: file.machines, path: path, log: log)
        registry.assignMissingPortBlocks()
        return registry
    }

    /// One-shot at load: any non-bundled emulated VM that predates sticky port
    /// assignment (ports == nil, so it was silently deriving an OS block that
    /// belongs to a bundled fixture) gets its own block now, persisted. New
    /// machines get theirs in `add`/`update`; this catches the existing file.
    private func assignMissingPortBlocks() {
        var changed = false
        for i in machines.indices {
            var m = machines[i]
            assignPortsIfNeeded(&m)
            if m != machines[i] { machines[i] = m; changed = true }
        }
        if changed { save() }
    }

    // MARK: - Lookup

    public func machine(_ id: UUID) -> Machine? { machines.first { $0.id == id } }
    public func controller(_ id: UUID) -> MachineController? { controllers[id] }

    /// The ids of every machine whose controller currently has a live qemu
    /// process. P2: any number of emulated VMs can run at once.
    public var runningMachineIDs: Set<UUID> {
        Set(controllers.filter { isRunning($0.value) }.keys)
    }

    private func isRunning(_ c: MachineController) -> Bool {
        c.engine.state == .running || c.engine.state == .shuttingDown
    }

    // MARK: - Controllers

    /// Install (or clear) the runtime controller for a machine. AppDelegate builds
    /// and wires the controller (its console/state closures are UI-coupled); the
    /// registry just holds it keyed by machine id.
    public func setController(_ controller: MachineController?, for id: UUID) {
        controllers[id] = controller
    }

    // MARK: - Mutation + persistence

    /// Append a new machine and persist. The caller (the in-app editor) is
    /// responsible for a sensible id/name; the registry just stores it. Image
    /// uniqueness among emulated VMs is advisory here -- use `imageClaimant` to
    /// warn before adding -- not hard-refused, so a half-filled new machine can
    /// exist while the user finishes editing it.
    public func add(_ machine: Machine) {
        var m = machine
        assignPortsIfNeeded(&m)
        machines.append(m)
        save()
    }

    // MARK: - Port assignment (sticky, at creation)

    /// Give a user-created emulated VM its own port block, ONCE, and persist it
    /// on the machine (Todd's call 2026-07-06: "dynamic by assignment time, not
    /// by invocation" -- a machine's ports never change once it's associated
    /// with the app). Bundled fixtures keep deriving their well-known per-OS
    /// blocks (Solaris 2123/2222/2125 etc., which the whole tooling ecosystem
    /// assumes); everything else gets the next free block in the same mnemonic
    /// pattern (2153/2252/2155, 2163/2262/2165, ...). External hosts need no
    /// assignment (they're dialed at their real LAN ports).
    private func assignPortsIfNeeded(_ m: inout Machine) {
        guard m.kind == .emulatedVM, !m.bundled, m.ports == nil else { return }
        m.ports = nextFreePortBlock()
    }

    /// The lowest mnemonic block (see `ImagePorts.block`) that doesn't overlap
    /// any machine's resolved ports. Blocks 2-4 are the per-OS blocks the
    /// bundled fixtures own, so the scan starts at 5.
    public func nextFreePortBlock() -> ImagePorts {
        let taken = machines.filter { $0.kind == .emulatedVM }.map(\.resolvedPorts)
        var index = 5
        while taken.contains(where: { $0.overlaps(ImagePorts.block(index)) }) {
            index += 1
        }
        return ImagePorts.block(index)
    }

    /// The other emulated VM (if any) whose resolved port block overlaps
    /// `ports`, ignoring `excluding` (the machine being edited). The Settings
    /// ports editor runs this at commit so a collision is flagged in the form
    /// instead of surfacing later as the launch-time `portConflict` refusal.
    /// Only emulated VMs are checked: they all share loopback, while external
    /// hosts are dialed at their own host's real ports, so two externals both
    /// on 23/22/2125 is the norm, not a clash.
    public func portBlockClaimant(ports: ImagePorts, excluding: UUID?) -> Machine? {
        machines.first { m in
            m.kind == .emulatedVM && m.id != excluding
                && m.resolvedPorts.overlaps(ports)
        }
    }

    /// The RUNNING machine (if any) whose ports collide with `machine`'s.
    /// Belt-and-suspenders start guard: sticky assignment means this can't
    /// happen unless someone hand-edited machines.json into a conflict, but a
    /// port fight between two live qemus is confusing enough to refuse cleanly.
    public func portConflict(for machine: Machine) -> Machine? {
        let ports = machine.resolvedPorts
        return machines.first { other in
            other.id != machine.id
                && runningMachineIDs.contains(other.id)
                && other.resolvedPorts.overlaps(ports)
        }
    }

    /// Remove a machine (by id), drop any live controller it had, and persist.
    /// Returns false if no such machine. The caller must not remove a running
    /// machine (stop it first); the registry doesn't own lifecycle here.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return false }
        machines.remove(at: i)
        controllers[id] = nil
        save()
        return true
    }

    /// The emulated VM (if any) already pointing at `imagePath`, ignoring the
    /// machine with id `excluding` (the one being edited). Tilde-expanded so
    /// `~/x.qcow2` and the absolute form match. Lets the editor warn before two
    /// machines claim the same qcow2 (the "one live opener per image" invariant).
    public func imageClaimant(imagePath: String, excluding: UUID?) -> Machine? {
        let target = (imagePath as NSString).expandingTildeInPath
        guard !target.isEmpty else { return nil }
        return machines.first { m in
            m.kind == .emulatedVM && m.id != excluding
                && (m.imagePath.map { ($0 as NSString).expandingTildeInPath }) == target
        }
    }

    /// Replace a machine's config (matched by id) and persist. Used as the machine
    /// data changes (the list-window editor). A machine edited into being an
    /// emulated VM (kind flipped in the editor) gets its sticky port block here,
    /// since `add` couldn't have known; the reverse flip sheds the block (an
    /// external host is dialed at its REAL ports -- 23/22/2125 defaults -- not a
    /// loopback hostfwd allocation).
    public func update(_ machine: Machine) {
        guard let i = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        var m = machine
        if machines[i].kind == .emulatedVM && m.kind == .externalHost {
            m.ports = nil
        }
        assignPortsIfNeeded(&m)
        guard machines[i] != m else { return }
        machines[i] = m
        save()
    }

    /// Merge machines freshly derived from the legacy launcher file into the
    /// registry: for a match (the emulated VM, or an external host by host string)
    /// keep the existing machine + its stable id and sync its launchers (and the
    /// bundled image); an unmatched group becomes a new external machine. Never
    /// removes a machine -- an external host you configured keeps its Keychain
    /// secret even if you delete its launchers. Transitional: the launcher file
    /// stays the editable launcher source until an in-app machine editor exists.
    public func reconcile(withMigrated migrated: [Machine]) {
        var changed = false
        for m in migrated {
            if let i = indexMatching(m) {
                if machines[i].launchers != m.launchers {
                    machines[i].launchers = m.launchers
                    changed = true
                }
                if machines[i].kind == .emulatedVM, m.imagePath != nil,
                   machines[i].imagePath != m.imagePath {
                    machines[i].imagePath = m.imagePath
                    changed = true
                }
            } else {
                machines.append(m)
                changed = true
            }
        }
        if changed { save() }
    }

    private func indexMatching(_ m: Machine) -> Int? {
        if m.kind == .emulatedVM { return machines.firstIndex { $0.kind == .emulatedVM } }
        return machines.firstIndex {
            $0.kind == .externalHost && $0.host.lowercased() == m.host.lowercased()
        }
    }

    public func save() {
        do {
            try MachinesFile(machines: machines).encoded()
                .write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            logSink?.log("machines: save failed: \(error)")
        }
    }

    // MARK: - MCP read surface

    /// A snapshot of every machine + its run state, for the MCP bridge / any
    /// read-only consumer. Cheap; call on demand.
    public func snapshot() -> [MachineSnapshot] {
        machines.map { m in
            let controller = controllers[m.id]
            let external = m.kind == .externalHost
            return MachineSnapshot(
                id: m.id, name: m.name, kind: m.kind, os: m.os, host: m.host,
                running: external ? nil : (controller.map(isRunning) ?? false),
                ready: external ? nil : (controller?.isReady ?? false),
                installed: m.isInstalledEmulatedVM,
                heliosPort: m.resolvedPorts.helios)
        }
    }
}
