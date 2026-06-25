# VM control: QMP for the machine, Helios for the guest

Status: **proposed 2026-06-24, approved; Stages 1-3 built + live-validated
2026-06-25 (incl. Design-2 console-view reconnect via engine adoption; the
end-to-end relaunch flow is a manual check).** The settled-decision
summary is the DECISIONS.md entry of
2026-06-24; this is the full design and the staging. Stage progress is tracked in
the rollout section below.

## The problem this fixes

macXserver currently controls the bundled SPARCstation as a black box: it
launches qemu with `-nographic` (serial console to a parent-owned stdio pipe),
reads that console as a text stream, and stops the VM with a process signal
(SIGTERM/SIGKILL). Every VM-level fact and action is therefore either inferred
from the guest console or done with a sledgehammer:

- "Did it halt cleanly?" (the gate for auto-backup) is a **console string match**
  (`syncing file systems... done`).
- "Stop it now" (Force Quit) is **SIGKILL**, which tears qemu down mid-write and
  can leave the qcow2 container inconsistent.
- An orphaned qemu (parent died) **spins at 100% CPU** because the console pipe's
  reader is gone and qemu busy-polls the hung-up fd.
- Liveness is **latch-once** (first Helios `hello`), so a daemon that dies
  mid-session goes unnoticed.

The cause is historical, not a bug: the SPARCplug control story grew bottom-up
from the guest side (console scrape, then `init 5` over the console, then the
Helios agent inside the guest). The `-nographic` choice quietly made the serial
console our only window into the VM, so we reached for console-derived signals
and never asked what the *emulator* exposes. The answer is QMP, the standard
qemu machine-control socket, which we never turned on.

## Two planes, and they barely overlap

There are two control planes, and keeping them separate is the design:

- **Helios plane** -- what's happening *inside the guest OS*: exec, files,
  OS-liveness (`hello`), and the only filesystem-clean shutdown there is
  (`init 5`, which syncs UFS). Works on the bundled emulator **and** on real
  iron, and is the *only* plane on real iron.
- **QMP plane** -- what's happening to the *virtual machine / the container*: VM
  liveness, structured power-state events, clean teardown of the qcow2,
  snapshots, pause/resume. Exists for the **captive emulator only**.

They touch in exactly one place, shutdown, and even there they are complementary,
not redundant: a graceful filesystem-clean shutdown is Helios `init 5` *only*
(QMP `system_powerdown` is a no-op on sun4m -- no ACPI), while QMP supplies the
*confirmation* that it happened and a *clean hard-stop* when it doesn't.

The QMP-only capabilities (snapshot, VM liveness, clean container quit, orphan
handling) are **emulator concepts that don't exist on real hardware**. A real
SS-5 has no snapshot, no orphan-qemu, no qcow2 to flush. So the planes diverging
by deployment is correct, not a gap: the captive case has emulator-specific
concerns that warrant emulator-specific control; real iron doesn't have those
concerns at all and stays Helios-only.

## Verified qemu capability (qemu-9.2.4, `-M SS-5` / sun4m)

Checked against the vendored source in `~/dev/SPARCplug/qemu`, because
machine-specific gaps are the whole risk:

- **QMP is available** for the sparc system target (target-independent;
  `qemu-options.hx`). Expose it with `-qmp unix:<path>,server=on,wait=off`.
- **Clean-halt is a structured event.** Solaris `init 5` -> the PROM writes
  `AUX2_PWROFF` -> `qemu_system_shutdown_request(SHUTDOWN_CAUSE_GUEST_SHUTDOWN)`
  (`hw/misc/slavio_misc.c:266`), surfaced as the QMP `SHUTDOWN` event with
  `{ guest: true, reason: "guest-shutdown" }` (`qapi/run-state.json`). It fires
  *after* the FS sync (it's the last thing `init 5` does) and is distinguishable
  from a host kill (`host-qmp-quit`, `host-signal`).
- **`quit` is a clean hard-stop.** QMP `quit` runs `bdrv_drain_all_begin()` +
  `bdrv_close_all()` (`system/runstate.c`), flushing and closing the block layer
  so the qcow2 *container* is left consistent. SIGKILL does none of that. (The
  guest filesystem is still dirty either way -- you skipped `init 5` -- so it
  fscks; but the container metadata won't be torn mid-write.)
- **Snapshots should work for SS-5.** Every sun4m device (esp, lance/pcnet,
  slavio_*, m48t59 nvram, fdc, tcx/cg3) has a `VMStateDescription`, with no
  `migrate_add_blocker` / `unmigratable`. The lone stub without vmsd (the APC,
  `hw/misc/slavio_misc.c`) holds trivial state. So `savevm`/`loadvm` (QMP
  `snapshot-save`/`snapshot-load`) is very likely viable -- the gate for a
  "boot once, snapshot at the CDE desktop, fast-launch in ~2s" feature. **Wants a
  real round-trip on the live image before we bank it.**
- **`-action` and `-no-shutdown` are supported** (`qemu-options.hx`):
  `-action shutdown=pause` plus `-no-shutdown` makes a guest poweroff *pause*
  qemu instead of exiting, so the cleanly-halted state can be snapshotted.

## The new division of labor

| Concern | Today | Redesign |
|---|---|---|
| Graceful FS-clean shutdown | Helios `init 5` | **Helios `init 5`** (unchanged -- only FS-clean path on SPARC) |
| "Halted cleanly?" (auto-backup gate) | console string `syncing file systems... done` | **QMP `SHUTDOWN`, `reason: guest-shutdown`** |
| Hard stop / Force Quit | SIGTERM -> SIGKILL | **QMP `quit`** (qcow2-clean) -> SIGKILL only if QMP is wedged |
| VM liveness (alive/paused/stuck) | inferred from process + console | **QMP `query-status`**, continuous |
| OS liveness / "ready" | Helios `hello` (latch-once) | Helios `hello` for ready **+** heartbeat; QMP separates "VM dead" from "daemon wedged" |
| Console | `-nographic` stdio pipe (HUP-spins an orphan) | **`-serial unix:` socket** (reconnectable, no spin) |
| Stalled shutdown | nothing -- sits in `.shuttingDown` forever | **no-progress watchdog** -> surface Force Quit |
| Orphan control | Helios shutdown (secret-in-lock) + verified SIGKILL | **+ QMP `quit` via socket-in-lock** (clean, no guest, no network auth) + console reconnect |
| Fast launch | cold boot every time | **QMP `snapshot-save`/`snapshot-load`** (post-v1, de-risked) |

Graceful shutdown does *not* move: Helios `init 5` is still the only way to sync
UFS. QMP isn't replacing Helios; it covers the VM-level concerns Helios
structurally can't (it goes down with the box, so it can't report the clean
power-off; it can't flush the qcow2; it can't snapshot).

## Two structural changes

**1. A `QmpClient` (new component, SwiftXServerCore).** This is genuinely new and
is *not* a Helios variant. QMP is async + bidirectional -- events (`SHUTDOWN`,
`RESET`, `STOP`, `RESUME`) interleave with command responses -- where
`HeliosClient` is strict one-request-in-flight. So `QmpClient` needs a background
reader that demuxes events (`{"event":...}`) from responses
(`{"return":...}` / `{"error":...}`, correlated by an echoed `id`), the
`qmp_capabilities` handshake, and an event-handler callback. `QemuEngine` owns it
and becomes the orchestrator of two channels (QMP for the VM, the serial socket
for the console). `HeliosClient` stays untouched as the guest plane.

**2. The lock file becomes the "VM handle."** Today it records host / pid /
secret. Add the **QMP socket path and console socket path**. Then any later
process -- this Mac after a crash, another app instance -- can *fully* reattach
to an orphan: QMP `quit` it cleanly (no SIGKILL, no guest cooperation, no
auth-over-network), drive Helios `init 5` if it wants FS-clean (the secret is
already in the lock), and re-attach the console view. The orphan stops being "a
thing we can only SIGKILL" and becomes "a VM we can pick the lock back up on."
Same move as the secret-in-lock (`ImageLock.secret`, added 2026-06-24),
generalized.

## Staged rollout (do not big-bang)

This is the working lifecycle core; a rewrite risks regressing the boot /
shutdown / orphan flows that are currently solid. Staged, each independently
testable against the `SPARCPLUG_LIVE_TEST` harness:

- **Stage 0 (tiny, independent):** the no-progress shutdown watchdog. Pure timer
  on the existing console stream (reset on any console output or shutdown
  milestone; escalate to surfacing Force Quit only on silence past the window,
  never auto-execute it). No QMP needed.
- **Stage 1 (additive, low risk -- the v1 sweet spot). DONE + live-validated
  2026-06-25.** `QmpClient` (async, demuxes events from id-correlated responses;
  6 unit tests) + `QemuEngine` wiring: `-qmp unix:<sock>,server=on,wait=off` at
  launch, a post-launch connect-with-retry, the `SHUTDOWN` event
  (`reason: guest-shutdown`) as a backup clean-halt signal next to the console
  string, and Force Quit now prefers a qcow2-clean QMP `quit` (SIGTERM fallback).
  The console path is untouched (still the stdio pipe). **Live-validated against
  real qemu-9.2.4 / SS-5:** QMP handshake + `query-status: running`; a Helios
  `init 5` fired `SHUTDOWN {guest:true, reason:"guest-shutdown"}` then qemu
  exited; a QMP `quit` fired `SHUTDOWN {guest:false, reason:"host-qmp-quit"}` and
  exited cleanly -- so the reason field reliably separates a guest clean-halt
  from a host Force Quit, which is exactly the discrimination `handleQmpEvent`
  relies on.
- **Stage 2 (console surgery). DONE + live-validated 2026-06-25.** The console
  moved to a `-serial unix:<sock>,server=on,wait=off` socket, retiring the stdio
  pipe. `buildArguments` swaps `-nographic` for `-display none` + the `-serial
  unix:` socket + `-monitor none` (HMP off; the VM is driven through `-qmp`) when
  a console path is given (additive, same shape as the Stage 1 `-qmp` opt-in; the
  no-path default keeps the legacy `-nographic` form). New `SerialConsoleClient`
  (raw byte stream, SO_RCVTIMEO poll loop + reader-join on close, mirroring
  QmpClient's socket I/O; 5 unit tests) connects post-launch with the same
  connect-with-retry as QMP and streams bytes into `ingest` -- exactly where the
  old stdout handler delivered them, so clean-halt / fsck-stall / progress
  detection are unchanged. stdin is now `/dev/null` (the console no longer reads
  it) and stray qemu stdout is routed to the emulator-diagnostics path. **Live-
  validated against real qemu-9.2.4 / SS-5:** boot console streamed through the
  unix socket, and a QMP `quit` exited qemu cleanly with the socket files
  unlinked and no orphan. Closes the orphan CPU-spin (the console is a listening
  socket now, so our disconnect just drops the client) and lays the groundwork
  for console reconnect (Stage 3).
- **Stage 3:** lock-as-VM-handle (socket paths in the lock) + orphan QMP recovery
  + console reconnect. This is where the parked "reconnect to a live orphan" and
  "control off the stdio pipe" punchlist items actually close.
  - **Lock-as-VM-handle + orphan QMP recovery: DONE + live-validated 2026-06-25.**
    `ImageLock` gained `qmp:` and `console:` socket-path lines (optional,
    host-local like `pid`/`secret`; older locks still parse), written by
    `QemuEngine.start()` at acquire time. New `QemuEngine.quitOrphanViaQmp(
    qmpSocketPath:)` connects a *fresh* QmpClient to the path the lock records and
    issues a qcow2-clean `quit` -- the orphan teardown a *different* process drives
    with no process handle, no guest cooperation, no network auth. The
    AppDelegate orphan "Force Quit" now prefers it (off-main), falling back to the
    verified SIGKILL when the lock has no QMP socket or the channel is wedged.
    **Live-validated:** a directly-spawned orphan qemu (a lock but no controlling
    client, mirroring a dead parent) was clean-stopped via the socket read back
    out of its lock, and it exited. 4 new unit tests (lock round-trip + acquire +
    quitOrphanViaQmp success/missing-socket) + 1 live test. NB: qemu's QMP
    `server=on` socket is single-client, which is *why* this works only once the
    parent's connection is gone -- exactly the orphan case.
  - **Console-view reconnect (Design 2 -- engine adoption): DONE + live-validated
    2026-06-25.** On launch, `checkForReconnectableOrphanOnLaunch` evaluates the
    lock; on a `localOrphan` it probes Helios and prompts. `QemuEngine.attach(
    toOrphan:)` then drives the orphan as a live session *without a child Process*:
    it wires the QMP + console clients to the lock's socket paths, flips to
    `.running`, stamps a "reconnected to console" marker (the serial socket replays
    no history, so a late joiner sees a blank window otherwise), and -- since there's
    no `terminationHandler` -- detects exit by polling the pid (`scheduleOrphanDeathPoll`).
    A shared `finishRun()` is the single teardown both the spawned-process and
    adopted paths funnel through. Because the engine fires the same callbacks, the
    whole console UI follows for free, including clean-halt (the QMP `SHUTDOWN`
    event) -> auto-backup. **Graceful-first policy (per Todd):** the prompt leads
    with **Shut It Down** when Helios answers and only offers **Force Quit** when it
    doesn't; the console window mirrors it -- **Shut Down** while ready, **Force
    Quit** only when the daemon can't be reached (booting, wedged, or a graceful
    attempt failed, surfaced via the new `onShutdownUnavailable`). **Live-validated:**
    a spawned orphan was adopted (state -> running, marker landed) and clean-stopped
    through the adopted engine, with the no-Process death poll firing onTerminated.
    2 new unit tests + 1 live test. The full end-to-end (Xcode-stop a session,
    relaunch, reconnect) is a manual check.
- **Stage 4 (post-v1):** snapshot fast-launch, now that the sun4m vmstate support
  is verified.

If scoping for plugin v1: do **Stage 0 + Stage 1**. They are the high-safety,
low-risk wins and they don't disturb the working console. Stages 2-4 are
fast-follows.

## What it closes, what it leaves alone

Closes: brittle console-string clean-halt detection, the Force-Quit qcow2
corruption risk, the stalled-shutdown wedge, the orphan CPU-spin, and the latent
half of the liveness gap (QMP vs Helios tells you *which* layer died). Unlocks
the snapshot fast-launch feature.

Leaves alone: Helios, the real-iron path, and the "one mechanism, two clients"
story. QMP is purely the captive macXserver<->emulator channel, orthogonal to
everything Helios. End state: Helios daemon (guest) with its two clients (control
plane + future MCP bridge), *universal*; QMP (emulator) with one client
(QemuEngine), *captive-only*.

## Related docs

- `PLUGIN_V1_PUNCHLIST.md` -- the crash/orphan section (L0/L2/L3) is what Stages
  2-3 finally close; the "what's actually left for v1" summary should gain Stage
  0 + Stage 1 once this is signed off.
- `Helios-Mission.md` -- the guest plane this is orthogonal to.
- DECISIONS.md 2026-06-24 -- the settled-decision summary.
