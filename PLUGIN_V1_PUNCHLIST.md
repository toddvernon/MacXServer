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
- [ ] **A4. Xcode bundle wiring.** New Copy Files phase: helper into
  `Contents/Helpers/qemu-system-sparc` with its `lib/` subdir alongside
  (dylibbundler rewrote to `@executable_path/lib/`, so the dylibs live next
  to the helper, NOT in `Contents/Frameworks/`). Firmware dir
  (`openbios-sparc32`) into `Contents/Resources/qemu-firmware/` (or
  alongside the helper). The `dist/` layout already matches this:
  `qemu-system-sparc` + `lib/` + `firmware/`.
- [ ] **A5. `release.sh` copy-in + helper signing.** Copy the SPARCplug
  `dist/` payload in before signing; sign inside-out with the helper
  getting `qemu.entitlements`. (See settled decision above.) The local A3
  run already proves the signing recipe; `release.sh` just needs to run it
  on the in-bundle copy with the Developer ID instead of ad-hoc.
- [ ] **A6. Clean-Mac acceptance.** Fresh account, no homebrew: drag app,
  confirm helper loads and boots. Catches a missed dylib sign (the
  library-validation failure mode).

## Track B — Run the engine (Deliverable 3 core)

- [ ] **B1. `QemuEngine` controller** (new, `SwiftXServerCore`). Clone the
  `Process`/`Pipe`/`readabilityHandler`/`terminationHandler` pattern from
  `SSHLauncher.swift:52-119` (the only subprocess code in the tree, exactly
  the right shape). Resolve the helper by absolute `Bundle.main` path
  (app-translocation-safe). Arg vector from the working recipe
  (`SPARCSTATION_PLUGIN.md:219-225`) plus the `-L` firmware path from A2 and
  `-drive` pointing at the Application Support qcow2.
- [ ] **B2. Engine state model.** `notInstalled → installedStopped →
  running`. Drives the menu label and the launcher-entry enable state.
- [ ] **B3. Observation window.** Reuse `LaunchProgressWindowController`
  (its `appendText` + AttributedString + autoscroll model is already a
  streaming console). Pipe qemu `-nographic` stdout in. Read-only for v1.

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

- [ ] **D1. Menu item** in the App menu (`AppDelegate.swift:155-232`),
  label flips `Install SPARCplug → Run/Stop SPARCplug` off the B2 state.
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
