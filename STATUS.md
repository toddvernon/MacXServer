# Status 2026-06-17

## FIRST THING on the other Mac (read before building)

The dev build now embeds the SPARCplug engine into `MacXServer.app` via a
Debug-only build phase that copies `~/dev/SPARCplug/dist`. For the
SPARCstation to run from an Xcode build on the other Mac, that `dist/` has
to exist there:

1. `git pull` both repos (`~/dev/X` and `~/dev/SPARCplug`).
2. In `~/dev/SPARCplug`: `./build-qemu.sh`, then
   `./packaging/bundle-dylibs.sh`, then
   `IDENTITY="Developer ID Application: CarePenguin, inc (X478U667PR)" ./packaging/codesign.sh`
   (ad-hoc `-` also runs, but only without hardened runtime; Developer ID is
   the faithful path). That produces `dist/{qemu-system-sparc, lib/, firmware/}`.
3. The Solaris image rides Dropbox at `~/Dropbox/dev/SPARCplug/SUN40G.qcow2`.
   In macXserver: Preferences → SPARCstation → Choose… that file (or a copy
   if you want to keep a pristine master; v1 boots read-write).
4. Build/run `MacXServer` in Xcode → SPARCstation → Start.

If `dist/` isn't built, the app still builds and runs; the SPARCstation
menu's Start just can't find the engine (the build phase logs a warning).

## What landed today

**Rename: SparkPlug → SPARCplug (it's a SPARCstation, not a spark plug).**
Swept the whole surface in one pass: the GitHub repo
(`toddvernon/SparkPlug` → `toddvernon/SPARCplug`, renamed in place, old URL
redirects), local dir (`~/dev/SPARCplug`), Dropbox asset dir
(`~/Dropbox/dev/SPARCplug`), every file in the SPARCplug repo, all
references across the macXserver repo, and memory.

**Plugin v1 integration — big progress.** The living checklist is
`PLUGIN_V1_PUNCHLIST.md` (decisions at top, Tracks A–E + a lifecycle
section). Done and committed today:

- **Track A (engine bundling) proven.** `packaging/bundle-dylibs.sh` now
  works end to end (fixed two real bugs: `-s` search path for the `@rpath`
  libslirp, and an `LC_RPATH` dedupe that modern dyld was aborting on). ROM
  staged into `dist/firmware`; the engine must launch with `-L` at it (the
  built-in firmware path is a dead build-tree absolute). Signed with the
  real Developer ID under hardened runtime + JIT entitlements and **booted
  Solaris to login** loading only bundled bits. A4 reframed: dev gets the
  engine via the Debug build phase; A5 (release.sh signed copy-in) and A6
  (clean-Mac) remain.
- **B1/B2: `QemuEngine`** (`Sources/SwiftXServerCore/QemuEngine.swift`) —
  spawns the engine, streams the serial console, state machine
  (notInstalled/stopped/running/shuttingDown), writable console.
- **B3: console observation window** with a full-width blue **boot
  thermometer** (grows on boot, recedes on shutdown, driven by console
  milestones).
- **D1: SPARCstation menu** (Start / Shut Down / Show Console / Back Up Disk
  Image). Start with no image opens a friendly hero-panel **welcome window**
  (Choose Image… / Download Starter Image… / Cancel), not an error alert.
- **Disk-image location is a Preferences setting** (`sparcDiskImagePath`,
  SPARCstation tab) — single source of truth for dev and release; the
  release downloader will write it at download time.
- **Graceful shutdown.** Auto-logs-in as root (image allows passwordless
  root console — verified; also the Helios prerequisite, on by default),
  `init 5` syncs/unmounts and powers off so qemu exits on its own. The
  positive "safe to power off" signal is the console line
  `syncing file systems... done` (verified empirically). Force Quit (hard
  kill, behind a confirm) for wedged cases.
- **Quit guard.** Quitting macXserver while the SPARCstation runs is refused
  with a dialog (Go to Console / Cancel) so the user shuts it down cleanly
  first — no orphaned qemu, no power-yank fsck.
- **Back Up Disk Image** menu item (stopped only): clones the qcow2 with a
  dated name.

## What's working / verified

- macXserver app + X server: untouched core, still green (full suite 1311
  tests pass).
- SPARCplug engine builds, relinks clean (zero `/opt/homebrew`), signs, and
  boots Solaris 2.6 to login under hardened runtime + JIT.
- `QemuEngine`: unit tests + two `SPARCPLUG_LIVE_TEST`-gated live tests —
  console streaming, and a full boot → auto-login → `init 5` → clean-halt →
  terminate cycle (~65s, runs against an APFS clone so the master image is
  never mutated). All pass.
- Xcode build (`MacXServer` scheme) green; project regenerated via
  `xcodegen generate` after the `project.yml` build-phase change.

## What's next (still plugin v1, BEFORE Helios)

1. **A5** — `release.sh`: after export, copy `dist/` into the `.app`, sign
   inside-out (dylibs → helper with `qemu.entitlements` → re-sign the app
   wrapper), then notarize. The signing recipe is already proven locally.
2. **A6** — clean-Mac acceptance (fresh account, no homebrew).
3. **Track C** — the real downloader behind "Download Starter Image…":
   NSURLSession + sha256 + gunzip into the user-chosen location, then write
   the path into `sparcDiskImagePath`. `manifest.json` + hosting on the
   OldSilicon CDN is the external piece.

Helios stays talk-only until plugin v1 ships.

## Pointers

- Living checklist: `PLUGIN_V1_PUNCHLIST.md`.
- Plugin design + milestone + licensing: `SPARCSTATION_PLUGIN.md`.
- Engine repo: `~/dev/SPARCplug` / `github.com:toddvernon/SPARCplug`
  (private). Build: `./build-qemu.sh` then `packaging/`.
- Assets (qcow2): `~/Dropbox/dev/SPARCplug/` (Dropbox-synced, not git).
- Dev engine resolution honors `SPARCPLUG_ENGINE_DIR` / `SPARCPLUG_DISK_IMAGE`
  env overrides (used by the live tests); the app normally resolves the
  engine from the bundle and the image from the Preferences setting.
