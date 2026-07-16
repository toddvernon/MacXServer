# Plugin v1 punch list

The living checklist for getting macXserver integrated with SPARCplug to
the "shippable plugin v1" milestone. The milestone itself is defined in
`SPARCSTATION_PLUGIN.md` ("Next milestone: shippable plugin v1"); this doc
turns its three deliverables into concrete, dependency-ordered tasks
against the actual code, and records the decisions we've settled so they
don't get relitigated.

Scope (as originally written): download one app, install the disk image from
a menu, boot a working SPARCstation with the console visible, launch X clients
into it. The original draft said "No Helios" and treated it as a fast-follow --
that's now stale: Helios **landed** and is part of the product. See the
reconciliation below.

## What's actually left for v1 (reconciled 2026-06-24)

Most of this doc is done. The **Helios control plane** (HELIOS_PLAN C1-C8) landed
since this list was written and closed every control/shutdown/orphan item the
"Crash / orphan safety" section was reaching toward: graceful shutdown,
liveness, and orphan recovery all run over the daemon now, and the console
auto-login is gone (it's a read-only observation glass-TTY). Helios is no longer
a "fast-follow" -- it shipped, and brought DNS admin + the per-launcher file
browser with it (tracked in HELIOS_PLAN, beyond this doc's scope).

What's genuinely left before a stranger can install and run the combo, in
priority order:

1. **Package the engine into the signed app (Track A).** A5 + A4 DONE
   2026-07-10 (`release.sh` copy-in + inside-out signing wired in; see Track A
   below). What's left is A6 (clean-Mac acceptance on a fresh no-Homebrew
   account) plus the first real release run, which is the end-to-end proof of
   the wiring + notarization of the combined bundle.
2. **Install the disk image (Track C + E).** C1 + C3 DONE 2026-07-10 (the
   downloader pipeline, Download… on the Overview, welcome-window routing;
   see Track C below and IMAGE_DOWNLOAD_PLAN.md). What's left is the data
   half: E1 confirm the shipping images are baseline-configured **with the
   current Helios daemon baked in**, then run `build-catalog.sh` and upload
   to macxserver.com/images/ (C2's hosting half).
3. **Restore from Backup** (data safety, "fix before shipping"). Auto-backup
   exists; the in-app restore UI does not. The one real functional gap.
4. ~~**D2 launcher un-gray**~~ — closed by P2 (launchers gate on ready
   everywhere; see Track D).

Not v1: L4 (kqueue watchdog -- optional, needs maintainer sign-off) and the
re-attachable serial console for orphan reconnect (Helios covers control; the
console-view re-attach is a nice-to-have).

Most-likely-to-bite: **A6**. The embedded-helper signing failure only shows up
on a Mac that isn't yours, and it's exactly what makes "no Homebrew, just drag
it" either true or a support nightmare.

## Settled decisions (2026-06-17)

- **v1 boots cold.** No CDE-ready savevm snapshot in v1. Matches the
  written acceptance in `SPARCSTATION_PLUGIN.md`. Snapshot fast-launch
  (~2s to desktop) is the obvious fast-follow, not a v1 gate.
- **The engine artifact is pulled in by `release.sh`, before notarization.**
  SPARCplug's packaging produces the *relinked* engine (dylibbundler done,
  zero `/opt/homebrew`) but leaves signing to the app pipeline so there's a
  single identity. `release.sh` copies it into the bundle, signs inside-out
  (dylibs, then the helper with its JIT entitlements, then the app wrapper),
  then notarizes and staples the whole `.app` as one unit. The only new
  steps in `release.sh` are the copy-in and the helper-sign-with-second-
  -entitlements-file; the notarize/staple tail is unchanged.
- **Hardened runtime is already on.** `release.sh:174,187` already builds
  with `--options=runtime`, and the shipping app is notarized that way. So
  there is no "turn it on" step and no new risk to existing users: the
  current app already proves the X11 TCP listener, dotfile reads,
  `/tmp/macxcapture`, and `ssh`/`telnet` subprocess spawning all work under
  hardened runtime. Hardened runtime is *not* the sandbox (which stays
  off); its only teeth are library validation (load only same-Team-ID /
  Apple dylibs) and no-JIT-unless-entitled. Both bite only the new qemu
  helper, never the existing app surface.

## Track A — Engine into the app bundle (Deliverable 1)

Gating track. Nothing else ships until the engine is in `MacXServer.app`
and survives a clean-Mac load + notarization. Engine build already exists
(`~/dev/SPARCplug/qemu/build/qemu-system-sparc`, 8.6 MB).

- [x] **A1. Relink the dylibs. DONE 2026-06-17.** Ran
  `packaging/bundle-dylibs.sh` (after `brew install dylibbundler`).
  Produces `dist/qemu-system-sparc` + `dist/lib/` (7 dylibs: glib quartet
  + libintl + libpcre2 + libslirp), every load path rewritten to
  `@executable_path/lib/`, audited zero `/opt/homebrew` / `/usr/local`
  across the binary *and* every bundled dylib. `libffi` resolves to the
  system `/usr/lib/libffi.dylib`, so it is correctly not bundled (the doc's
  worry about it was stale). Two script fixes were needed and are now in
  `bundle-dylibs.sh`: (1) `-s` search path for the `@rpath`-referenced
  `libslirp` (otherwise dylibbundler prompts interactively and loops
  forever with no stdin); (2) an `LC_RPATH` dedupe pass — dylibbundler
  collapses several original rpaths onto the same `@executable_path/lib/`,
  and modern dyld aborts at load on duplicate `LC_RPATH`.
- [x] **A2. Bundle the OpenBIOS ROM and fix the firmware path. DONE
  2026-06-17.** The built binary's default `-L` points at the absolute
  build-tree path (`.../qemu/build/qemu-bundle/usr/local/share/qemu`),
  which does not exist on a customer machine. `bundle-dylibs.sh` now stages
  `qemu/pc-bios/openbios-sparc32` into `dist/firmware/`, and the engine
  controller (Track B) must pass an explicit `-L <bundled-firmware-dir>`.
  Confirmed: booting with `-L dist/firmware` gets the guest past OpenBOOT.
- [x] **A3. Sign-test locally. DONE 2026-06-17.** Note: ad-hoc (`-`) does
  NOT work under hardened runtime — library validation rejects the
  no-Team-ID dylibs ("different Team IDs"). Signed `dist/` with the real
  Developer ID (`CarePenguin, inc / X478U667PR`, same identity `release.sh`
  uses), hardened runtime + `qemu.entitlements` (`allow-jit` +
  `allow-unsigned-executable-memory`). Result: boots Solaris 2.6 to
  `login:` in ~14s loading only bundled dylibs + bundled ROM. This is the
  full production signing posture validated locally, minus notarization.
- [x] **A4. Bundle layout / dev override. DONE 2026-07-10** (realized by the
  A5 `release.sh` copy-in, which stages exactly this layout). Shipped layout: helper +
  `lib/` into `Contents/Helpers/` (dylibbundler rewrote to
  `@executable_path/lib/`, so the dylibs live next to the helper, NOT in
  `Contents/Frameworks/`); firmware into `Contents/Resources/qemu-firmware/`.
  The `dist/` layout already matches. Realized at release time by A5 (the
  `release.sh` copy-in), not a fragile pbxproj Copy Files phase. For dev,
  `QemuEngine.defaultConfig()` honors `SPARCPLUG_ENGINE_DIR` /
  `SPARCPLUG_DISK_IMAGE` so the controller runs against `dist/` with no
  bundle wiring at all (proven by the live test).
- [x] **A5. `release.sh` copy-in + helper signing. DONE 2026-07-10.**
  `release.sh` now (a) sanity-checks the SPARCplug payload up front for
  MacXServer releases — dist/ present, relink audit (zero
  `/opt/homebrew` / `/usr/local` in helper or dylibs via `otool -L`), and a
  version cross-check that the dist binary reports the `qemu.lock`-pinned
  QEMU version (ties the shipped binary to the GPL source bundle); (b) after
  export, copies helper + `lib/` into `Contents/Helpers/` and firmware into
  `Contents/Resources/qemu-firmware/`, signs inside-out (dylibs → helper
  with `qemu.entitlements` → outer app re-seal), and `codesign --verify
  --deep --strict`s the combined bundle before the unchanged notarize/staple
  tail. Also wired in the same change: the GPL corresponding-source bundle
  (`Tools/make-gpl-source-bundle.sh`) is assembled during the release and
  attached to the GitHub release next to the app zip, closing the
  GPL_SOURCE.md promise. Recipe re-validated 2026-07-10 on a scratch bundle
  with the real Developer ID: verify clean, JIT entitlements present, signed
  helper boots and loads bundled dylibs. First real release run PROVEN
  2026-07-16: v0.9.9 cut via `release.sh --beta` end to end (archive,
  embed, inside-out sign, notarize Accepted, staple validated, published
  to macxserver-beta with the GPL bundle attached). Remaining proof: A6.
- [ ] **A6. Clean-Mac acceptance.** Fresh account, no homebrew: drag app,
  confirm helper loads and boots. Catches a missed dylib sign (the
  library-validation failure mode).

## Track B — Run the engine (Deliverable 3 core)

- [x] **B1. `QemuEngine` controller. DONE 2026-06-17.**
  `Sources/SwiftXServerCore/QemuEngine.swift`, modeled on `SSHLauncher`
  (`Process`/`Pipe`/`readabilityHandler`/`terminationHandler`, dedicated
  queue, pure static `buildArguments` for testing). Resolves the helper via
  `defaultConfig()` (bundle `Contents/Helpers/` or dev override), passes the
  `-L` firmware path + `-drive` at the qcow2. `onConsole` streams the serial
  console; `onStateChange` reports transitions. Tests in
  `QemuEngineTests.swift`: argv pinned, path resolution (both modes), state,
  and a `SPARCPLUG_LIVE_TEST`-gated live boot that spawned the real engine
  and streamed console in 0.3s (uses a throwaway disk, never a real qcow2).
- [x] **B2. Engine state model. DONE 2026-06-17.** `notInstalled → stopped →
  running` on `QemuEngine.State`, computed from disk-image presence + run
  state, surfaced via `onStateChange`. Wiring it to the menu label and
  launcher-entry enable is Track D.
- [x] **B3. Observation window. DONE 2026-06-17.**
  `Sources/SwiftXServer/SparcPlugConsoleWindowController.swift`, modeled on
  `LaunchProgressWindowController` (NSPanel + SwiftUI monospaced transcript,
  autoscroll). Read-only console with a state dot (running/stopped/no-image).
  Wired to `QemuEngine.onConsole`. Known v1 limitation: transcript grows
  unbounded over a long session (same as the launcher progress window); cap
  later if it matters.

## Lifecycle & shutdown safety (added 2026-06-17)

Not in the original three deliverables, but a correctness requirement: a
hard kill of qemu leaves Solaris (non-logging UFS) needing fsck on next boot,
and quitting the app without stopping the engine would orphan a headless
qemu. All DONE 2026-06-17.

- [x] **Graceful shutdown.** *(Mechanism superseded by Helios -- see L0/L2/L3.
  This described the original console-driven path; `shutDown()` now drives the
  Helios `shutdown` verb, the console auto-login was removed, and the console is
  read-only. The clean-halt detection below is unchanged and still gates the
  auto-backup.)* The guest syncs/unmounts and powers off, so qemu exits on its
  own. The positive "safe to power off" signal is the console line
  `syncing file systems... done` (`onCleanHalt`), and `init 5` cleanly exits
  qemu (not parked at `ok`).
- [x] **States + UI.** Added `State.shuttingDown`. Console window has
  Shut Down + Force Quit buttons and shows a "Filesystems synced — safe to
  power off" banner when the clean-halt signal lands. Menu: Start / Shut
  Down SPARCstation / Show Console / Back Up Disk Image.
- [x] **Quit guard.** `applicationShouldTerminate` refuses to quit while the
  SPARCstation is running (`.terminateCancel`) and pops a dialog — "Go to
  Console" (reveals the console so the user can Shut Down) / "Cancel". The
  user shuts the guest down cleanly, then quits. Prevents both the orphaned
  qemu and the power-yank fsck.
- [x] **Boot thermometer.** Full-width blue progress bar across the top of
  the console window, driven by `QemuEngine` console milestones (`onProgress`):
  grows as the guest boots, recedes as it shuts down.
- [x] **Force quit.** `kill()` (SIGTERM) behind a confirm dialog, for wedged
  cases.
- [x] **Back Up Disk Image.** Menu item enabled only when stopped; copies the
  qcow2 alongside itself with a dated `... backup <date>.qcow2` name (APFS
  clonefile via copyItem). Manual backups are never auto-pruned.
- [x] **Auto-backup on clean shutdown (2026-06-17).** Default-on Preferences
  setting (SPARCstation tab; off = "live dangerously"). On every *verified
  clean halt* -- never a hard kill -- macXserver clones the image to a dated
  `... autobackup <date>.qcow2` sibling and prunes to the newest 5. Fires off
  `QemuEngine.onTerminated`, which now reports whether the run ended via the
  `syncing file systems` signal so we only ever copy a known-good image. The
  naming + rotation policy is the pure, unit-tested `SparcBackup` in
  SwiftXServerCore; the load-bearing test pins that rotation never selects the
  master or a manual backup. This is a rolling "last known good" that protects
  *future* sessions; it only refreshes on clean exits (a crashy session makes
  no copy, which is correct -- you never snapshot a dirty image).
- [ ] **Restore from Backup (deferred -- fix before shipping).** There's no
  in-app way to roll the master back to one of those autobackups yet. The
  intended shape is a stopped-only "Restore from Backup…" menu item (mirroring
  Back Up's gating): list autobackups + manual backups newest-first, default
  to the most recent, and on confirm rename the current master aside (e.g.
  `... before-restore <date>.qcow2`) before copying the chosen backup into the
  image path -- a *restore*, not a boot-from-backup (v1 boots read-write, so
  booting a backup in place would consume it). The pick-and-restore logic is
  pure and belongs alongside `SparcBackup`. **Workaround for now:** the user
  swaps the image file by hand (or repoints Preferences → SPARCstation) before
  launching. v1 must ship with the real UI.
- [x] **Tests.** Unit tests plus two `SPARCPLUG_LIVE_TEST`-gated live tests:
  console streaming, and a full boot → auto-login → `init 5` → clean-halt →
  terminate cycle (passes in ~65s, runs against an APFS clone so the master
  image is never mutated). Plus `SparcBackupTests` (7) for the auto-backup
  naming + rotation policy.

## Crash / orphan safety (added 2026-06-19 — loop back here)

The quit guard above stops the *clean-quit* orphan, but not the ones that
matter most: stopping the Xcode debug session, an app crash, or a SIGKILL
all bypass `applicationShouldTerminate` (SIGKILL can't be caught, and macOS
has no `PR_SET_PDEATHSIG`). Result: a headless qemu keeps running, holding
the qcow2 open, spinning at 100% CPU because its console pipe reader died
with the parent. Hit this for real 2026-06-19 (a ~17h orphan, shut down by
hand over the telnet hostfwd). The latent corruption risk is worse than the
orphan: nothing stops a *second* qemu from opening the same qcow2.

**Strategic resolution (DECISIONS 2026-06-20): the Helios control-plane daemon
is the destination for all of this** -- and it has since **LANDED** (HELIOS_PLAN
C1-C8, deployed + verified on the live image 2026-06-24). The guest-side agent
gives a real `shutdown` verb (graceful `init 5` that also works on an orphan,
since the daemon outlives the parent) and a real liveness signal -- the
shippable control channel L0/L2/L3 were all reaching toward. So those three are
now **closed via Helios** (see each below); graceful shutdown, readiness, and
orphan recovery run over the daemon, superseding the telnet/ssh/console-scrape
paths. L1 (lock) + Force Quit + auto-backup remain the safety floor. See
`Helios-Mission.md` and DECISIONS 2026-06-20.

- [x] **L1. Image lock file. DONE 2026-06-20.** `ImageLock` /
  `ImageLockManager` in SwiftXServerCore: host-aware advisory lock written
  next to the image (so it works across the two Macs sharing the qcow2 via
  Dropbox — a local pid is meaningless on the other machine). `QemuEngine`
  acquires it (with the qemu pid) on start and releases on clean exit.
  `AppDelegate.launchSparcStation` pre-flights via `evaluate()`:
  free → boot; staleSameHost (our host, dead pid) → reclaim + boot;
  remoteLocked (other host) → hard stop with Reveal-Lock-in-Finder (user
  deletes it); localOrphan (our host, live pid verified as our qemu) →
  dialog. Force Quit re-verifies it's still our qemu (via `proc_pidpath`)
  before SIGKILL so a recycled pid is never killed. 10 unit tests pin the
  decision tree + parse/serialize + release-by-host. Caveats accepted: lock
  is advisory (qemu's own fcntl lock doesn't cross Dropbox) and cross-machine
  detection is best-effort (Dropbox sync latency).
- [x] **L2. Orphan recovery UX. Graceful path DONE via Helios 2026-06-24.**
  The localOrphan dialog offers: **Try to Shut It Down**, **Force Quit**
  (qcow2-clean QMP `quit` -> verified SIGKILL fallback; see (d)), **Show Me How**
  (manual steps), **Cancel**.
  - (b) **DONE 2026-06-20.** The silent ~35s poll is a live panel
    (`SparcShutdownProgressWindowController`): countdown + progress bar while
    waiting, auto-dismiss + boot on power-off, and on timeout it flips in place
    to an actionable failure state (Force Quit / Show Me How / Cancel).
  - (c) **Graceful shutdown now works -- over Helios, not telnet.** The old
    telnet path was dead (Solaris 2.6 refuses root telnet); it's replaced by
    `attemptHeliosShutdown`, which drives the daemon's `shutdown` verb (`init 5`)
    over the 2125 hostfwd and polls the pid to death. The daemon outlives the
    parent, so it answers even for an orphan. **The auth gap is closed
    (2026-06-24):** the per-boot Helios secret is persisted in the image lock
    (`ImageLock.secret`), so a *different* macXserver process (this Mac after a
    crash, or the other Mac via the Dropbox-synced lock) can authenticate to the
    orphan's daemon. Force Quit + auto-backup remain the fallback when the daemon
    is unreachable. The failure-panel + by-hand copy was de-telnet-ified.
  - (a) **Reconnect** to a live orphan -- **DONE 2026-06-25 (VM_CONTROL Stage 3,
    Design 2 "engine adoption").** On launch, `checkForReconnectableOrphanOnLaunch`
    detects a `localOrphan`, probes Helios, and prompts; `QemuEngine.attach(
    toOrphan:)` adopts it as a live session (QMP + console wired to the lock's
    sockets, no child Process, pid-poll for exit, "reconnected to console" marker).
    The whole console UI + clean-halt -> auto-backup follow because the engine fires
    the same callbacks. Graceful-first: Shut It Down when Helios answers, Force Quit
    only when it doesn't. Engine adoption live-validated; the end-to-end relaunch
    flow is a manual check.
  - (d) **Force Quit is now qcow2-clean (VM_CONTROL Stage 3, 2026-06-25).** The
    orphan Force Quit prefers `QemuEngine.quitOrphanViaQmp` -- a fresh QmpClient on
    the QMP socket path the lock records, issuing a `quit` that drains + closes the
    block layer so the container isn't torn mid-write. Verified SIGKILL remains the
    fallback when the lock has no QMP socket or the channel is wedged. The guest FS
    is still dirty either way (no `init 5`), so it still fscks next boot; the win is
    container integrity.
  - (Former footgun resolved: "Try to Shut It Down" can now actually work, so it
    being the default button is fine.)
- [x] **L3. Move *control* off the stdio pipe. DONE -- both halves now landed.**
  The original plan was a `-serial unix:` socket + `-qmp unix:` socket so control
  survived the parent's death, and **both shipped** (VM_CONTROL Stages 1-3,
  2026-06-25): the `-qmp` socket gives a qcow2-clean orphan `quit` (its path is in
  the lock), and the `-serial unix:` socket retired the stdio pipe (closing the
  orphan CPU-spin) and makes the console re-attachable. The Helios daemon already
  closed the *graceful* control half (liveness via `hello`, `init 5` shutdown incl.
  orphans). The lone residual is the *console view* re-attach UI (L2a Reconnect) --
  still non-v1. (QMP was never the graceful path: SPARC has no ACPI, so
  `system_powerdown` won't halt Solaris; graceful is `init 5`, via Helios.)
- [x] **L0. Drop console auto-login; control off the console. DONE.** Graceful
  shutdown is the Helios `shutdown` verb (`QemuEngine.requestShutdownViaDaemon`
  / `performDaemonShutdown`, no console fallback) and readiness is the Helios
  `hello` probe, so the console drives no control. The auto-login was removed:
  `ingest()` only reads the console (forward to UI + clean-halt/fsck/progress
  markers) and there is no `sendConsole`/type-`root` anywhere -- it's a pure
  observation glass-TTY, which also decouples macXserver from the guest's
  password policy. (Stale "auto-logs-in as root" wording survives in the
  Lifecycle section below and one code comment; both are vestigial.)
- [ ] **L4. (Optional) kqueue watchdog — true prevention.** A tiny guardian
  process spawns qemu and `kqueue`-watches the macXserver pid
  (`EVFILT_PROC`/`NOTE_EXIT`); on parent exit by *any* means including
  SIGKILL it drives `init 5` / SIGTERM→SIGKILL on qemu, then exits. The
  macOS substitute for `PR_SET_PDEATHSIG` and the only thing that stops the
  orphan existing at all. New helper binary → maintainer sign-off required.

## Track C — Install the disk image (Deliverable 2)

(Superseded in shape by IMAGE_DOWNLOAD_PLAN.md — per-machine images and a
per-OS catalog replaced the single manifest.json — and built to that design
2026-07-10.)

- [x] **C1. Downloader. DONE 2026-07-10.** `ImageCatalog` + `ImageDownloader`
  in SwiftXServerCore: catalog fetch on click → confirm with real sizes →
  stream w/ progress → sha256(gz) → gunzip → sha256(image) →
  `GuestOSDetector` banner check → atomic move into
  `~/Library/Application Support/macXserver/Images/`. 13 tests against
  file:// fixtures; temp partials never survive a failure.
- [ ] **C2. Catalog + hosting.** Script half DONE 2026-07-10
  (`build-catalog.sh` emits catalog.json + gz payloads with both checksums).
  Hosting half OPEN: upload the staging dir to macxserver.com/images/
  (the pinned URL; DECISIONS 2026-07-10) — gated on E1.
- [x] **C3. Install flow + state detection. DONE 2026-07-10.** Download… on
  the Overview of any imageless emulated VM with a known OS (the OS keys the
  catalog — wrong-image-to-wrong-machine impossible by construction); the
  welcome window's Download routes into the same flow; the row thermometer
  does download duty with per-phase status text and Cancel; on success the
  image attaches to the machine and Start goes live. No auto-boot.

## Track D — UI glue

- [x] **D1. Menu + install flow. DONE 2026-06-17.** Top-level "SPARCstation"
  menu in `AppDelegate.installMainMenu()`: Start / Stop / Show Console (no
  separate Install item — Start handles the missing-image case).
  `validateMenuItem`: Start enabled when not running, Stop when running.
  Start with an image boots + opens the console; with no image it presents a
  friendly hero-panel window (`SparcStationWelcomeWindowController`) — graphic
  + explanation of the bundled emulator + Choose Image… / Download Starter
  Image… / Cancel — not a system error alert. The disk-image path is a
  Preferences setting (`sparcDiskImagePath`, SPARCstation tab with
  Choose/Reveal/Clear); it's the source of truth for dev and release and
  where the location is changed after first run. Engine config rebuilds on
  path change. Engine binary resolves from the app bundle in release, and
  from a Debug-only `project.yml` build phase that embeds
  `$SRCROOT/../SPARCplug/dist` in dev.
- [x] **D2. Launcher enable. DONE (closed by P2, 2026-07-06).** Launcher
  chips + Machines-menu items on emulated machines gate on the guest being
  up and ready (`launcherEnabled`, one shared rule), and the bundled
  fixtures seed their launcher groups. Nothing left here.

## Track E — Shipping image

- [ ] **E1. Confirm `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` is the
  baseline-configured image** (the `Tools/sparcstation-baseline-config.sh`
  edits actually baked in), then gzip + host. Sunfreeware tools and the
  CDE-ready savevm snapshot are explicitly deferred past v1.

## Acceptance (from SPARCSTATION_PLUGIN.md)

On a clean Mac with no homebrew: drag the app in, "Install SPARCplug"
(downloads image), "Run SPARCplug" (boots, console visible in the
observation window, launcher enabled), launch xterm into the guest.
