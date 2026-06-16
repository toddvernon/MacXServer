# Status 2026-06-16

A full day on the SPARCstation-plugin direction, mostly design and a
real engine build. No macXserver server code or tests were touched
today; the work landed in docs, a new `Tools/` guest script (earlier),
and a brand-new standalone repo (this evening). macXserver itself is
unchanged and remains green from the last server-side work.

## The day in three parts

**Morning (other Mac): distribution + bundling design.** Expanded
`SPARCSTATION_PLUGIN.md` with the "how does a user get from downloaded
macXserver to booted CDE without homebrew or Terminal" answer:
on-demand plugin payload, the homebrew-dep-tree problem, dylib
bundling, codesign order with JIT entitlements.

**Afternoon (other Mac): Solaris guest network bring-up.** Got the
2.6 guest's slirp networking working end to end (outbound TCP/UDP,
DNS, default-route persistence) and converged it into
`Tools/sparcstation-baseline-config.sh`, which turns any Solaris 2.6
install into the slirp-shaped baseline. Full recipe + gotchas are in
`SPARCSTATION_PLUGIN.md`.

**Evening (this Mac): SparkPlug repo + minimal engine build +
distribution/licensing decisions.** The big one. Details below.

## What's working (verified today)

- **SparkPlug minimal QEMU engine builds and boots.** New standalone
  private repo `github.com:toddvernon/SparkPlug` (local `~/dev/Sparkplug`).
  Vendored qemu-9.2.4 (clean import, not a fork, `roms/` pruned).
  `build-qemu.sh` produces an 8.6 MB headless `qemu-system-sparc`
  (sparc-softmmu, TCG + slirp only, all UI/codec/crypto/audio off) that
  boots Solaris 2.6 to a `login:` prompt on emulated SS-5. Non-system
  dylib deps trimmed to just `libslirp` (our bundled subproject) + the
  glib quartet, so the only real external dep is glib.
- The Solaris image now lives at `~/Dropbox/dev/Sparkplug/SUN40G.qcow2`
  (1.3 GB actual / 42.9 GB virtual / ~250 MB gzipped). Boots clean from
  there.
- macXserver app + server: unchanged today, still green.

## Decisions made today (all documented)

- **Engine ships IN the app; only the disk image downloads on demand.**
  Code-vs-data seam. `DECISIONS.md` 2026-06-16 entry + the 2026-06-16
  sections of `SPARCSTATION_PLUGIN.md`.
- **One app bundle, not a fused binary.** qemu stays a nested helper
  spawned as a subprocess (event-loop/JIT/crash isolation, and it keeps
  macXserver non-GPL via mere aggregation).
- **SparkPlug source stays in its own private repo**, not merged into
  the public macXserver repo (GPL bulk, repo-size, license boundary).
- **No `.pkg` installer**; drag-to-Applications survives.
- **Licensing posture** captured in `SPARCSTATION_PLUGIN.md`
  ("Licensing and attribution"): About/Licenses panel with full license
  texts + per-component version + "unmodified" statement + source link;
  OpenBIOS ROM needs an explicit upstream source link because we pruned
  `roms/`.
- Build trims learned the hard way: `--disable-png`, and `--disable-pixman`
  (QEMU's internal fallback backs the cold-path TCX surface; I was wrong
  that pixman was mandatory, proved it by building without it). macOS
  build gotcha: homebrew `python@3.14` has a broken pyexpat; fixed with
  an isolated system-python venv + `--disable-dbus-display`.

## Not done / open

- `packaging/` scripts in SparkPlug (`dylibbundler` + codesign with JIT
  entitlements) are skeletons, NOT exercised. `dylibbundler` isn't even
  installed yet, and there's no Developer ID wiring.
- The plugin has never been bundled into `MacXServer.app` or notarized.
- No menu/UI in macXserver for SparkPlug yet (install/run, observation
  window, launcher enable).

## What to do next: shippable plugin v1 (BEFORE Helios)

This is the agreed next batch. Three deliverables, defined fully in
`SPARCSTATION_PLUGIN.md` → "Next milestone: shippable plugin v1":

1. **Engine-in-app binary, no disk image.** Bundle qemu + glib dylibs
   into `MacXServer.app` (Helpers/ + Frameworks/), `dylibbundler` relink
   (zero `/opt/homebrew` paths), codesign with JIT entitlements,
   notarize. One uploadable `.app`.
2. **Menu installs the disk image on demand.** "Install SparkPlug"
   downloads the ~250 MB gzipped qcow2 to Application Support (absolute
   path), verifies sha256, decompresses; menu flips to "Run SparkPlug"
   and the launcher entry un-grays.
3. **Run with an observation window + enable the launcher.** Spawn the
   engine as a subprocess, route the `-nographic` serial console into an
   observation window, enable the launcher to launch X clients into the
   guest.

Acceptance: clean Mac, no homebrew. Drag app in, Install (downloads
image), Run (boots, console visible, launcher enabled), launch xterm.

**Helios is talk-only until plugin v1 ships.** A future session may
discuss `Helios-Mission.md` (it now carries a DO-NOT-IMPLEMENT-YET
banner) but must not write any Helios code until the three deliverables
above are done. Deliberate sequencing.

## Pointers

- SparkPlug engine: `~/dev/Sparkplug` / `github.com:toddvernon/SparkPlug`
  (private). Build with `./build-qemu.sh`; smoke-test recipe in its README.
- Plugin design + milestone + licensing: `SPARCSTATION_PLUGIN.md`.
- Decision record: `DECISIONS.md` (2026-06-16 entry).
- Helios (gated, design-only): `Helios-Mission.md`.
- Assets (qcow2): `~/Dropbox/dev/Sparkplug/` (Dropbox-synced, not git).
