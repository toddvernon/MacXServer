# Status 2026-06-19 (end of day)

Shipped the SPARCstation **shared folder (TFTP)** feature end-to-end, fixed
a Debug-build code-signing footgun that was silently killing the bundled
engine, and cleaned up three Preferences-dialog regressions. Engine + image
untouched and healthy (qemu-img clean, boots fine). TFTP transfer verified
into the live guest.

## What landed today

**Shared folder (TFTP).** New Preferences → SPARCstation toggle "Use a
shared folder to copy files into the SPARCstation," off by default, default
location `~/macXserverTFTP` (created on enable; Choose/Reveal to relocate).
When on, `QemuEngine` appends `,tftp=<dir>` to the slirp `-nic` line, so the
guest pulls files with `tftp 10.0.2.2` (binary; get). Wired
`Preferences` → `makeSparcConfig()` → `QemuEngine.buildArguments`; dev
override `SPARCPLUG_TFTP_DIR`. Off = byte-identical `-nic` to before (pinned
by test). `fullemu.sh` default flipped to the same `~/macXserverTFTP` for
dev/product parity. `guest/set-hostname.sh` (Solaris 2.6 rename script)
added to the SPARCplug repo and dropped in the shared folder as the first
real payload.

**Debug code-signing fix (the silent "Stopped" bug).** Xcode Debug ad-hoc
signs the `.app`, but the embedded qemu helper is Developer-ID + hardened
runtime — an inconsistent nesting that AMFI SIGKILLs at launch (exit 137,
no console, app stuck on "Stopped"). `project.yml`'s Debug-only embed
post-build step now re-signs the helper + dylibs ad-hoc after copying, so
they match the ad-hoc app. Release path (`release.sh`, uniform Dev-ID +
hardened + notarized) is unaffected — that's the posture this bug can't
occur in. Saved to memory.

**Preferences dialog fixes.** (1) Tab bar was collapsing into a `>>`
overflow menu — the SPARCplug iteration added a 6th tab ("SPARCstation")
without widening the 560pt window; bumped to 720 so all six fit on top.
(2) Opening from the menu now always lands on the first tab (Cut/Paste);
the reused window controller had been retaining the last tab. (3) The tall
SPARCstation tab was clipping top+bottom; wrapped it in a ScrollView and
raised the window to 560 high. SwiftUI TabView has no per-tab auto-resize
(AppKit's NSTabViewController does); ScrollView is the robust answer.

## What's working / verified

- macXserver app + X server + bundled engine: green. Engine boots the image
  cleanly (verified standalone via dist/ and the re-signed bundle helper).
- SUN40G.qcow2: `qemu-img check` clean, `corrupt: false`. Survived an
  orphaned-qemu episode (below) with no damage.
- Shared folder: enabled, file dropped, `tftp 10.0.2.2` get succeeded into
  the guest. "Restart to apply" note shows live while the engine runs.
- `swift build` + `xcodebuild` Debug both clean; QemuEngine tests pass
  (added 3 for the tftp arg + env override).

## What broke / lesson (the orphan episode)

Stopping the Xcode debug session SIGKILLs the app but **orphans the child
qemu** — it kept the master qcow2 open ~17h pegged at 100% CPU (its console
pipe reader died with the parent). Shut it down by hand via the telnet
hostfwd (`init 5`). No `PR_SET_PDEATHSIG` on macOS, and the
`applicationShouldTerminate` quit guard never runs on SIGKILL/crash, so
nothing reaps it. Worse latent risk: nothing stops a *second* qemu from
opening the same qcow2 (corruption, not just fsck).

## What to do next (agreed loop-back)

1. **Image lock file.** On engine start, write pid + image path to a known
   file; on launch, refuse to open an image a live pid already holds. Kills
   the double-open corruption risk. Cheap, do first. (Punchlist: Lifecycle.)
2. **Orphan detection + recovery.** Detect a live orphan on launch and offer
   Reconnect / Shut Down. Enabled by moving console + control off the dying
   stdio pipe onto unix sockets (`-serial unix:`, `-qmp unix:`), so a
   recovery path can re-attach and drive `init 5` after the parent died.
3. **(Optional) kqueue watchdog** — the only true *prevention* (survives
   parent SIGKILL); needs a new helper, so maintainer call.

Plus deferred polish: wrap all Preferences tabs in ScrollView (only
SPARCstation done) and a final text/sizing sweep.

## Pointers

- Shared folder default: `~/macXserverTFTP`. Guest pull: `tftp 10.0.2.2`,
  `binary`, `get <file>`.
- Plugin v1 work: `PLUGIN_V1_PUNCHLIST.md` (orphan/lockfile under Lifecycle).
- Dev launcher: `~/Dropbox/dev/SPARCplug/fullemu.sh` (homebrew qemu).
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ dated sibling).
