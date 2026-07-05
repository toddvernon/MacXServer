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
        return MachineRegistry(machines: file.machines, path: path, log: log)
    }

    // MARK: - Lookup

    public func machine(_ id: UUID) -> Machine? { machines.first { $0.id == id } }
    public func controller(_ id: UUID) -> MachineController? { controllers[id] }

    /// The bundled emulated VM -- the first (and, in P1, only) emulatedVM machine.
    /// This is what the existing SPARCstation menu drives.
    public var bundledMachine: Machine? { machines.first { $0.kind == .emulatedVM } }

    /// The id of the machine whose controller currently has a live qemu process,
    /// if any. In P1 at most one is running.
    public var runningMachineID: UUID? {
        controllers.first { isRunning($0.value) }?.key
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

    /// Replace a machine's config (matched by id) and persist. Used as the machine
    /// data changes (e.g. the bundled machine's image tracking Preferences in P1;
    /// the list-window editor in P1c).
    public func update(_ machine: Machine) {
        guard let i = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        guard machines[i] != machine else { return }
        machines[i] = machine
        save()
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
                installed: m.isInstalledEmulatedVM)
        }
    }
}
