# Status 2026-06-17 (end of day)

Two work sessions today across both Macs. The morning (desktop) landed the
SparkPlug→SPARCplug rename and the bulk of the plugin v1 integration
(QemuEngine, console window, menu, graceful shutdown). The afternoon
(laptop) brought the engine up on the second Mac, fixed three things that
broke a clean-checkout build, and added auto-backup on clean shutdown.

## Building the engine (now reproducible from a clean checkout)

For the SPARCstation to run from an Xcode build, `~/dev/SPARCplug/dist`
has to exist (the dev build embeds it into `MacXServer.app` via a
Debug-only build phase). Both Macs have it built as of today. To rebuild
from scratch:

1. `git pull` both repos (`~/dev/X` and `~/dev/SPARCplug`).
2. Build deps (one-time, homebrew): `dylibbundler ninja meson pkg-config`
   + `glib pixman pcre2 libffi gettext`.
3. In `~/dev/SPARCplug`: `./build-qemu.sh`, then
   `./packaging/bundle-dylibs.sh`, then
   `IDENTITY="Developer ID Application: CarePenguin, inc (X478U667PR)" ./packaging/codesign.sh`.
   Produces `dist/{qemu-system-sparc, lib/, firmware/}`.
4. The Solaris image rides Dropbox at `~/Dropbox/dev/SPARCplug/SUN40G.qcow2`.
   In macXserver: Preferences → SPARCstation → Choose… that file (v1 boots
   read-write).
5. Build/run `MacXServer` in Xcode → SPARCstation → Start. If `dist/` isn't
   built, the app still builds; the build phase logs a warning and Start
   can't find the engine.

## What landed today (afternoon / laptop session)

**Engine built + verified on the second Mac.** Live test (`QemuEngineTests`,
`SPARCPLUG_LIVE_TEST`) boots Solaris 2.6 end to end -- boot → auto-login →
`init 5` → clean halt -- against an APFS clone, 7/7 green. Xcode build embeds
the signed engine into `MacXServer.app` (Helpers/ + Resources/qemu-firmware/),
hardened runtime intact, zero homebrew leaks.

**Three clean-checkout build fixes (SPARCplug `f2fd12d`).** The build only
worked on the Mac that did the original tarball import; a fresh git history
failed three ways, all now fixed in the build scripts:
- `build-qemu.sh`: `--disable-install-blobs` (meson was validating non-sparc
  firmware blobs like `pc-bios/s390-ccw.img` that the blanket `*.img`
  gitignore keeps out of the repo).
- `build-qemu.sh`: build the `qemu-system-sparc` target explicitly (bare
  `ninja` left only the unsigned binary and built the whole qtest suite).
- `bundle-dylibs.sh`: stage `openbios-sparc32` into `dist/firmware/` -- the
  step the punch list claimed was done but that never made it into the
  committed script. `QemuEngine` passes `dist/firmware` as `-L`; without it
  the engine can't boot past OpenBOOT.

**Local rename finished on the laptop.** `~/dev/SparkPlug` → `~/dev/SPARCplug`
+ remote URL repointed. GitHub repo and the Dropbox asset dir were already
renamed (the laptop pull worked via the old-URL redirect); only the local
working tree was stale. Both Macs now match.

**Auto-backup on clean shutdown (macXserver `113a197`).** Default-on
Preferences setting (SPARCstation tab; off = live dangerously). On every
*verified clean halt* -- never a hard kill -- macXserver clones the image to
a dated `... autobackup <date>.qcow2` sibling and prunes to the newest 5.
Fires off `QemuEngine.onTerminated`, which now reports whether the run ended
via the `syncing file systems` signal. Naming + rotation is the pure,
unit-tested `SparcBackup` in SwiftXServerCore (`SparcBackupTests`, 7 tests;
the load-bearing one pins that rotation never selects the master or a manual
backup). Manual "Back Up Disk Image" copies use a distinct marker and are
never auto-pruned.

## What's working / verified

- macXserver app + X server: untouched core, still green.
- SPARCplug engine: builds reproducibly from a clean checkout on both Macs,
  relinks clean (zero `/opt/homebrew`), signs under hardened runtime + JIT,
  boots Solaris 2.6 to login and halts cleanly via `init 5`.
- `QemuEngine`: unit tests + two live tests (console streaming; full
  boot→login→`init 5`→clean-halt→terminate, ~65s against an APFS clone).
- Auto-backup: `SparcBackup` rotation/naming policy unit-tested.
- Xcode `MacXServer` build green; engine embedded in the .app.

## What's next (still plugin v1, BEFORE Helios)

1. **A5** -- `release.sh`: copy `dist/` into the `.app`, sign inside-out
   (dylibs → helper with `qemu.entitlements` → app wrapper), notarize +
   staple. Signing recipe proven locally on both Macs now.
2. **A6** -- clean-Mac acceptance (fresh account, no homebrew).
3. **Track C** -- the real downloader behind "Download Starter Image…":
   NSURLSession + sha256 + gunzip, then write `sparcDiskImagePath`.
   `manifest.json` + OldSilicon CDN hosting is the external piece.
4. **Restore from Backup UI (fix before shipping).** Auto-backup captures
   known-good copies but there's no in-app way to roll back to one yet.
   Intended: a stopped-only "Restore from Backup…" menu item (pick newest,
   rename current master aside, copy the chosen backup into the image path).
   Workaround for now: swap the image file by hand. See PLUGIN_V1_PUNCHLIST.md.

Helios stays talk-only until plugin v1 ships.

## Pointers

- Living checklist: `PLUGIN_V1_PUNCHLIST.md`.
- Plugin design + milestone + licensing: `SPARCSTATION_PLUGIN.md`.
- Engine repo: `~/dev/SPARCplug` / `github.com:toddvernon/SPARCplug` (private).
- Assets (qcow2): `~/Dropbox/dev/SPARCplug/` (Dropbox-synced, not git).
- Dev engine resolution honors `SPARCPLUG_ENGINE_DIR` / `SPARCPLUG_DISK_IMAGE`
  env overrides (used by the live tests); the app resolves the engine from
  the bundle and the image from the Preferences setting.
