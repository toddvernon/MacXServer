# Status 2026-06-25 (end of day, session 3)

VM control day. Took the QMP Stage 1 foundation from earlier today and drove the
whole `VM_CONTROL.md` rollout to completion: Stages 2 + 3, then the Design-2
reconnect feature on top, then the quit-time detach dialog, then dev-secret
continuity across a detach. macXserver can now hand a running SPARCstation off to
the background and pick it back up next launch.

## Where things stand

**VM control Stages 1-3 are all done + live-validated** (`VM_CONTROL.md` rollout
section has the per-stage detail). The captive qemu is driven through two planes:
Helios (guest OS) and QMP (the VM). What landed this session:

- **Stage 2 -- serial console on a socket.** Console moved off the `-nographic`
  stdio pipe onto `-serial unix:<sock>,server=on,wait=off` (+ `-display none` +
  `-monitor none`). New `SerialConsoleClient` streams it. Closes the orphan
  CPU-spin (the console is a listening socket now, so our disconnect just drops
  the client) and makes the console re-attachable. `buildArguments` keeps the
  legacy `-nographic` form when no console path is given (additive, like the
  Stage 1 `-qmp` opt-in).

- **Stage 3 -- lock-as-VM-handle + qcow2-clean orphan recovery.** `ImageLock`
  records the QMP + console socket paths (`qmp:` / `console:`, host-local like
  pid/secret). `QemuEngine.quitOrphanViaQmp(qmpSocketPath:)` connects a fresh
  QmpClient to the path the lock records and issues a qcow2-clean `quit` (drains +
  closes the block layer) -- the orphan Force Quit prefers it, SIGKILL fallback.

- **Stage 3 Design 2 -- reconnect to an orphaned VM on launch.** This is the big
  one. On launch, `checkForReconnectableOrphanOnLaunch` detects a `localOrphan`,
  probes Helios, and prompts. `QemuEngine.attach(toOrphan:)` adopts an
  already-running qemu as a live session WITHOUT a child Process: wires QMP +
  console to the lock's sockets, flips to `.running`, stamps a "reconnected to
  console" marker (the serial socket replays no history, so a late joiner sees a
  blank window otherwise), and detects exit by polling the pid (no
  terminationHandler). A shared `finishRun()` is the single teardown both
  lifecycle paths funnel through. Because the engine fires the same callbacks, the
  whole console UI follows for free, including clean-halt -> auto-backup.
  **Graceful-first policy (per Todd):** the prompt leads with Shut It Down when
  Helios answers and only offers Force Quit when it doesn't; the console window
  mirrors it (Shut Down while ready, Force Quit only when the daemon can't be
  reached, via the new `onShutdownUnavailable` signal that closes the old
  told-to-Force-Quit-with-no-button dead-end).

- **Quit-with-VM-running dialog.** `applicationShouldTerminate` used to refuse
  outright. Now it offers **Quit and Detach** (leave qemu running in the
  background; the lock persists so the next launch offers to reconnect), **Go to
  Console** (shut Solaris down cleanly first), or Cancel. Detaching is safe now
  (no CPU-spin, reconnectable) -- same outcome as the Xcode-stop path.

- **Dev-secret continuity on detach.** On a detach the guest keeps running, so its
  Helios secret is still live. A `detachingSparcOnQuit` flag tells
  `applicationWillTerminate` to PRESERVE the Claude-dev secret file (`/tmp/sparkplug`)
  so Claude Code keeps daemon access while we're quit; reconnect re-writes it from
  `lock.secret` on relaunch.

## What's working

- Full suite green: **1415 tests, 0 failures** (31 skipped = the live tests).
- New tests: `SerialConsoleClientTests` (5), QMP orphan-quit + lock-socket
  round-trip + acquire (4), `attach` reject (1), plus 3 live tests
  (`testLiveBootStreamsConsole`, `testLiveOrphanQmpQuitViaLock`,
  `testLiveAdoptOrphanLifecycle`) all passing against real qemu-9.2.4 / SS-5.
- Both the Xcode `SwiftXServerCore` and `MacXServer` schemes build clean
  (xcodegen regenned to pick up `SerialConsoleClient.swift`).
- **Reconnect validated live by Todd** end-to-end (boot, Xcode-stop to orphan,
  relaunch, reconnect prompt -> connected console). "works great."

## What's broken / rough edges

- The end-to-end **Quit and Detach** dialog and the **dev-secret-on-detach** path
  haven't had a manual click-through yet (logic + build verified, suite green).
  Worth a quick manual pass: Cmd-Q with the VM up -> Detach -> relaunch ->
  reconnect, and confirm `/tmp/sparkplug` survives the detach in Claude-dev mode.
- Console-reconnect "Ignore at launch" edge: if you decline the reconnect prompt
  while the VM runs, the launch-time secret-file wipe leaves Claude without the
  file until you reconnect. Minor, non-v1.

## What's next

- **Stage 4 (post-v1): snapshot fast-launch.** `snapshot-save`/`snapshot-load`
  for a "boot once, snapshot at the CDE desktop, fast-launch in ~2s" feature. The
  sun4m vmstate support is verified in `VM_CONTROL.md`; wants a real round-trip on
  the live image before we bank it.
- **Helios (the standing thread):** C6 more guided-sysadmin tasks; B6 daemon
  `make test` on Solaris + 2 hardening items (orphan-reap, shutdown
  euid/exit-status).

## What's committed (recent, all pushed)

- `~/dev/X` (ahead 0 / behind 0):
  - 12b4871 -- preserve the Claude-dev secret file on Quit and Detach.
  - 0de9591 -- quit dialog: Quit and Detach vs Go to Console.
  - ab914f2 -- regenerate Xcode project (pick up SerialConsoleClient.swift).
  - 3c0abbd -- Stage 3 Design 2: reconnect to an orphaned VM (engine adoption).
  - 30404d7 -- Stage 3: lock-as-VM-handle + qcow2-clean orphan QMP recovery.
  - 4b862c8 -- Stage 2: serial console on a -serial unix: socket.
- `~/dev/SPARCplug` (ahead 0 / behind 0) and the cx tree: unchanged this session.

## Switching to the other Mac

- A SPARCstation VM is **still running** on this Mac (Todd's real SUN40G.qcow2,
  from testing reconnect). It holds the image lock on the Dropbox-synced qcow2.
  Left up on purpose. If you switch Macs, the other Mac will see `remoteLocked` on
  that image until this VM shuts down (or you detach + let it run, knowing the
  lock is held). Shut it down here first if you want the other Mac to boot it.
- Let Dropbox finish syncing the memory dir before opening the other Mac.
- `git pull` X (SPARCplug / cx unchanged but pull anyway).
- `/sos` first.

## Pointers

- VM control: `Sources/SwiftXServerCore/SerialConsoleClient.swift` (console
  socket), `QmpClient.swift` (QMP), `QemuEngine.swift` (`attach(toOrphan:)`,
  `finishRun`, `quitOrphanViaQmp`, death poll, `buildArguments`),
  `ImageLock.swift` (qmp/console paths). UI in `AppDelegate.swift`
  (`checkForReconnectableOrphanOnLaunch`, `reconnectToOrphan`,
  `presentReconnectPrompt`, `applicationShouldTerminate`) and
  `SparcPlugConsoleWindowController.swift` (graceful-first controls).
- Design + rollout: `VM_CONTROL.md`. Punchlist crash/orphan: `PLUGIN_V1_PUNCHLIST.md`
  (L2a/L3 closed).
