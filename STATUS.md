# Status 2026-07-05 (late)

## Headline: Machine Manager P1c shipped (in-app editor, OS detection, per-OS boot). SunOS 4.1.4 boots + runs through the app. Graceful shutdown of 4.1.4 is the one open bug — daemon proven innocent, it's a macXserver-side thing, parked with a diagnostic in place.

## Shipped + committed (pushed to origin/main)

- **`cba8a81` — Machine Manager P1c.** One unified Machines window (master list +
  Overview/Settings tabs): add / edit / remove / clone machines + launchers in-app,
  registry is authoritative, launcher-file reconcile retired. `GuestOSDetector`
  (qcow2 banner scan) locks the OS at image-pick time. Per-OS boot wiring
  (`unit=3` + `boot sd@3,0` for 4.1.4) — validated to multiuser via a headless
  snapshot boot. Per-OS Helios host port (readiness/xterm/DNS-admin now hit the
  right block). Console header shows the running OS.

## Shipped this session (committing now, see the guest-OS-profile commit)

- **Guest OS profile** (`MachineOS`, exhaustive switches; `GUEST_OS_PROFILE.md`).
  The forcing function so a Solaris assumption can't silently break a BSD guest —
  grew out of the shutdown bug. `QemuEngineConfig` carries a single `os` and
  derives disk unit / boot-command / clean-halt markers / X bin dirs from it.
  Routed the scattered Solaris literals (halt marker, X PATH in `launchXterm` +
  `HeliosLauncher`) through it.
- **Shutdown watchdog** — if the guest doesn't halt within 90s of an ACK'd
  shutdown, surface "use Force Quit" instead of hanging (the no-silent-failure
  half).
- **Temporary diagnostic (REMOVE once shutdown is fixed):** `launchXterm` +
  `requestShutdownViaDaemon` emit `[macXserver] {xterm,shutdown}: helios port N,
  secret len M` to the console, to catch the shutdown-secret bug below.

## The one open bug: 4.1.4 graceful shutdown (Shut Down → Force Quit, VM never exits)

**Symptom:** Start 4.1.4 → green → xterm works → click Shut Down → button flips to
Force Quit, VM stays green, never exits. (Workaround: console login → `su` →
`sync; sync; halt`, the gold path; or Force Quit.)

**Proven today (not guessed):**
- The **daemon is innocent.** Hitting it directly via `~/dev/SPARCplug/helios/helios
  --port 2135 shutdown` with the running guest's real secret (`/tmp/sparkplug`,
  matches the qemu `-prom-env`) returns a clean `{"ok":true,"result":{"status":
  "shutting down"}}`. Auth is uniform across verbs (`Dispatch.cpp` authOk before
  dispatch); `hello`/`run`/`shutdown` are the same request shape. So the daemon
  accepts shutdown with the correct secret.
- Therefore **macXserver is sending a bad shutdown request** — almost certainly a
  wrong/empty secret (or, if the secret turns out correct, a read race against the
  daemon closing the connection right after the ACK — the daemon DOES stop
  listening post-shutdown, confirmed).
- Every static code path says shutdown should send the same `currentSecret` that
  xterm/readiness use (same engine, `controller?.engine`), so the divergence is a
  runtime state I couldn't pin statically.

**Tomorrow, first thing:** rebuild, repro (Start → green → xterm → Shut Down), read
the two `[macXserver] … secret len` lines in the console.
- `shutdown secret len == 0/-1` → empty secret at shutdown → hunt the engine/secret
  mismatch (suspect: two engine instances, or `currentSecret` nil on the engine the
  console's `controller?.engine` resolves to). Then remove the diagnostic.
- `shutdown secret len == xterm's (~32)` → NOT the secret → fix is in
  `HeliosClient.readEnvelope` racing the daemon's close-after-ACK.

Then: land the real per-OS shutdown command guest-side (`HELIOS_SHUTDOWN_CMD=
/usr/etc/halt` on 4.1.4, `/sbin/halt` NetBSD, in the SPARCplug guest-config
deploy — see SHORTCUTS "per-OS shutdown"), so once auth is fixed the daemon runs a
command that actually halts 4.1.4 (today it runs Solaris `/usr/sbin/init 5`, a
no-op there).

## Housekeeping / gotchas
- I killed the running 4.1.4 daemon with a CLI `shutdown` test — the VM's qemu is
  still up but its daemon is dead (connection refused). Force Quit or `sync;sync;
  halt` it before tomorrow's clean repro.
- swift test 1469 pass. No new source files → no xcodegen needed.
