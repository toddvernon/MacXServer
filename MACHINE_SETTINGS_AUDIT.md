# Machine settings audit (2026-07-08)

Audit of the Machines window settings UI and the machine-state model:
organization, discoverability, and whether user-editable config matches what
the code actually consumes. Two subagent passes (UI inventory + state/config
cross-reference), top findings hand-verified against the working tree
(main @ f577f81). Read-only audit; nothing was changed.

**2026-07-09: the cleanup shipped** (SETTINGS_CLEANUP_PLAN.md, all four
phases). Each finding below carries a Status line: 9 shipped, F3 deferred
to SHORTCUTS.md.

Files walked: MachineDetailForm.swift (MDF), MachinesWindowView.swift (MWV),
MachinesModel.swift, AppDelegate.swift (AD), Machine.swift (M),
MachinesFile.swift, MachineRegistry.swift, LauncherFile.swift (LF),
TelnetLauncher / SSHLauncher / HeliosLauncher, QemuEngine,
DnsAdminWindowController / DnsAdminPanelView, KeychainHelper.

One correction to the framing that prompted this: the Identity section holds
only Name and Kind (MDF:142-168). Host and User already live under
Connection. The underlying complaint (naming and grouping are muddled) still
stands.

---

## 1. What the UI actually is today

Machines window = master list + detail pane with two tabs: Overview (operate)
and Settings (edit). Settings has five sections in order: Identity,
Connection, Disk image (emulated only), Runtime (emulated only, read-only),
X11 Launchers. Plus a launcher editor sheet and the Helios Secret dialog.

Field inventory, condensed (section / field / backing property / consumers):

| Section | Field | Property | Consumed by | Visible help? |
|---|---|---|---|---|
| Identity | Name | `name` | list row, menus, launcher group, console title | validation note only |
| Identity | Kind | `kind` | gates everything: ports, engine, section visibility | bundled note only |
| Connection | Host | `host` | all launches, prober, Keychain account keys | validation note only |
| Connection | User | `user` | telnet/ssh/helios login, both Keychain keys | none |
| Connection | Transport | `transport` | launcher default (M:390), prober candidacy (AD:1278) | none, raw enum values |
| Connection | OS | `os` | boot config, halt cmd, port block, xBinDirs, DNS gate | provenance caption only |
| Connection | Prompt (telnet only) | `shellPrompt` | TelnetLauncher shell-ready needle | hover tooltip only |
| Connection | Password (telnet only) | `password` | telnet credential ladder (AD:1431-1437) | hover tooltip only |
| Connection | DISPLAY | `display` | launch-time DISPLAY export (AD:1466), nothing else | hover tooltip only |
| Disk image | path + Choose/Reveal | `imagePath` | qemu disk, OS detection, claim check, backups | warnings only |
| Disk image | auto-backup toggle | `autoBackup` | post-clean-halt clone (AD:1691) | yes, the house model |
| Runtime | Ports (read-only) | `resolvedPorts` | every launch/probe/hostfwd/file-browser dial | shared footnote |
| Runtime | MAC (read-only) | `resolvedMacAddress` | qemu NIC | shared footnote |
| Launchers | name/command/transport | `launchers[i]` | chips, menus, resolved launch | placeholders only |
| Overview | Helios Secret button (external) | Keychain | prober + every Helios call | dialog text |

Exactly one field in the whole form has an always-visible explanatory
caption (the auto-backup toggle, MDF:305-307). Prompt, Password, and DISPLAY
carry hover-only `.help` tooltips, invisible until you know to hover.

Config with NO editor anywhere: `ports` override (M:266), `macAddress`
override (M:276, documented read-only by design), `networkMode` (M:277,
dead, see finding F2).

---

## 2. Organization: what is misfiled and where it should go

Verdicts, field by field:

- **OS** sits in Connection but is machine identity: it drives boot config,
  halt command, port block, X paths (M:24-146). Nothing about connecting.
- **Prompt** and **Password** sit in Connection but are telnet login
  mechanics. Their visibility rule even leaks the problem: editing one
  launcher's transport in the sheet makes two fields materialize in a
  different section of the parent form.
- **DISPLAY** sits in Connection but its only consumer is launch resolution
  (AD:1466). It is X11-launcher config, exactly as suspected.
- **Helios Secret** is a credential setting living on Overview, and it
  occupies the slot where emulated machines show lifecycle buttons
  (MWV:299), which is structurally accidental.
- **Runtime** is doubly misnamed: not runtime state (its own footnote says
  the values never change) and not settings (read-only). It is reference
  info.
- **Identity** reads person-flavored for a section holding machine facts.

### Proposed section structure

Settings tab, five sections:

1. **Machine**: Name, Kind, OS (moved from Connection; detection-lock
   behavior comes along unchanged). What this machine is.
2. **Connection**: Host, Transport (renamed, see below), Helios Secret
   (moved from Overview, external only, as a Set/Change button row since the
   value lives in the Keychain). How the app reaches the box. A wrong secret
   is a connection failure, so its neighbors are Host and Transport.
3. **Login**: User, Password (telnet only), Shell prompt (telnet only). The
   account on the machine. Conditional rows now appear inside the section
   that owns them, and the person/machine confusion dissolves.
4. **X11 Launchers**: the DISPLAY field (renamed "Show windows on") at the
   head, then the launcher list and Add Command. Everything about launching
   in one place.
5. **Disk Image** (emulated only): unchanged.

Runtime section dissolves: Ports + MAC move to Overview as a quiet
monospaced facts row under the system line (they pair naturally with the
live system line, and Settings then contains only things with an edit
affordance). Fallback if kept in Settings: rename to "Assigned by the app".

Overview loses the Helios Secret button; an external host's lifecycle row
then shows nothing, which is truthful.

---

## 3. Labels and helper text

Renames (better than captioning an opaque label):

- Transport -> **"Connect with"**, options title-cased: Telnet, SSH,
  Helios agent (raw lowercase enum values show today, MDF:189-203).
- DISPLAY -> **"Show windows on"**.
- Prompt -> **"Shell prompt"**.
- OS picker values -> `displayName` ("Solaris 2.6"), not raw "solaris26".
  M:34-40 exists for exactly this; raw values violate the no-jargon rule.
- Identity section -> **"Machine"**.
- MAC label (if kept) -> "Network address (MAC)".

Caption drafts (SwiftUI footnote under the control, same style as
`helpNote` MDF:548-551 and the auto-backup toggle). The mechanism already
exists; this is promoting three hover-only tooltips and writing ~6 new
one-liners:

- **Kind**: "An emulated VM runs right here on your Mac. An external host is
  a real machine on your network that this app connects to."
- **User**: "The account on that machine. Apps you launch log in and run as
  this user."
- **Connect with**: "How the app logs in to run things. Telnet and SSH sign
  in like you would at a terminal; the Helios agent is our own helper, the
  smoothest option once it's installed on the machine."
- **OS** (free-picker state): "What the machine runs. Set it if we couldn't
  detect it. It tells the app where that system keeps its X programs and how
  to talk to it."
- **Shell prompt**: "How we recognize that a telnet login finished: text
  your shell prompt ends with. Leave blank and the app figures out the
  usual prompts itself."
- **Password**: "Password for telnet logins. Leave it blank to be asked once
  and have it kept in the macOS Keychain; type it here only if you're fine
  with it sitting in machines.json as plain text."
- **Show windows on**: "Where launched apps put their windows. Blank means
  this X server (shown grayed). From inside an emulated VM this Mac is
  10.0.2.2, so those machines use 10.0.2.2:0." (The live placeholder,
  AD:250-256, is already excellent. Keep it.)
- **Launcher command**: "Runs on the machine with its display already
  pointed at this server. Anything that opens an X window works."
- **Launcher list**: "Right-click a launcher to watch the login play out in
  a progress window, handy when a launch hangs." (Run with Progress Window
  is currently hinted nowhere.)
- **Helios Secret dialog** rewrite: "The password this machine's Helios
  agent expects. The app sends it whenever it talks to the agent: file
  transfer, DNS, status. Leave blank to clear it. Kept in your macOS
  Keychain."
- **Host** (emulated, disabled state): "Emulated VMs are always reached
  through this Mac, so there's nothing to set."

Fine as-is: Name, Kind label, Host (external), Disk image, X11 Launchers,
Admin Agents, the auto-backup footnote (the house standard).

---

## 4. The state model (derived from code)

Kind is explicit (`MachineKind`, M:8-11); bundled is a separate persisted
Bool (M:240). Three user-visible categories:

- **Bundled fixture** = emulatedVM + bundled. Locks kind/host/OS/transport
  (snapped to helios, MDF:38-40), keeps well-known per-OS port blocks.
- **User VM** = emulatedVM, not bundled. Sticky assigned port block.
- **External host** = externalHost. No lifecycle we own (no controller is
  ever built, M:368; AD:1612-1613).

Emulated lifecycle: notInstalled (no image) -> stopped -> booting (running,
not ready) -> running+ready -> shuttingDown, plus the orphan-qemu reattach
path (AD:1777-1837). `ready` = the guest's helios daemon answered hello this
run, so readiness IS the helios liveness signal for emulated machines.

Helios plane is two different mechanisms by kind:

- Emulated: per-boot engine-generated secret, identified by helios port
  among loopback machines (AD:1212-1222). No user-visible secret;
  `canSetHeliosSecret = !isEmulated`.
- External: secret in the Keychain, account `helios:user@host`
  (AD:1200-1202). Prober hellos every candidate (candidacy = transport ==
  helios OR secret set, AD:1278) every ~3 min; reach state {unknown, up,
  unauthorized, down} drives the dot and the admin gates. Launch verbs
  deliberately never gate on probe results (AD:1230-1232).

Transport at launch (AD:1424-1481): telnet = password ladder
(machine password wins, then Keychain, then prompt-and-store) + prompt
scraping, no PATH prepend (login shell owns PATH); ssh = keys only
(BatchMode), prepends per-OS xBinDirs; helios = daemon run_command with
secret, prepends xBinDirs. Per-launcher transport override picked in
`resolved` (M:390).

OS gates: engine guest profile (boot disk, boot command, halt command,
fsck/halt markers, port-block default), xBinDirs for ssh/helios launches
(`os ?? .solaris26`), external DNS-admin gating, manual-shutdown
instructions. OS provenance is a sub-state: manual pick vs image-detected vs
agent-detected (the latter two lock the picker).

Impossible combos are genuinely unreachable in the UI (external x lifecycle,
emulated x user-set secret, bundled x externalHost) with one soft spot:
bundled + transport != helios is only snapped back when the form is opened;
the registry does not enforce it.

The full config-item x state matrix (every persisted property, every
consumer, per state) is in the audit transcript; the summary is that the
model is coherent and mostly honestly gated. The exceptions are the findings
below.

---

## 5. Findings (ranked, top items hand-verified)

### F1 · HIGH · Ports: consulted everywhere, editable nowhere, and a dialog lies about it  [VERIFIED]

> **Status: SHIPPED 2026-07-09 — editable Ports row in Settings → Connection (both kinds), commit-time collision check (`portBlockClaimant`), fields frozen while running.**

`Machine.ports` is a first-class persisted override consumed on every plane
(launch dial, hostfwds, prober, DNS, file browser, manual-shutdown text).
The only UI is the read-only Runtime row, rendered only for emulated VMs. An
external host's ports are invisible entirely: a real box with telnetd/sshd/
heliosAgent on a non-default port can only be configured by hand-editing
machines.json (the migrator even supports pinning a plane,
MachinesFile.swift:145-157, so such configs exist). Meanwhile the
port-conflict alert says "Give one of them its own ports in Settings"
(AD:1625). Settings has no such control. The user is sent to a dead end.

### F2 · HIGH · `networkMode` is dead config, and the live behavior contradicts its doc  [VERIFIED]

> **Status: SHIPPED 2026-07-09 — property deleted, hostfwds bind 127.0.0.1 explicitly. DECISIONS entry.**

`Machine.networkMode` is decoded/encoded (M:459, 497) with documented
semantics (`.slirp` = "hostfwds bound to localhost", `.slirpLanExposed`,
`.socketFabric`) but nothing reads it: `makeEngineConfig` never passes it
and `QemuEngineConfig` has no such field. Worse, the actual nic string is
`hostfwd=tcp::PORT-:23,...` (QemuEngine.swift:925): empty hostaddr, which
qemu/libslirp binds to ALL interfaces. So the guest's telnet/ssh/helios
forwards are LAN-reachable while the model claims loopback-only. Either wire
it (`hostfwd=tcp:127.0.0.1:...` for `.slirp`) or delete the property. Note
this is also a small security surface: guest telnet reachable from the LAN.

### F3 · MEDIUM · Telnet login/password prompt needles are hardcoded

> **Status: DEFERRED — ledgered in SHORTCUTS.md (Telnet launch); fix is the shellPrompt pattern repeated, waiting on a live repro.**

`LauncherEntry.build` defaults loginPrompt = "ogin:", passwordPrompt =
"assword:" (LF:97-98) and `Machine.resolved` never overrides them, so for
machine launchers the defaults are the only possibility. `shellPrompt` was
re-added at machine level after exactly this class of loss (the 2026-07-07
ss5 incident, cited at M:250-256); the other two needles were not. A telnet
host with a "Username:" style banner times out with "Timed out waiting for
login prompt" and there is no knob anywhere.

### F4 · MEDIUM · External DNS admin gates on OS, but DNS never uses the OS  [VERIFIED]

> **Status: SHIPPED 2026-07-09 — OS condition dropped; gate is reach == .up, matching File Transfer.**

`canDnsAdmin` (external) requires reach == .up AND os != nil (AD:421-423),
and the dimmed-button help sends the user to Settings to set the OS. But
`DnsAdminWindowController` takes only name/secret/host/port and the panel
path is a constant `/etc/resolv.conf`. The gate implements the 2026-07-07
"OS-sensitive verbs" doctrine, but nothing downstream is OS-sensitive.
Mitigated in practice by prober OS auto-adoption; a pre-sysinfo (0.1.x)
agent leaves the button permanently dimmed for no functional reason.
Decision needed: drop the OS condition, or keep the doctrine and note it.

### F5 · MEDIUM · Machines menu and Overview disagree on Admin verbs  [VERIFIED]

> **Status: SHIPPED 2026-07-09 — both kinds get an Admin submenu (File Transfer + DNS) mirroring the Overview; external Helios Secret menu item retired with the Overview button.**

The comments claim menu and window mirror each other (AD:72-76, 339-342).
They do not: external machines get DNS + File Transfer on Overview but only
"Helios Secret" in the menu (AD:594-596); emulated machines get both on
Overview but only DNS in the menu's Admin submenu (AD:582-593). A menu-first
user cannot find File Transfer at all.

### F6 · MEDIUM-LOW · Telnet Keychain slot is shared by all loopback VMs with the same user  [VERIFIED]

> **Status: SHIPPED 2026-07-09 — account is user@host:port with one-shot fallback migration from user@host. DECISIONS entry.**

Telnet Keychain account = `user@host` (AD:1438). Every emulated VM is host
127.0.0.1, so the Solaris and NetBSD fixtures both logging in as tvernon
share ONE stored password. First-launch prompt for VM A silently becomes the
stored password for VM B; a mismatch is a bare "Authentication failed".
`Machine.password` is the escape hatch but the Keychain path is the default.
The key should include the machine id or the telnet port. (The helios secret
account has the same shape but is external-only, so it is not affected.)

### F7 · LOW · `LauncherEntry.verbose` is parsed but read by nothing

> **Status: SHIPPED 2026-07-09 — verbose field + parse removed; login_prompt/password_prompt doc block rewritten to say what they really are (legacy dotfile-only keys).**

LF still parses `verbose` (LF:33, 83, 96) and its doc comment describes
behavior that no longer exists (verbosity is exclusively the launch-gesture
parameter now). The legacy `login_prompt`/`password_prompt` doc block is
similarly misleading. Cleanup, not user-visible.

### F8 · LOW · `~/.macxserver-launchers` is still read on every startup

> **Status: SHIPPED 2026-07-09 — dotfile read only when machines.json is absent (the one-shot migration); post-migration bundledUser falls back to NSUserName().**

`loadMachineRegistry` parses the legacy dotfile each launch solely to derive
`bundledUser` for fixture injection (AD:196-205), though the stated design
is one-shot migration input. A stale legacy file's first user silently
becomes the user on any newly injected bundled fixture. Harmless today,
ghost input tomorrow.

### F9 · LOW · Duplicate launcher names are allowed but launchers are keyed by name

> **Status: SHIPPED 2026-07-09 — editor sheet blocks Done on a sibling-name match with a note saying why.**

Chip id, menu representedObject, and `launchFromMachine` all key by name
(AD:398-404, 455, 604); the editor validates only non-empty. Two launchers
named "xterm": the second is unreachable from every run surface, plus
duplicate-ID ForEach glitches. One-line fix: uniqueness in `canSave`, or a
real id on MachineLauncher.

### F10 · LOW · OS-unset ssh/helios launches silently assume Solaris paths

> **Status: CAPTION SHIPPED 2026-07-09 — the telnet-PATH asymmetry is documented in the launcher-command caption; the silent Solaris-path default itself stays as-is (per the cleanup plan, a caption at most).**

`(os ?? .solaris26).xBinDirs` (AD:1473, 1481). External NetBSD box with OS
unset: bare `xterm` gets Solaris paths prepended, fails over ssh/helios,
works over telnet (login shell PATH). The failure never mentions the OS
field. Related, worth documenting at the launcher editor: telnet prepends no
xBinDirs at all, so the same launcher can behave differently per transport
(intentional, undocumented).

### Checked and clean (not findings)

- `Machine.password` is telnet-only by design and the code honors it
  (M:399-402; ssh/helios skip the password path entirely).
- Legacy `fileBrowser`/`password` launcher keys behave exactly as documented
  (decode-drop / decode-lift).
- Prompt/Password visibility matches consumption precisely, including the
  launcher-override case.
- No VM-only field is consulted for external hosts; encode strips
  image/mac/networkMode/autoBackup for externals; ports shed on the
  emulated -> external flip.
- Minor notes: the loopback-host constant is duplicated
  (MachinesFile.swift:24 vs AD:214-216); `resolvedEntries()` (M:409) is
  test-only; the parser `warnings` arrays are discarded at both call sites.

---

## 6. Suggested order of attack

1. F2 (networkMode: wire or delete; the LAN-exposed hostfwd is the part
   with teeth) and F1 (a ports editor, or at minimum stop pointing the
   conflict dialog at a control that does not exist).
2. The reorganization + rename + captions pass (sections 2 and 3). One
   sitting, pure UI, no model changes except moving the Helios Secret entry
   point.
3. F5 and F9 (small correctness fixes), F6 (key the telnet Keychain slot by
   machine), F4 (decide: drop the OS gate on DNS or keep the doctrine).
4. F3 (machine-level login/password prompt needles, same pattern as
   shellPrompt) when a real host needs it.
5. F7/F8 cleanup whenever passing through.
