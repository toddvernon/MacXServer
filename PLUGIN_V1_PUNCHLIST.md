# Plugin v1 punch list

The living checklist for getting macXserver integrated with SPARCplug to
the "shippable plugin v1" milestone. The milestone itself is defined in
`SPARCSTATION_PLUGIN.md` ("Next milestone: shippable plugin v1"); this doc
turns its three deliverables into concrete, dependency-ordered tasks
against the actual code, and records the decisions we've settled so they
don't get relitigated.

Scope is plugin v1 only: download one app, install the disk image from a
menu, boot a working SPARCstation with the console visible, launch X
clients into it. No Helios, no QMP, no snapshot fast-launch. Those are
fast-follows, called out where relevant.

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
- [ ] **A4. Bundle layout / dev override.** Shipped layout: helper +
  `lib/` into `Contents/Helpers/` (dylibbundler rewrote to
  `@executable_path/lib/`, so the dylibs live next to the helper, NOT in
  `Contents/Frameworks/`); firmware into `Contents/Resources/qemu-firmware/`.
  The `dist/` layout already matches. Realized at release time by A5 (the
  `release.sh` copy-in), not a fragile pbxproj Copy Files phase. For dev,
  `QemuEngine.defaultConfig()` honors `SPARCPLUG_ENGINE_DIR` /
  `SPARCPLUG_DISK_IMAGE` so the controller runs against `dist/` with no
  bundle wiring at all (proven by the live test).
- [ ] **A5. `release.sh` copy-in + helper signing.** Copy the SPARCplug
  `dist/` payload in before signing; sign inside-out with the helper
  getting `qemu.entitlements`. (See settled decision above.) The local A3
  run already proves the signing recipe; `release.sh` just needs to run it
  on the in-bundle copy with the Developer ID instead of ad-hoc.
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

- [x] **Graceful shutdown.** `QemuEngine` now drives the serial console
  (writable stdin + `sendConsole`). On boot it auto-logs-in as root (the
  image allows passwordless root console login — also the Helios
  prerequisite, so it's on by default). `shutDown()` sends `init 5`; the
  guest syncs/unmounts and powers off, so qemu exits on its own.
  Empirically verified: the positive "safe to power off" signal is the
  console line `syncing file systems... done` (`onCleanHalt`), and `init 5`
  cleanly exits qemu (not parked at `ok`).
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
- [~] **L2. Orphan recovery UX. PARTIAL 2026-06-20.** The localOrphan dialog
  offers: **Try to Shut It Down** (best-effort `init 5` over the 2123 telnet
  hostfwd via `TelnetLauncher`, success measured by polling the pid to death,
  ~35s timeout → falls back to manual), **Force Quit** (verified SIGKILL),
  **Show Me How** (manual telnet steps), **Cancel**. Still TODO: (a) a
  **Reconnect** action that re-attaches the observation window to a live
  orphan — needs L3's console socket; (b) progress feedback during the telnet
  poll (currently silent for ~35s); (c) root-over-telnet is often refused on
  2.6, so "Try to Shut It Down" frequently can't authenticate — Force Quit +
  manual are the reliable paths today.
- [ ] **L3. Move console + control off the stdio pipe.** Today console +
  control ride `-nographic` stdio owned by the parent's `Pipe`; when the
  parent dies they're unreachable and qemu spins. Switch to
  `-serial unix:console.sock,server,nowait` (re-attachable console) +
  `-qmp unix:qmp.sock,server,nowait` (reliable liveness + hard `quit`).
  Then L2's Reconnect re-wires the observation window and Shut Down drives
  `init 5` over the serial socket — works even on an orphan. NB: SPARC has
  no ACPI, so QMP `system_powerdown` won't cleanly halt Solaris; graceful
  stays `init 5` over serial.
- [ ] **L4. (Optional) kqueue watchdog — true prevention.** A tiny guardian
  process spawns qemu and `kqueue`-watches the macXserver pid
  (`EVFILT_PROC`/`NOTE_EXIT`); on parent exit by *any* means including
  SIGKILL it drives `init 5` / SIGTERM→SIGKILL on qemu, then exits. The
  macOS substitute for `PR_SET_PDEATHSIG` and the only thing that stops the
  orphan existing at all. New helper binary → maintainer sign-off required.

## Track C — Install the disk image (Deliverable 2)

- [ ] **C1. Downloader** (new). `NSURLSession` w/ progress → SHA256 verify
  → gunzip → atomic move into `~/Library/Application Support/macXserver/`.
  Net-new: the app uses zero Application Support today (all `~/.macxserver-*`
  dotfiles), so this dir + absolute-path discipline is new but small.
- [ ] **C2. `manifest.json` + hosting.** version/url/sha256/size; gzipped
  qcow2 actually uploaded (OldSilicon CDN). External to the code.
- [ ] **C3. Install sheet + state detection.** State keys off "is the qcow2
  in Application Support."

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
- [ ] **D2. Launcher enable.** The `[host:qemu-ss5]` entry with
  `display = 10.0.2.2:0` already works end-to-end (the `display` key exists
  in `LauncherEntry`). v1 just un-grays it when the engine runs.
  Auto-materializing the entry is nice-to-have, not required.

## Track E — Shipping image

- [ ] **E1. Confirm `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` is the
  baseline-configured image** (the `Tools/sparcstation-baseline-config.sh`
  edits actually baked in), then gzip + host. Sunfreeware tools and the
  CDE-ready savevm snapshot are explicitly deferred past v1.

## Acceptance (from SPARCSTATION_PLUGIN.md)

On a clean Mac with no homebrew: drag the app in, "Install SPARCplug"
(downloads image), "Run SPARCplug" (boots, console visible in the
observation window, launcher enabled), launch xterm into the guest.
