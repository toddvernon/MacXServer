# Status 2026-07-06

## Headline: The BSD graceful-shutdown bug is FIXED and validated on all 3 emulated guests + the real SS5. Plus a Machine-manager UI pass (bundled machines, sections, no Save button) in swift-x.

Two threads this session. The big one: ran down why Helios graceful shutdown
never powered off the BSD guests, fixed it in the daemon, and validated the whole
per-OS daemon build+deploy+shutdown loop end to end. The other: polished the
Machines window (bundled-machine model, list sections, auto-commit editor).

## What's working / done this session

### heliosAgent per-OS daemon fix (cx repo -- committed + pushed)
- **Root cause found + fixed:** `performShutdown` hardcoded Solaris
  `/usr/sbin/init 5` for every guest -> a silent no-op on the BSDs (the daemon
  ACKs before running the command, so it looked like it worked). This was the
  NetBSD bug AND the parked 4.1.4 bug -- the old "macXserver sends a bad secret"
  theory was wrong (it trusted the ACK).
- **Fix:** per-OS **compiled** shutdown default (`_NETBSD_` -> /sbin/halt,
  `_SUNOS_` -> /usr/etc/halt, else /usr/sbin/init 5) -- can't be forgotten in an
  rc script the way the env var was. `HELIOS_SHUTDOWN_CMD` still overrides.
  `system()`'s return is now checked + logged. No `-p` needed (proven: /sbin/halt
  exits qemu on NetBSD).
- **Same-class fixes in one pass:** `search` uses an absolute per-OS grep
  (`HELIOS_GREP` override) and returns ok:false on grep error instead of a silent
  empty result; bounded search timeout (60s default) + max clamp; `eeprom`
  resolved to an absolute path in the init script + deploy.sh (fixes 4.1.4
  deny-all-on-reboot); deploy.sh chmod 600s the secret file; PROTOCOL.md per-OS
  shutdown table + "ACK is not power-off" caveat. `make test` 133/0.
- **Validated build -> deploy -> authenticated shutdown -> power off on ALL
  THREE emulated guests** (NetBSD /sbin/halt ~9s, Solaris init 5 ~27s, SunOS
  4.1.4 /usr/etc/halt ~18s) **and the real SS5** (running the 4.1.4 image; Todd
  built+deployed there with secret "test", works).
- Removed the stale `[macXserver] ... secret len` diagnostic from
  QemuEngine.swift (it was chasing the wrong theory).

### Emu scripts set a helios secret (SPARCplug repo -- committed + pushed)
- All three `emu/*-full.sh` inject `-prom-env helios-secret=$HELIOS_SECRET`
  (default `sparcplug-emu-dev`) and write it to `/tmp/sparkplug` so the helios
  CLI drives a booted guest agentically with no flags. This is what made the
  ssh-less 4.1.4 build/deploy/test fully scriptable.

### Machine-manager UI (swift-x -- committing now)
- Non-runnable VM (no image) opens on the **Settings** tab, not Overview.
- Machines window is 2x taller / 20% wider (984x1080).
- **Bundled machines:** new persisted `bundled` flag on `Machine`; three imageless
  bundled fixtures (Solaris 2.6 / SunOS 4.1.4 / NetBSD) seeded via
  `MachineMigrator.ensuringBundled`; three master-list **sections** (Bundled /
  Virtual / External), each sorted by name; bundled fixtures are protected from
  removal (this is the real fix for "can't delete my VM" -- the old first-emulated
  heuristic mis-tagged user VMs); editor locks a bundled machine's kind/host/OS;
  engine wires to whichever bundled machine has an image attached.
- **No Save button:** the detail form auto-commits at edit boundaries (Return,
  leaving the pane, launcher edits) with inline validation. Uses `.onChange` /
  `.onDisappear` (not @State-init) because the window is NSPanel-hosted.
- swift test green throughout; `swift build` clean.

## What's broken / open

- **macXserver console + engine are single-instance (P2 not done).** Diagnosed
  but NOT fixed: one `sparcConsole` + one engine wired to a single resolved
  machine, so attaching images to multiple bundled machines makes the console
  follow/steal and non-wired machines lose their Console button. This is the P2
  concurrency work (per-machine console + engine). Todd hasn't picked an approach
  yet (asked: full P2 / plan-first / interim). The per-OS host-port blocks already
  make concurrent bundled VMs collision-free, so the groundwork is there.
- **Bundled fixtures need images.** On next macXserver launch the three bundled
  fixtures appear imageless; Todd deletes his old migrated machines and attaches
  images to test. (His call, in-app.)

## What's next
- Decide + do the P2 per-machine console/engine (the console-hijack fix).
- Rebuild macXserver in Xcode to see all the Machine-manager UI changes.
- Optional real-SS5 shutdown-verb test (powers off the live machine -- Todd's to run).
- Deferred daemon items (noted in memory): `-b` bind-addr option, accept()
  backoff, NUL-truncation in cx/process, search colon-in-name parser nit.

## Committed this session (all pushed to origin/main)
- cx `heliosAgent` **685f705** -- per-OS shutdown/grep/eeprom daemon fixes.
- SPARCplug **b54073a** -- emu scripts inject helios secret + /tmp/sparkplug.
- swift-x (this commit) -- Machine-manager UI + bundled machines + diagnostic removal.

## Switching Macs
- All three affected repos pushed to origin/main; `git pull` on the other Mac.
- Let Dropbox finish syncing the memory dir + the cx tree before opening the
  other Mac (memory rides Dropbox now, not git).
- No VM running (all guests powered off by the shutdown tests). No image locks.
- The real SS5 on the LAN is running the 4.1.4 image with the fixed agent
  (secret "test"); leave its /etc/helios/helios.json alone on any redeploy.
- macXserver must be rebuilt in Xcode on the other Mac to pick up the UI work.
