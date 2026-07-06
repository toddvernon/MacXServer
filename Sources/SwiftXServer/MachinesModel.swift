import Foundation
import SwiftXServerCore

/// The status indicator for a machine (master-list dot + Overview page).
enum MachineStatusDot: Equatable {
    case running        // guest up and ready (daemon answered)
    case booting        // qemu up, still coming to ready
    case stopped        // installed, not running
    case notInstalled   // emulated VM with no image
    case external       // a real host (no lifecycle we own)
}

/// One clickable launcher under a machine (Overview page runs it on click).
struct MachineLauncherChip: Identifiable, Equatable {
    let id: String          // the launcher name (unique within a machine)
    let name: String
    let isFileBrowser: Bool
    let enabled: Bool
}

/// The live *operate* state of a machine, as the Overview page renders it.
/// AppDelegate computes these from the registry + controller state (the same
/// source the Machines menu reads), so the window and the menu never disagree.
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

/// The single observable backing for the unified Machines window: a master list
/// of machines with a per-machine detail pane that switches between an **Overview**
/// (operate: status + lifecycle + run launchers) and **Settings** (edit: the config
/// form + add/edit/remove launchers) tab.
///
/// It merges what used to be two models (the list window's operate model and the
/// editor's edit model): AppDelegate owns the `MachineRegistry`, assigns
/// `machines` + `rows`, and wires every `on*` closure. The view reads `rows[id]`
/// for the Overview and edits a local draft of `machines`' selected element for
/// Settings, committing via `onCommit`.
@MainActor
final class MachinesModel: ObservableObject {
    /// The registry's machines, mirrored for the master list + Settings form.
    @Published var machines: [Machine] = []
    /// Live operate-state per machine id, for the Overview page + master dot.
    @Published var rows: [UUID: MachineRow] = [:]
    /// The selected machine in the master list.
    @Published var selection: UUID?

    /// The bundled emulated VM's id: special (kind + host locked, can't be
    /// removed, image tracks Preferences). nil if there's no bundled machine.
    var bundledMachineID: UUID?
    /// The id of the machine whose qemu is currently live (if any). Its image
    /// can't be edited out from under it and it can't be removed.
    var runningMachineID: UUID?

    // Operate actions (Overview page + master list).
    var onStart: ((UUID) -> Void)?
    var onShutDown: ((UUID) -> Void)?
    var onForceQuit: ((UUID) -> Void)?
    var onBackup: ((UUID) -> Void)?
    var onConsole: ((UUID) -> Void)?
    /// (machineID, launcherName)
    var onLaunch: ((UUID, String) -> Void)?
    var onSetHeliosSecret: ((UUID) -> Void)?

    // Edit actions (master toolbar + Settings page).
    /// Add a fresh default machine, persist it, and return its id to select.
    var onAddNew: (() -> UUID?)?
    /// Commit edits to an existing machine (matched by id).
    var onCommit: ((Machine) -> Void)?
    /// Remove a machine by id.
    var onRemove: ((UUID) -> Void)?
    /// Clone a machine (config + launchers, not the disk image); returns the new
    /// machine's id to select.
    var onClone: ((UUID) -> UUID?)?
    /// Present an NSOpenPanel to pick a qcow2; returns the chosen path or nil.
    var onPickImage: (() -> String?)?
    /// The name of the *other* emulated VM already claiming `imagePath` (excluding
    /// the machine being edited), or nil if the image is free. Drives a warning.
    var imageClaimant: ((_ imagePath: String, _ excluding: UUID) -> String?)?

    var selectedMachine: Machine? { machines.first { $0.id == selection } }
    func row(_ id: UUID) -> MachineRow? { rows[id] }
    func isBundled(_ id: UUID) -> Bool { id == bundledMachineID }
    func isRunning(_ id: UUID) -> Bool { id == runningMachineID }
}
