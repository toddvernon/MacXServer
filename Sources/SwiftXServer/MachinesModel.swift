import Foundation
import SwiftXServerCore

/// The status indicator for a machine (master-list dot + Overview page).
enum MachineStatusDot: Equatable {
    case running        // guest up and ready (daemon answered)
    case booting        // qemu up, still coming to ready
    case stopped        // installed, not running
    case notInstalled   // emulated VM with no image
    // External hosts: no lifecycle we own, but the helios prober (~3 min
    // hello against EVERY external with a host) refines the dot. The TCP
    // layer is an aliveness oracle independent of helios configuration
    // (2026-07-10): a REFUSED connect proves the box is alive with no agent;
    // an agent that ANSWERS "unauthorized" is alive with an agent; only a
    // timeout / no-route means the box isn't there. Colors stay, but every
    // surface also carries the state in words (Todd: "the colors start to
    // get confusing").
    case external               // unknown (first probe still pending)
    case externalUp             // agent answered hello
    case externalUnauthorized   // agent alive but denied the request
    case externalNoAgent        // box alive, nothing listening on the helios port
    case externalDown           // unreachable: timeout / no route / no resolve
}

/// One clickable launcher under a machine (Overview page runs it on click).
struct MachineLauncherChip: Identifiable, Equatable {
    let id: String          // the launcher name (unique within a machine)
    let name: String
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
    /// The dot's meaning in a word or two ("reachable", "no agent",
    /// "unreachable", ...), shown next to the color wherever the color alone
    /// would have to be decoded. nil = nothing to add (e.g. unprobed).
    let stateWord: String?
    let dot: MachineStatusDot
    let progress: Double?       // boot progress 0...1 when booting

    /// The machine's ACTIVE USER (machine.user): the account launchers log in
    /// as. Leads the Overview page -- identity is host + account. Empty =
    /// none set yet.
    let activeUser: String

    /// One caption under the Overview's launcher chips saying why any of them
    /// are dimmed ("machine unreachable", "Helios launchers need the agent").
    /// nil = nothing dimmed, no note.
    let launcherNote: String?

    /// One quiet line of guest facts from the agent's `sysinfo` (uname, load,
    /// swap, disk fullness, clock drift), composed by AppDelegate from the
    /// latest probe. nil = no data yet (machine down, agent pre-0.2.0, or
    /// never probed). Display-only; fields the agent omitted just don't
    /// appear in the line.
    let systemLine: String?

    // Lifecycle capabilities. In P1 only the wired bundled emulated VM shows
    // lifecycle controls; external hosts have none (no start/stop we own).
    let showsLifecycle: Bool
    let canStart: Bool
    let canShutDown: Bool
    let canForceQuit: Bool
    let canBackup: Bool
    let canConsole: Bool

    /// An imageless emulated VM whose OS is known can fetch its curated image
    /// (IMAGE_DOWNLOAD_PLAN.md): the Overview shows Download… next to Start.
    let canDownload: Bool
    /// A curated-image download is in flight for this machine: the thermometer
    /// does download duty and the lifecycle row offers Cancel.
    let isDownloading: Bool
    // The Admin Agents rule (Todd, 2026-07-07): an admin verb is available
    // when the box is ANSWERING over Helios -- emulated = running and ready
    // (readiness IS the helios liveness signal), external = the prober's
    // last hello succeeded (which, against the fail-closed agent, also
    // proves the saved secret) -- plus, for OS-sensitive verbs, when we know
    // what OS the machine runs (external boxes declare it in Settings;
    // emulated machines get it from image detection).

    /// DNS admin (edit /etc/resolv.conf over the agent). OS-sensitive:
    /// an external host also needs its OS set.
    let canDnsAdmin: Bool

    /// Helios file browser. OS-agnostic, so reachability alone gates it.
    let canFileTransfer: Bool

    /// Users admin (add/delete accounts). OS-sensitive -- UserAdmin's per-OS
    /// mechanics need the machine's OS -- so it gates on the box answering
    /// over Helios AND a known OS, same rule File Transfer uses plus the OS.
    let canManageUsers: Bool

    /// The lightweight tier of the Overview's Change… button (2026-07-14):
    /// an external box with NO agent to manage users through. The full Users
    /// panel is impossible there, so Change… opens the Change Login sheet
    /// instead -- username + password, proven by actually logging in over
    /// the box's own telnetd before anything is adopted. Never true when
    /// `canManageUsers` is (the panel outranks the sheet wherever the agent
    /// answers); false for emulated VMs (our guests all run the agent, so
    /// "not ready" means wait, not downgrade).
    let canChangeLogin: Bool

    /// Clock admin (set the guest clock from this Mac). OS-sensitive --
    /// ClockAdmin's date grammar and the 4.1.4 year-safety gate are per-OS --
    /// so it uses the same rule as Users.
    let canSyncClock: Bool

    /// True when the machine's OS came from the box itself (an external
    /// host's sysinfo uname). The Settings OS picker dims: the box outranks
    /// a manual pick, same as image detection does on emulated VMs.
    let osIsDetected: Bool

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

    /// The ids of every machine whose qemu is currently live. A running
    /// machine's image can't be edited out from under it and it can't be
    /// removed. P2: any number can run at once.
    var runningMachineIDs: Set<UUID> = []

    // Operate actions (Overview page + master list).
    var onStart: ((UUID) -> Void)?
    var onShutDown: ((UUID) -> Void)?
    var onForceQuit: ((UUID) -> Void)?
    var onBackup: ((UUID) -> Void)?
    var onConsole: ((UUID) -> Void)?
    /// (machineID, launcherName, verbose). verbose = stream this one launch's
    /// transcript to a live progress window (right-click > Run with Progress
    /// Window); it's a launch gesture, not launcher config.
    var onLaunch: ((UUID, String, Bool) -> Void)?
    var onSetHeliosSecret: ((UUID) -> Void)?
    /// Download this machine's curated starter image (imageless emulated VM
    /// with a known OS; see MachineRow.canDownload).
    var onDownload: ((UUID) -> Void)?
    /// Cancel the in-flight image download.
    var onCancelDownload: ((UUID) -> Void)?
    /// Open the machine's DNS (/etc/resolv.conf) admin window.
    var onDnsAdmin: ((UUID) -> Void)?
    /// Open the machine's Helios file browser (Overview → Admin Agents).
    var onFileTransfer: ((UUID) -> Void)?
    /// Open the machine's Users admin panel (Overview → Admin Agents).
    var onManageUsers: ((UUID) -> Void)?
    /// Change Login (the agent-less tier of Change…): prove user+password by
    /// logging in over the box's telnetd, then adopt them as the machine's
    /// active user (machine.user + telnet Keychain slot). The completion fires
    /// on the main actor: nil = adopted, else a user-facing failure message
    /// the sheet shows inline.
    var onVerifyLogin: ((_ id: UUID, _ user: String, _ password: String,
                         _ completion: @escaping (String?) -> Void) -> Void)?
    /// Open the machine's Clock admin panel (Overview → Admin Agents).
    var onSyncClock: ((UUID) -> Void)?

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
    /// The name of the *other* emulated VM whose port block overlaps `ports`
    /// (excluding the machine being edited), or nil if the block is free.
    /// Drives the Settings ports editor's collision warning.
    var portsClaimant: ((_ ports: ImagePorts, _ excluding: UUID) -> String?)?
    /// Whether an external machine has a Helios secret saved (Keychain /
    /// dev-secrets). Drives the Settings Helios section's status line -- the
    /// value itself never reaches the form.
    var hasHeliosSecret: ((_ id: UUID) -> Bool)?
    /// The DISPLAY a launched client gets when the machine leaves it blank:
    /// this X server's own address ("<Mac LAN IP>:<display>"). Shown as the
    /// field's placeholder so blank reads as what it actually does.
    var defaultDisplay: (() -> String)?

    var selectedMachine: Machine? { machines.first { $0.id == selection } }
    func row(_ id: UUID) -> MachineRow? { rows[id] }
    func isRunning(_ id: UUID) -> Bool { runningMachineIDs.contains(id) }

    /// Fresh-install state: there's an emulated VM to run but none has a disk
    /// image yet. Drives the first-run bubble + the blue (prominent) Download
    /// button (FIRST_RUN_EXPERIENCE.md). State-derived, not a dismissed-once
    /// flag, so it honestly returns if every image is later removed.
    var isFirstRun: Bool {
        let emulated = machines.filter { $0.kind == .emulatedVM }
        return !emulated.isEmpty && emulated.allSatisfy { $0.image == nil }
    }

    // The master list's three sections, each sorted by name (case-insensitive).
    // A machine you create lands in Virtual (emulated) or External by its kind;
    // the machines we ship carry `bundled` and group at the top.
    private func sorted(_ ms: [Machine]) -> [Machine] {
        ms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var bundledMachines: [Machine]  { sorted(machines.filter { $0.bundled }) }
    var virtualMachines: [Machine]  { sorted(machines.filter { $0.kind == .emulatedVM && !$0.bundled }) }
    var externalMachines: [Machine] { sorted(machines.filter { $0.kind == .externalHost }) }
}
