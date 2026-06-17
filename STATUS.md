# Status 2026-06-16

## FIRST THING TOMORROW (brain-fog edition)

**Open `~/dev/X/Tools/CX_PROCESS_TIMEOUT_AND_CWD.md` on this Mac and
follow it top to bottom.** That's the assignment.

The doc contains complete source for every change — no judgment calls,
no design decisions left to make in the morning. Concretely:

1. **Change 1**: replace `~/Dropbox/dev/cx/cx/process/process.h` with
   the version in the doc.
2. **Change 2**: replace `~/Dropbox/dev/cx/cx/process/process.cpp` with
   the version in the doc.
3. **Change 3**: delete one line (the vestigial
   `#include <cx/process/process.h>`) from
   `~/Dropbox/dev/cx/cx_apps/cm/ScreenEditorCommands.cpp` line 24.
4. **Change 4**: create three new files under
   `~/Dropbox/dev/cx/cx_tests/cxprocess/` and add one small block to
   `~/Dropbox/dev/cx/cx_tests/Makefile`. All source in the doc.
5. **Build + test on Mac.** Expect `12 passed, 0 failed`. Also confirm
   `cx_tests/cxbuildoutput` still passes (proves the popen-based legacy
   path didn't regress) and `cm` still builds (proves the include
   removal was safe).
6. **Same on Linux.**
7. **Same on SS5.** This is the highest-risk step — g++ 2.95.3 is the
   pickiest of the three. If something fails it'll be a missing header
   or a 2.95-incompatible idiom; the compile error will say where.

If all three platforms green: that's the end of tomorrow. We move
cx onto the bundled SparkPlug image and start seed-daemon design next
session.

If something breaks: capture the build/test output, drop it where I can
read it, ping me. The blast radius is tiny by construction (one new
overload, one new test file, one deleted include), so recovery is short.

**Helios is still talk-only until plugin v1 ships.** The cx-process
work is substrate enablement, not Helios code itself, so it's allowed
under the gate.

---

## The day, in four parts

**Morning (other Mac): distribution + bundling design.** Expanded
`SPARCSTATION_PLUGIN.md` with the "downloaded macXserver → booted CDE
with no homebrew or Terminal" path: on-demand plugin payload, the
homebrew-dep-tree problem, dylib bundling, codesign order with JIT
entitlements.

**Afternoon (other Mac): Solaris guest network bring-up.** Got 2.6
guest's slirp networking working end to end (outbound TCP/UDP, DNS,
default-route persistence) and converged it into
`Tools/sparcstation-baseline-config.sh`.

**Evening (this Mac): SparkPlug repo + minimal engine build +
distribution/licensing decisions.** New standalone private repo
`github.com:toddvernon/SparkPlug`, vendored qemu-9.2.4 (clean import,
not a fork), `build-qemu.sh` produces an 8.6 MB headless
`qemu-system-sparc` that boots Solaris 2.6 to login on emulated SS-5.
Engine-in-app + image-downloaded-on-demand decided; one bundle, not
fused; no `.pkg`.

**Late evening (this Mac): Helios talk-only design session.** Discussed
the post-plugin-v1 Helios architecture and made one substantial pivot:
file plane moves from NFS to a Sun-side access server written in cx C++,
exposing a small JSON-over-TCP verb set. Bootstrap framing established
(hand-build seed v0 → agent develops v1+). Survey script + cx
validation + sunfreeware additions docs written. Survey ran clean on
a real SS5 (g++ 2.95.3, GNU make 3.82, ar/ld all green; gdb/gawk/gsed/
ggrep missing). Made on cx libs ran clean: base/net/log/json/process
libs all built. Found that nothing in production cx code calls
`CxProcess::run()` — wide license to add overloads. Designed and wrote
the full source for adding cwd+timeout to CxProcess (the doc tomorrow
implements).

## What's working (verified today)

- **SparkPlug minimal QEMU engine builds and boots** (morning/evening of
  today; details in the previous STATUS lineage, unchanged).
- **Solaris image lives at `~/Dropbox/dev/Sparkplug/SUN40G.qcow2`**
  (1.3 GB actual / 42.9 GB virtual / ~250 MB gzipped).
- **macXserver app + server**: untouched today, still green.
- **NEW (this evening): cx libraries build clean on Solaris 2.6**
  (real SS5). Specifically: `libcx_base.a`, `libcx_net.a`, `libcx_log.a`,
  `libcx_json.a`, `libcx_process.a` all archived to `lib/sunos_/`. Zero
  errors, zero warnings.
- **NEW: Helios tool survey reports `Seed-server build: READY`** on the
  real SS5. Compile + sockets-link sanity both pass end-to-end.

## Decisions made today (all documented)

- **Engine ships IN the app; only the disk image downloads on demand.**
  `DECISIONS.md` 2026-06-16 entry + `SPARCSTATION_PLUGIN.md` 2026-06-16
  sections.
- **One app bundle, not a fused binary.** qemu as nested helper.
- **SparkPlug source stays in its own private repo** (not merged).
- **No `.pkg` installer.** Drag-to-Applications survives.
- **Licensing posture** captured (`SPARCSTATION_PLUGIN.md` "Licensing
  and attribution").
- **Build trims**: `--disable-png`, `--disable-pixman`,
  `--disable-dbus-display` (broken homebrew python@3.14 workaround).
- **NEW: Helios file plane is access-server-based, not NFS.** Sun-side
  daemon in cx C++ exposing JSON-over-TCP verbs (`write_file`,
  `read_file`, `run`, `list_dir` for v0). Captured in
  `Tools/CX_VALIDATION_ON_SOLARIS.md`, `Tools/CX_PROCESS_TIMEOUT_AND_CWD.md`,
  and the conversation transcript. Not yet promoted into
  `Helios-Mission.md` (it still says NFS); that update lands once plugin
  v1 ships and Helios goes from talk-only to design-and-build.
- **NEW: Bootstrap framing for seed daemon.** Build minimal v0 by hand,
  then use the agent to develop v1+ via the seed itself. v0 verbs are
  exactly what the agent needs to develop v1, nothing more.

## Not done / open

- `packaging/` scripts in SparkPlug (`dylibbundler` + codesign with JIT
  entitlements) are skeletons, NOT exercised. Unchanged from yesterday.
- The plugin has never been bundled into `MacXServer.app` or notarized.
  Unchanged.
- No menu/UI in macXserver for SparkPlug yet (install/run, observation
  window, launcher enable). Unchanged.
- **NEW: cx `CxProcess` cwd+timeout overload designed but not yet
  applied.** Full source in `Tools/CX_PROCESS_TIMEOUT_AND_CWD.md`.
  Tomorrow's first task.
- **NEW: Sunfreeware additions (gdb/gawk/gsed/ggrep) planned but not
  installed.** Plan in `Tools/SUNFREEWARE_ADDITIONS.md`. Not blocking
  the seed; install when image gets re-baked next.

## What to do next: still plugin v1 (BEFORE Helios)

This hasn't moved. Three deliverables, fully defined in
`SPARCSTATION_PLUGIN.md` → "Next milestone: shippable plugin v1":

1. **Engine-in-app binary, no disk image.** dylibbundler relink, JIT
   codesign, notarize. One uploadable `.app`.
2. **Menu installs the disk image on demand.** "Install SparkPlug"
   downloads + verifies sha256 + decompresses to Application Support;
   menu flips to "Run SparkPlug" and launcher entry un-grays.
3. **Run with observation window + enable the launcher.** Spawn engine,
   route `-nographic` serial console into an observation window, enable
   launcher to launch X clients into the guest.

Tomorrow's cx-process work doesn't progress plugin v1 directly; it
unblocks the seed daemon that comes after v1 ships. Both tracks can
move in parallel without conflict.

## Pointers

- SparkPlug engine: `~/dev/SparkPlug` (cloned today onto this Mac) /
  `github.com:toddvernon/SparkPlug` (private). Build with
  `./build-qemu.sh`; smoke test in its README.
- Plugin design + milestone + licensing: `SPARCSTATION_PLUGIN.md`.
- Decision record: `DECISIONS.md` (2026-06-16 entry).
- Helios (gated, design-only): `Helios-Mission.md`.
- Assets (qcow2): `~/Dropbox/dev/Sparkplug/` (Dropbox-synced, not git).
- **NEW: Helios tool survey** (read-only inventory of a Sun box):
  `Tools/helios-tool-survey.sh`. Run as `sh helios-tool-survey.sh
  > out.txt`.
- **NEW: cx validation on Solaris**: `Tools/CX_VALIDATION_ON_SOLARIS.md`.
- **NEW: Sunfreeware additions plan**: `Tools/SUNFREEWARE_ADDITIONS.md`.
- **NEW (TOMORROW'S TASK)**: `Tools/CX_PROCESS_TIMEOUT_AND_CWD.md` —
  complete source for the cwd + timeout overload on CxProcess.
