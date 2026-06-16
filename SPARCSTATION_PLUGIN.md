# SPARCstation Plugin

A "plug-in vintage SPARCstation" for macXserver. Open the app, see a
working Solaris desktop. No install, no configuration, no separate VM
manager. The X server you already shipped becomes both display surface
AND control plane for a bundled QEMU sun4m engine and a pre-baked
Solaris 2.6 disk image.

This doc captures the work that landed on 2026-06-15 to prove the
architecture, the working recipe, and the path from "I have a script
that works on Todd's machine" to "shippable feature of macXserver."

Sibling to `Helios-Mission.md` (which describes the AI-workbench
direction the plugin substrate also unlocks).

## Why this matters

`PROJECT.md` defines macXserver as a display server for vintage Sun
X apps. That product needs the user to own (or remotely reach) actual
Sun hardware. The audience is small: people with SPARCstations.

Adding a bundled emulator widens the audience by a large multiplier
without breaking the product's identity. The pitch becomes "a working
SPARCstation 5 in a Mac app." Same target environment (vintage Sun),
same display server, same launcher UX, plus an emulator under the
hood that the user never has to think about. The user-visible product
is still "macXserver"; the bundled emulator is invisible scaffolding.

The unlock is two-fold:
- **Audience.** Anyone with a Mac who's curious about vintage Solaris
  can now experience it. Museum people, educators, retrocomputing
  hobbyists, anyone who's heard "CDE was the GUI on enterprise Unix"
  and wanted to see it. The "I don't have a Sun" objection disappears.
- **Helios.** AI-driven dev on vintage Sun needs a deterministic test
  substrate (snapshot, run experiment, restore). Real hardware can't
  provide that; an emulated SPARCstation with savevm/loadvm can.
  Helios with a real Sun is gated on the Sun being on, the network
  working, the SSH session not flaking, compile times being slow.
  Helios on a snapshotted SS-5 runs hundreds of iterations per session.

This direction was raised in conversation 2026-06-15. Todd's framing:
"one stop, on install, it just works for one thing." The SPARCstation
plugin executes that philosophy with the same discipline we've used
on macXserver itself.

## What landed 2026-06-15

End-to-end proof of concept. Every architectural piece exists and
talks to every other piece. The remaining work is packaging and
polish, not invention.

**Stack proven:**
- QEMU `qemu-system-sparc` booting Solaris 2.6 on emulated SPARCstation 5
  (sun4m). Headless via `-nographic` serial console to the Mac
  terminal. No QEMU framebuffer window, no graphics chrome from QEMU.
- Slirp NAT outbound from guest to host. Guest's X11 traffic routes
  through `DISPLAY=10.0.2.2:0` directly to macXserver's TCP listener.
- Slirp hostfwd inbound from host to guest. Mac side telnets into
  127.0.0.1:2123, lands in the guest's inetd → in.telnetd → login chain.
- macXserver launcher driving a remote command in the guest. The new
  `display =` key in the launcher format (commit `4f7ff3c`) lets the
  entry specify `10.0.2.2:0` for the DISPLAY override instead of the
  Mac's LAN IP.
- `xterm` running in the guest, rendering through macXserver as a
  first-class macOS window with Motif chrome.

That's the entire feature in skeleton form. Everything from here is
making it shippable.

## Working recipe (technical reference)

The configuration that survived an afternoon of bring-up. Everything
below is mechanical, no insight required — just enough specificity that
future-Todd or future-Claude can reproduce the working state without
re-deriving any of it.

### QEMU launch script

Living at `~/Dropbox/dev/QEMU/go` on Todd's Mac:

```sh
qemu-system-sparc -M SS-5 -m 128 -nographic \
    -prom-env 'input-device=ttya' \
    -prom-env 'output-device=ttya' \
    -nic user,model=lance,mac=DE:AD:BE:EF:F3:E5,hostfwd=tcp::2123-:23,hostfwd=tcp::2222-:22 \
    -drive file=SUN40G.qcow2,bus=0,unit=0,media=disk
```

Flag-by-flag:

- `-M SS-5` — SPARCstation 5 (sun4m). QEMU reports `SUNW,SPARCstation-5`
  to OpenBOOT, which Solaris reads via `sysinfo(SI_PLATFORM)`. The guest
  is indistinguishable from a real SS-5 at the model-string level.
- `-m 128` — 128 MB RAM. SS-5 max was 256 MB; 128 is generous for the
  target era. CDE comes up comfortably.
- `-nographic` — disable the framebuffer window. Route the SPARC's
  ttya serial port to the controlling terminal's stdio. This is the
  "headless Sun" path real Solaris admins used in datacenters.
- `-prom-env 'input-device=ttya' / 'output-device=ttya'` — pre-set
  OpenBOOT NVRAM so the firmware uses ttya from boot. Without these,
  OpenBOOT reads the default `input-device=keyboard, output-device=screen`
  and goes looking for the framebuffer we just disabled. With them,
  console policy is serial-only before the first byte prints.
- `-nic user,model=lance,mac=...,hostfwd=tcp::2123-:23,hostfwd=tcp::2222-:22`
  — slirp NAT with an emulated AMD lance NIC. `model=lance` matches
  Solaris's `le0` driver. The MAC is fixed for stable guest identity
  across reboots. The two `hostfwd` clauses open Mac ports 2123 and
  2222, forwarding to guest ports 23 (telnet) and 22 (SSH, for future
  use if OpenSSH ever joins the disk image).
- `-drive file=SUN40G.qcow2,bus=0,unit=0,media=disk` — SCSI disk image
  with Solaris 2.6 pre-installed. The `if=scsi` is implicit on SPARC;
  SS-5's only disk interface is SCSI.

### Guest-side Solaris configuration

The disk image needs three persistent changes to come up networked
correctly for slirp. All under `/etc`:

- `/etc/hostname.le0` contains `10.0.2.15`. This is the address slirp
  expects to find the guest at. Solaris brings `le0` up with this
  static address at boot.
- `/etc/defaultrouter` contains `10.0.2.2`. Slirp's gateway alias.
- `/etc/nodename` contains the hostname (`PiSPARC` in Todd's image,
  whatever you want for a shippable one).

Why the static IP matches slirp's expected guest address: slirp's
`hostfwd` rewrites inbound packets with destination IP `10.0.2.15:N`.
If the guest's `le0` is on any other address, Solaris drops the
packets at the IP layer because the destination isn't ours.

### macXserver launcher entry

The `display` key (added 2026-06-15, commit `4f7ff3c`) overrides
the auto-computed `<mac-lan-ip>:0` for hosts that can't reach the
Mac at its LAN IP. The QEMU/slirp guest is exactly that case.

```
[host:qemu-ss5]
host = 127.0.0.1
port = 2123
user = tvernon
password = kemosabe
display = 10.0.2.2:0
shell_prompt = vernon]
transport = telnet
verbose = true

[qemu-ss5/xterm mint]
command = xterm -bg black -fg "#95efaf" -cr "#ff9966" -geometry 100x40
```

This is structurally identical to every other host block in Todd's
launcher file (u5, ss5, nuc, etc) — same fields, same shape. The
`display = 10.0.2.2:0` is the only line per-host that the QEMU case
needs that the LAN-Sun case doesn't.

## Surprises and gotchas (lessons from the bring-up)

Things that ate time today, recorded so they don't eat time again.

- **Slirp blocks ICMP.** `ping` from inside the guest never works,
  even when TCP is fine. Don't use ping as the connectivity test;
  use `telnet 10.0.2.2 <port>` or `xdpyinfo`.
- **Slirp's hostfwd is destination-IP-specific.** Forwards to
  `:23` mean "to `10.0.2.15:23`," not "to whatever the guest happens
  to have." If Solaris's le0 isn't on 10.0.2.15, inbound forwarding
  silently fails — connection accepted on Mac side, packets dropped
  on guest side, telnetd never spawned.
- **OpenBOOT NVRAM persists between boots.** Once `-prom-env` sets
  the console to ttya, subsequent boots remember it via the saved
  NVRAM in the disk image. But `-prom-env` re-applies each launch,
  which is harmless and makes the script portable.
- **`Ctrl-A` is QEMU's escape char in `-nographic` mode.** Collides
  with bash's "move to beginning of line." `Ctrl-A X` quits QEMU,
  `Ctrl-A C` toggles into the QEMU monitor, `Ctrl-A ?` for help.
- **Solaris 2.6's telnetd does terminal-type negotiation on
  connect.** A bare TCP connection sees the banner but no `login:`
  until the negotiation completes. Modern Mac telnet handles this
  cleanly; older clients sometimes hang on it.
- **Solaris 2.6's default user shell prompt is customized.** Todd's
  `.profile` sets PS1 to `[host:[user]:cwd] `. The launcher's default
  `shell_prompt = $ ` doesn't match. Use `shell_prompt = vernon]`
  (or whatever distinctive substring ends the prompt) or the
  launcher times out waiting for `$`.
- **PATH and LD_LIBRARY_PATH not set under a bare serial login.**
  CDE sets them in its startup; raw serial login doesn't. To run
  X11 clients from a fresh login: `PATH=/usr/openwin/bin:/usr/dt/bin:$PATH`
  and `LD_LIBRARY_PATH=/usr/openwin/lib:/usr/dt/lib` before running
  anything X-related. The launcher's `command` field runs through
  `/bin/sh -c`, which inherits from login env, so this matters if
  the disk image hasn't been configured to set them globally.
- **Solaris 2.6's `route` syntax is BSD-style with required gateway
  on delete.** `route delete default` alone errors. The correct
  form is `route delete default <gateway>`. We rarely need to
  delete the default route though — adding the connected route
  via `ifconfig le0 inet 10.0.2.15 netmask 255.255.255.0 up` is
  enough for slirp connectivity.
- **The launcher's command-wrapper assumes `command` is a single
  command.** It builds
  `/bin/sh -c 'DISPLAY=X; export DISPLAY; nohup <command> </dev/null >/dev/null 2>&1 &'`.
  A compound statement in `command` (e.g. `DISPLAY=Y; export DISPLAY; xterm`)
  breaks the wrapping — nohup sees a bare variable assignment as
  its "command," the semicolons escape the redirection structure,
  and the launched xterm runs without nohup or redirects. The
  `display` key exists specifically to avoid this — keep the
  command field naked, let the wrapper compose DISPLAY at the
  right level.

## Path to product

Phases from "works on Todd's machine" to "feature of macXserver
that ships with the app." Roughly an ordered punch list.

### Phase 1: bundling

- **Build a stripped QEMU.** `--target-list=sparc-softmmu` plus
  disable every other target. Result is a binary maybe 10 MB,
  embedded as a resource in `MacXServer.app/Contents/Resources/`.
  Not a fork — just a configured-down upstream build, rebased
  against current QEMU periodically.
- **Bundle the OpenBOOT ROM.** OldSilicon's distribution side
  solves the legal question. Embed as a resource alongside the
  binary.
- **Bundle a Solaris 2.6 disk image.** Pre-installed, pre-configured
  for slirp (the three `/etc/` edits above already in place).
  Shipped as a qcow2 in resources, copied to writable Application
  Support on first launch so user state persists.
- **Bundle a "logged into CDE" snapshot.** `savevm` mid-boot, after
  CDE has come up and the user has logged in. Restoring this
  snapshot on launch skips the 60-90 second cold boot — user sees
  a working desktop in 2 seconds flat.

### Phase 2: control plane

- **QMP integration in macXserver.** QEMU's JSON-over-socket
  control protocol. macXserver spawns the QEMU subprocess with
  `-qmp unix:<socket>,server,nowait` and drives boot/snapshot/reset
  via the socket. No subprocess management hacks, no parsing of
  QEMU stderr — just structured messages.
- **UI surface.** A "Sun" menu (or whatever it lives under): Boot,
  Reset, Suspend, Snapshot, "Drop to OpenBOOT." NOT a VM list,
  NOT a configuration panel. One machine, one set of controls.
- **First-launch flow.** Detects "no user state yet," copies
  the bundled snapshot to writable storage, launches QEMU with
  `-loadvm cde-ready`. User sees the Solaris desktop without
  ever knowing there's a VM involved.
- **Auto-DISPLAY in the launcher.** When the launcher knows it's
  targeting the bundled emulator (host = 127.0.0.1 + a magic port,
  or a `kind = qemu-local` key), auto-set `display = 10.0.2.2:0`.
  User shouldn't have to know about slirp's addressing.

### Phase 3: polish

- **Persistent state.** User's CDE config, their files, anything
  they edit, goes to Application Support and survives launches.
  Bundle stays read-only.
- **Snapshot management.** "Reset to fresh CDE" is a menu item
  that restores the shipped snapshot. User can save additional
  named snapshots if they want.
- **Network egress (optional).** Solaris can reach the internet
  via slirp's NAT. Useful for `ftp`, `gcc` builds, etc. Default
  on, no configuration needed.
- **No audio, no floppy, no tape.** Resist the urge to add
  these — they're "everything to everyone" expansion. SS-5
  audio was niche, and the bundle is for showing what vintage
  Solaris looked like, not for being a complete SPARC simulator.

### Phase 4: brand and ship

- **macxserver.com positioning.** "A working SPARCstation 5 in a
  Mac app." Video on the home page of CDE running, with a download
  button. The X server is the technical heart but stops being the
  user-facing surface; the Solaris experience becomes the product.
- **Existing audience preserved.** Power users who already use
  macXserver against real Sun hardware over SSH/telnet keep
  working as today. The new bundled mode is additive, not a
  replacement.
- **Marketing line.** "The vintage Sun environment that runs on
  your laptop. No setup, no install, no Sun hardware required."

## Open questions

Things we've thought about but not decided. Each blocks a phase but
not the next milestone.

- **Single machine target or two?** SS-5 is the obvious choice
  (iconic, well-supported in QEMU, runs the apps we care about).
  Adding SS-20 or sun4c IPX/IPC would be cheap (same emulator,
  different `-M` flag, different disk images) but doubles the
  bundle size and complicates the UX. Lean: one machine, ship,
  see if anyone asks.
- **Solaris 2.6 vs Solaris 2.7 vs SunOS 4.1.4?** 2.6 is the peak-
  CDE Motif environment of the late-90s enterprise Unix experience.
  2.7 is similar with minor cleanups. 4.1.4 is pre-CDE, smaller,
  faster on the emulator, more Unix-purist. My (Claude's) lean is
  2.6 for the broad cultural memory of "Solaris workstation."
  Todd's call.
- **NetBSD/SPARC as a no-OS-licensing demo image?** Free to
  redistribute, doesn't run vintage Solaris apps, but is exactly
  what you'd want if you ever needed to ship a demo that's legally
  unencumbered. Plausible as a second-tier "free demo" alongside
  the curated Solaris image. Defer until OldSilicon's distribution
  posture changes.
- **Sun-3 (m68k) support?** Not in scope. Different emulator
  configuration, different OS image, different audience overlap.
  If TME ever gets compelling enough, possibly a second product;
  not a feature of the same bundle.
- **TME as a second engine?** Probably not. QEMU's pragmatism wins
  for this audience. TME's accuracy matters when you care about
  authentic SunOS 4 hardware modeling; we're shipping a CDE-era
  experience where QEMU is fine. Keep TME in mind for an "expert
  mode" that doesn't exist yet.
- **Plugin architecture or baked-in?** Todd's framing is "plugin
  sparcserver." Plausible packaging: separate .app bundled with
  macXserver, or a downloadable extension that drops into a known
  path. Pros of plugin: keeps macXserver core lean, lets each
  ship independently. Cons of plugin: more surface for users to
  understand, more places things can be misconfigured. The
  cleaner UX may be "one app, all included" with a feature flag
  to disable the bundled SS-5 for users who don't want it.
  Decide when bundling lands.
- **Performance bar.** Solaris 2.6 boot to login on QEMU TCG on
  M3 silicon is roughly 60-90 seconds. CDE launch from login is
  another 20-30 seconds. With snapshot-based fast-launch the
  user-visible startup is 2-3 seconds. Confirm with measurements
  before committing to "2 seconds" as a public claim.
- **Multi-instance.** Two SPARCstations side by side? Possibly
  interesting for showing client/server work or testing remote
  X paths. Defer.
- **Inputs.** Mouse and keyboard route through the guest's xterm
  / CDE naturally via the X protocol. But what about Sun keysym
  oddities (the L1-L10 left-side keys, the Compose key)? Today
  we lean on the keysym mapping that ships in macXserver core
  (USKeymap.swift). Should hold up under the SS-5 plugin; worth
  spot-checking once a bundled image exists.

## Helios alignment

The plugin and Helios are complementary. Helios with the plugin
becomes dramatically more capable than Helios with only real Sun
hardware:

- **Snapshot before each AI experiment.** `loadvm cde-ready`
  resets the guest to a known state in 2 seconds. Failed
  experiments don't corrupt the substrate.
- **Hundreds of iterations per session.** Real hardware = one
  experiment per minute on a fast day. Emulator = many per minute.
- **Determinism.** Same snapshot, same input, same output. AI
  training/evaluation loops actually work.
- **Reproducibility for users.** Helios experiments become
  shareable artifacts ("apply this snapshot, run this command,
  observe this behavior") instead of "ssh to my u5 and try this."

When the plugin ships, Helios should sit on top of it from day one.
The plugin gives Helios the test substrate it needs to graduate
from "interesting demo idea" to "actual development workflow."

## Why this is the right next direction

Three structural reasons:

1. **It uses macXserver's privileged position.** The X server is
   already the display surface. Adding the engine and the disk
   image puts the entire vintage Sun experience in one app. No
   one else is positioned to ship this combination.
2. **The legal hard part is solved.** OldSilicon's distribution
   side handles the ROM and OS image redistribution. The technical
   stack (QEMU + Solaris 2.6) is freely re-buildable from upstream.
   No licensing maze to navigate.
3. **It widens the audience without compromising the niche.**
   The product is still "the vintage Sun X environment on a Mac."
   The bundled emulator just removes the "do you own a Sun?"
   prerequisite, multiplying the reachable users without changing
   what the product is. Same audience values, same target
   environment, much bigger reachable pool.

Resist the temptation to expand scope beyond "one machine, pre-
installed, just works." The discipline that made macXserver good
is the discipline this needs too.
