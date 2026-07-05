import Foundation
import SwiftXServerCore

/// The status indicator for a machine row.
enum MachineStatusDot: Equatable {
    case running        // guest up and ready (daemon answered)
    case booting        // qemu up, still coming to ready
    case stopped        // installed, not running
    case notInstalled   // emulated VM with no image
    case external       // a real host (no lifecycle we own)
}

/// One clickable launcher under a machine.
struct MachineLauncherChip: Identifiable, Equatable {
    let id: String          // the launcher name (unique within a machine)
    let name: String
    let isFileBrowser: Bool
    let enabled: Bool
}

/// A machine as the list window renders it. AppDelegate computes these from the
/// registry + live controller state (the same source `refreshSparcMenu` reads),
/// so the window and the menu never disagree.
struct MachineRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isEmulated: Bool
    let subtitle: String        // image name, or "host · external"
    let statusText: String
    let dot: MachineStatusDot
    let progress: Double?       // boot progress 0...1 when booting

    // Lifecycle capabilities. In P1 only the wired bundled emulated VM shows
    // lifecycle controls; external hosts have none (no start/stop we own).
    let showsLifecycle: Bool
    let canStart: Bool
    let canShutDown: Bool
    let canForceQuit: Bool
    let canBackup: Bool
    let canConsole: Bool

    /// External hosts carry a Helios daemon secret the user enters (bundled VMs
    /// get theirs per-boot automatically). True → show the "Helios Secret" control.
    let canSetHeliosSecret: Bool

    let launchers: [MachineLauncherChip]
}

/// Observable backing for the Machines list window. A dumb published container +
/// action hooks: AppDelegate owns the state (it already tracks controller state
/// for the menu) and assigns `rows`; the view calls the `on*` closures, which
/// AppDelegate wires to the existing lifecycle/launch methods.
@MainActor
final class MachineListModel: ObservableObject {
    @Published var rows: [MachineRow] = []

    var onStart: ((UUID) -> Void)?
    var onShutDown: ((UUID) -> Void)?
    var onForceQuit: ((UUID) -> Void)?
    var onBackup: ((UUID) -> Void)?
    var onConsole: ((UUID) -> Void)?
    /// (machineID, launcherName)
    var onLaunch: ((UUID, String) -> Void)?
    var onSetHeliosSecret: ((UUID) -> Void)?
    var onAddMachine: (() -> Void)?
}
