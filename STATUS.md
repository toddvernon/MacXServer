# Status 2026-06-17 (end of day)

A long day across both Macs. Morning (desktop): SparkPlug→SPARCplug
rename + the bulk of the plugin v1 integration (QemuEngine, console
window, menu, graceful shutdown). Afternoon/evening (laptop): brought the
engine up on the second Mac and made the build reproducible, added
auto-backup on clean shutdown, sanitized the console output, and pivoted
the Helios access model off NFS onto a Sun-side agent on a port.

## Building the engine (reproducible from a clean checkout)

For the SPARCstation to run from an Xcode build, `~/dev/SPARCplug/dist`
must exist (the Debug build phase embeds it into `MacXServer.app`). Both
Macs have it built. To rebuild from scratch:

1. `git pull` both repos (`~/dev/X` and `~/dev/SPARCplug`).
2. Build deps (one-time, homebrew): `dylibbundler ninja meson pkg-config`
   + `glib pixman pcre2 libffi gettext`.
3. In `~/dev/SPARCplug`: `./build-qemu.sh`, then
   `./packaging/bundle-dylibs.sh`, then
   `IDENTITY="Developer ID Application: CarePenguin, inc (X478U667PR)" ./packaging/codesign.sh`.
   Produces `dist/{qemu-system-sparc, lib/, firmware/}`.
4. Solaris image rides Dropbox at `~/Dropbox/dev/SPARCplug/SUN40G.qcow2`.
   Preferences → SPARCstation → Choose… it (v1 boots read-write).
5. Build/run `MacXServer` in Xcode → SPARCstation → Start.

## What landed today

**Engine reproducible + verified on the second Mac.** Three clean-checkout
build fixes (SPARCplug `f2fd12d`): `--disable-install-blobs`, build the
`qemu-system-sparc` target explicitly, and stage `openbios-sparc32` into
`dist/firmware/` (the punch list claimed this but it was never in the
committed script). Live test boots Solaris 2.6 end to end (boot →
auto-login → `init 5` → clean halt) against an APFS clone, 7/7 green.
Xcode build embeds the signed engine into the .app, no homebrew leaks.

**Auto-backup on clean shutdown (macXserver `113a197`).** Default-on
Preferences setting (off = live dangerously). On every verified clean halt
-- never a hard kill -- clones the image to a dated
`... autobackup <date>.qcow2` sibling and prunes to the newest 5. Pure,
unit-tested `SparcBackup` (rotation never selects the master or a manual
backup). `QemuEngine.onTerminated` now reports clean-vs-hard so we only
copy known-good images.

**Console output sanitized; the spinner animates (macXserver `0d757eb`).**
New `ConsoleSanitizer` (Core, pure, 15 tests). Strips ANSI/CSI/OSC escapes
+ BEL (does NOT honor clear-screen -- append-only log keeps scrollback),
interprets CR/LF/BS/TAB with a line buffer. The console model renders
committed lines + a live current line, so the `\|/-` Sun boot spinner
cycles in place. This is also the rendering half of the future glass-TTY
escape hatch.

**Helios access model pivoted off NFS (docs only; `ba7cc17`, `a196567`,
`0d7fbec`).** Decision recorded in DECISIONS.md (2026-06-17): the sole
mechanism is a **Sun-side guest agent on a TCP port** (slirp `hostfwd`)
proxying command execution + filesystem access; the serial console is a
secondary mix-in for boot/recovery/observation. NFS/NAS and the
terminal-fd command channel are **deprecated** (Helios-Mission.md
rewritten; the NFS sections in SPARCSTATION_PLUGIN.md fenced off as
historical). Added: a curated **image-repair GUI** (Phase 0.5 -- ~10
common fixes like vfstab/network via the agent's file primitives, no
terminal) and the **dev-on-emulator / deploy-on-iron parity** point (same
agent reaches SPARCplug over slirp and a real Sun over its network).

**Terminal-emulator question resolved (no emulator).** Helios routes
commands through the agent and full-screen observation through the X-side
framebuffer; the repair GUI absorbs the config-fix use cases; recovery is
roll-back-to-backup, not repair-in-place. So: no VT100 emulator ever; the
console stays read-only observation; a minimal glass TTY is a contingency
only for a hard-down pre-agent `fsck`, built only if that need shows up.

## What's working / verified

- macXserver app + X server: untouched core, still green.
- SPARCplug engine: reproducible clean build on both Macs, signed under
  hardened runtime + JIT, boots Solaris and halts cleanly via `init 5`.
- `QemuEngine`: unit tests + two live tests (console streaming; full
  boot→login→`init 5`→clean-halt→terminate, ~65s on an APFS clone).
- Auto-backup (`SparcBackupTests`) + console sanitizer
  (`ConsoleSanitizerTests`) unit-tested.
- Xcode `MacXServer` build green; engine embedded in the .app.

## What's next (still plugin v1, BEFORE Helios)

1. **A5** -- `release.sh`: copy `dist/` into the `.app`, sign inside-out
   (dylibs → helper with `qemu.entitlements` → app wrapper), notarize +
   staple. Recipe proven locally on both Macs.
2. **A6** -- clean-Mac acceptance (fresh account, no homebrew).
3. **Track C** -- the real downloader behind "Download Starter Image…"
   (NSURLSession + sha256 + gunzip, then write `sparcDiskImagePath`).
4. **Restore from Backup UI (fix before shipping).** Roll the master back
   to an autobackup (stopped-only menu item; rename master aside; copy the
   chosen backup in). Workaround for now: swap the image by hand. See
   PLUGIN_V1_PUNCHLIST.md.

Helios stays talk-only until plugin v1 ships. Its design is now settled on
the agent-on-a-port model (see Helios-Mission.md + DECISIONS.md).

## Pointers

- Living checklist: `PLUGIN_V1_PUNCHLIST.md`.
- Plugin design + milestone + licensing: `SPARCSTATION_PLUGIN.md`.
- Helios design: `Helios-Mission.md`; access-model decision in DECISIONS.md.
- Engine repo: `~/dev/SPARCplug` / `github.com:toddvernon/SPARCplug` (private).
- Assets (qcow2): `~/Dropbox/dev/SPARCplug/` (Dropbox-synced, not git).
- Dev engine resolution honors `SPARCPLUG_ENGINE_DIR` / `SPARCPLUG_DISK_IMAGE`
  env overrides (live tests); the app resolves engine from the bundle,
  image from the Preferences setting.
