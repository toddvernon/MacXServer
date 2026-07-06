import Foundation

/// The per-machine runtime unit. Owns the one `QemuEngine` for a machine and
/// the machine's readiness flag, keyed by a stable `id`. Today the app holds
/// exactly one of these (the bundled SPARCstation); the Machine Manager refactor
/// (see MACHINE_MANAGER_REFACTOR.md) grows a `MachineRegistry` that holds a keyed
/// collection of them, one per configured machine.
///
/// P0 scope (2026-07-05): this is the near-mechanical extraction seam. It owns
/// the non-UI machine runtime -- the engine and `isReady`. UI that's per-machine
/// (the serial-console window) stays owned app-side for now and becomes keyed by
/// `id` in P1; the hypervisor/lock/secret/port state the doc lists (QmpClient,
/// ImageLock sidecar, per-machine secret file, port allocation) folds in during
/// the concurrency phase (P2), where more than one machine runs at once and the
/// currently-global singletons actually collide.
///
/// `@MainActor` because the app drives it entirely from the main thread and
/// `QemuEngine` already dispatches its callbacks onto the main queue.
@MainActor
public final class MachineController {

    /// Stable identity -- the registry key once the registry exists (P1). Never
    /// the image path or a host string, so a machine keeps its identity across
    /// an image move or a config edit.
    public let id: UUID

    /// The machine's engine. AppDelegate reaches engine operations through this
    /// (`controller.engine.foo`) rather than holding a bare `QemuEngine?`.
    public let engine: QemuEngine

    /// True once this machine's guest answered `hello` this run (the
    /// authoritative daemon-is-up signal). Was AppDelegate's global `sparcReady`;
    /// it's per-machine now so each running machine tracks its own readiness.
    /// Set in the engine's onReady wiring, cleared the moment state leaves
    /// `.running`. Reads default to a stopped machine being not-ready.
    public var isReady: Bool = false

    /// 0...1 boot/shutdown progress of the current run, mirrored from the
    /// engine's onProgress into the list row's dot. nil when not running. Was
    /// AppDelegate's single `bundledBootProgress`; per-machine in P2.
    public var bootProgress: Double?

    public init(id: UUID = UUID(), config: QemuEngineConfig) {
        self.id = id
        self.engine = QemuEngine(config: config)
    }
}
