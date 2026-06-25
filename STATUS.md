# Status 2026-06-25

Two threads this stretch: the per-launcher Helios file browser shipped + deployed
(2026-06-24), and then a hard look at SPARCplug VM control turned up that we'd
been driving qemu as a black box and never using QMP. That produced a design
(`VM_CONTROL.md`), a DECISIONS entry, and **Stage 1 built + live-validated**: a
QMP control channel alongside Helios.

## Where things stand

**VM control redesign (the live thread).** macXserver now controls the captive
qemu through **two planes**: Helios (guest OS -- exec/files/`init 5`, the only
plane on real iron) and **QMP** (the VM/hypervisor -- clean-halt events, a
qcow2-clean stop, snapshots; captive-only). They barely overlap, which is the
right shape. Full design + the source-cited sun4m capability evidence in
`VM_CONTROL.md`; settled-decision summary in DECISIONS.md 2026-06-24.

- **Stage 1 DONE + live-validated 2026-06-25.** New `QmpClient` (async, demuxes
  events from id-correlated responses; 6 unit tests) wired into `QemuEngine`:
  `-qmp unix:<sock>,server=on,wait=off` at launch, post-launch connect-with-retry,
  the `SHUTDOWN` event (`reason: guest-shutdown`) as a backup clean-halt signal
  next to the console string, and Force Quit now prefers a qcow2-clean QMP `quit`
  (SIGTERM fallback). Console path untouched (still the stdio pipe).
  - **Live-validated against real qemu-9.2.4 / SS-5:** QMP handshake +
    `query-status: running`; Helios `init 5` -> `SHUTDOWN {guest:true,
    reason:"guest-shutdown"}` + clean exit; QMP `quit` -> `SHUTDOWN {guest:false,
    reason:"host-qmp-quit"}` + clean exit. The `reason` field reliably separates a
    guest clean-halt from a host Force Quit -- exactly what `handleQmpEvent` keys
    on, so a Force Quit won't trigger a spurious auto-backup.

**File browser (prior thread, closed).** Per-launcher `filebrowser = true` (helios
transport) opens a single-pane browser of the user's home dir; drag to/from
Finder both ways, upload overwrite-warned + Solaris-name-munged, runs AS the
user. Daemon file-verb run-as deployed + verified on the live image. A
non-helios filebrowser key gives an honest wrong-transport dialog. HELIOS_PLAN
C8 done; C9 (real-box Helios over ssh-tunnel preferred, static-secret fallback)
captured.

## What's working

- `swift build` clean; full suite **1401 tests, 0 failures**. New:
  `QmpClientTests` (6), the `buildArguments` `-qmp` test, plus the file-browser /
  lock-secret / sanitizer tests from 06-24.
- Stage 1 QMP path proven end-to-end on real qemu (see above).

## What's broken / not yet verified

- The `QemuEngine` QMP *integration* (connect-retry, event->clean-halt,
  kill->quit) has no unit test -- it needs a live qemu, so it's covered by the
  live validation + the `QmpClient` unit tests instead. The pure part
  (`buildArguments` `-qmp` arg) is unit-tested.
- The in-app path wasn't exercised this session (I drove qemu+QMP manually, not
  through the running app). Behavior is identical, but a normal app-launch boot
  should be eyeballed once to confirm `connectQmp` attaches.

## What's next

- **VM control Stage 2:** move the console from the stdio pipe to a `-serial
  unix:` socket. Kills the orphan 100%-CPU spin (qemu busy-polls the hung-up
  pipe today) and enables console reconnect. Higher touch -- its own stage.
- **Stage 3:** lock-as-VM-handle (QMP + console socket paths in the lock) +
  orphan QMP recovery + console reconnect. Closes the parked L2-Reconnect / L3.
- **Stage 4 (post-v1):** snapshot fast-launch (sun4m vmstate verified viable;
  wants a live savevm/loadvm round-trip before banking it).
- **Plugin v1 (reconciled in PLUGIN_V1_PUNCHLIST.md):** the real shipping work is
  Track A (sign the qemu helper into the bundle + clean-Mac acceptance), Track
  C/E (download + install the image, with the current Helios daemon baked in),
  and **Restore from Backup** (the one functional gap, "fix before shipping").
  Helios-closed control items (L0/L2/L3) are reconciled as done.

## What's committed (recent, all pushed)

- `~/dev/X`: `5b18284` Stage 1 wiring + live-validate; `f088f42` QmpClient;
  `7366251` VM_CONTROL.md + DECISIONS; `b89ea29` punchlist reconcile; `2f34494`
  C9 ssh-preferred; `f0163f4` Helios-Mission reframe. (The file-browser +
  daemon-run-as commits from 06-24 are upstream of these.)
- `~/Dropbox/dev/cx` (heliosAgent): file-verb run-as (06-24), unchanged since.
- `~/dev/SPARCplug`: unchanged.

## Switching to the other Mac

- Let Dropbox finish syncing memory + the cx tree before opening the other Mac
  (the qcow2 didn't change beyond normal use this session).
- `git pull` X and the cx tree.
- VM is shut down, no image lock.
- `/sos` first.

## Pointers

- VM control: `QmpClient.swift` (the QMP client), `QemuEngine.swift`
  (`connectQmp` / `handleQmpEvent` / `kill` / `buildArguments` qmp arg).
  Design + staging: `VM_CONTROL.md`. Decision: DECISIONS.md 2026-06-24.
- File browser: `FileBrowserPanel*` / `FileBrowserWindowController` /
  `AppDelegate.openFileBrowser`; `SolarisFilename.swift`; `ImageLock.secret`.
- Daemon run-as: `cx_apps/heliosAgent/Verbs.cpp`. Redeploy: `guest/get-helios.sh`.
