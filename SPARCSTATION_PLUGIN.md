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

## Distribution and bundling mechanics

How the user gets from "downloaded macXserver" to "booted CDE desktop"
without homebrew, Terminal, or any setup step. This section captures
direction from a 2026-06-16 conversation; nothing here is code yet.

### Plugin-as-downloadable-bundle (UX shape)

Keep macXserver's base download small. The SPARCstation parts are an
optional payload the app pulls down on demand from the OldSilicon CDN
(which already distributes the disk image). The plugin framing from
Todd's original sketch maps cleanly onto this distribution shape: the
plugin literally is a separately-downloaded, separately-versioned
bundle that drops into Application Support.

Plugin bundle on disk:

```
~/Library/Application Support/macXserver/Plugins/
  SPARCstation.macxplugin/
    Info.plist           name, version, sha256 of each payload, min macXserver version
    qemu-system-sparc    notarized, hardened-runtime, JIT entitled (see signing below)
    openbios-sparc32     ROM
    lib/                 bundled dylibs (see bundling mechanics below)
    SS5-cde-ready.qcow2  Solaris 2.6 image with a savevm snapshot named "cde-ready"
```

Self-contained: no PATH leakage, no system mutations, removable with
one `rm -rf`. Disk image gets copied out to a writable path on first
boot so the plugin bundle itself stays read-only / re-installable
without nuking user state.

Distribution: a single `.tar.gz` of the plugin plus a tiny
`manifest.json` (version, URL, sha256, size) hosted alongside it.
macXserver fetches the manifest only when the user clicks Install. No
background polling, no telemetry on first launch.

Install flow inside macXserver:

- `macXserver → Install SPARCstation Plugin…` opens a sheet: "Adds a
  working SPARCstation 5 with Solaris 2.6 and CDE. ~350 MB download.
  From oldsilicon.com."
- Click Install: NSURLSession streams the tarball with a progress
  bar, SHA256 verified against the manifest before unpacking, atomic
  move into Application Support.
- After install, a `Window → Boot SPARCstation 5` menu item appears
  and a launcher entry auto-materializes (`[host:sparcstation-local]`
  with `display = 10.0.2.2:0`, `host = 127.0.0.1`, dynamically
  chosen port).

Boot UX: click Boot, macXserver spawns the bundled QEMU with
`-loadvm cde-ready -qmp unix:...`. With a saved-state snapshot the
user is at CDE in ~2 seconds. No "VM is starting" modal, no boot
console.

Updates and removal: `macXserver → Manage Plugins…` lists installed
plugins with version, "Check for Update", and "Uninstall" buttons.
Same download mechanism for updates; not Sparkle, just the same ~200
lines of NSURLSession + sha256 verification.

Alternatives considered:

- **Two .app downloads** (`macXserver.app` vs
  `macXserver-SPARCstation.app`). Simpler — no plugin loader to
  write, two separately notarized builds. Cost: discoverability
  ("did I download the right one?") and the release pipeline
  doubles. Lean: no.
- **Everything embedded in one fat .app.** Eliminates the install
  flow entirely but every SSH-to-real-Sun user pays ~400 MB on the
  base download. Breaks the "macXserver is small" character of the
  product. Lean: no.
- **Sparkle for the plugin.** Overkill — Sparkle is for app updates,
  not optional content. Roll-your-own keeps the dependency surface
  tight. Lean: no.

### QEMU bundling mechanics (the homebrew-style dep tree problem)

Homebrew's QEMU is a fat developer install: every target, every UI
backend, every codec, every optional feature, ~30 dylibs of deps.
None of that is what we want to ship. The right move is to NOT ship
the homebrew binary at all; build our own trimmed QEMU and bundle the
few surviving dylibs into the plugin.

**Step 1: collapse the dep list at configure time.** For headless
SPARC-only QEMU driving slirp networking, almost every homebrew dep
is dead weight:

```
./configure --target-list=sparc-softmmu \
  --enable-tcg --enable-slirp=internal \
  --disable-sdl --disable-gtk --disable-cocoa --disable-curses --disable-vnc \
  --disable-opengl --disable-virglrenderer --disable-spice \
  --disable-gnutls --disable-nettle --disable-gcrypt \
  --disable-libssh --disable-curl --disable-libnfs --disable-libusb \
  --disable-bzip2 --disable-lzo --disable-snappy --disable-libxml2 \
  --disable-rdma --disable-vde --disable-vhost-net --disable-docs \
  --disable-tools --disable-guest-agent --disable-capstone
```

`--enable-slirp=internal` bakes the slirp library in so it's not an
external dep. After this, `otool -L qemu-system-sparc` typically
shows:

- `libglib-2.0` + `libgobject-2.0` + `libgio-2.0` + `libgmodule-2.0`
  (glib bundle)
- `libpixman-1`
- `libintl`, `libpcre2`, `libffi` (glib's deps)
- `libz`, `libiconv`, `libSystem`, `libc++` (system; don't bundle)

That's ~5 non-system dylibs. Stripped binary ~8 MB, bundled deps add
~5 MB, total ~15 MB in the binary layer. Disk image dominates the
download.

**Step 2: bundle the surviving dylibs with `@executable_path`
rewriting.** Standard macOS pattern: copy the dylibs into the plugin
and rewrite the binary's install names to load them from
`@executable_path/lib/`. Use the actively-maintained
`auriamg/macdylibbundler` (brew-installable, build-time tool only,
never shipped):

```sh
dylibbundler -od -b -x ./SPARCstation.macxplugin/qemu-system-sparc \
             -d  ./SPARCstation.macxplugin/lib/ \
             -p  '@executable_path/lib/'
```

It walks the dep graph transitively, copies every non-system dylib
into `lib/`, rewrites every `LC_LOAD_DYLIB` to
`@executable_path/lib/libfoo.dylib`. Sanity check after: `otool -L`
on the binary; every entry should point at `@executable_path/lib/`
or a system path under `/usr/lib/` or `/System/`. Anything pointing
at `/opt/homebrew/…` or `/usr/local/…` is a leak that breaks on the
customer's machine — the most common "ship a Mac app with bundled
CLI tools" bug.

**Step 3: build from source, not from homebrew.** Homebrew's QEMU
package and its deps roll forward weekly. For a shippable binary we
want determinism: a `build-qemu-plugin.sh` that fetches pinned
tarballs for QEMU + glib + pixman + libffi + libpcre2, builds each
into a private prefix, links QEMU against the private prefix, runs
dylibbundler against the result. Reproducible across machines and
releases. The script doubles as build documentation. Setup is
roughly a one-afternoon job; reruns are ~5 minutes.

**Step 4: codesign in the right order.** Codesign is recursive but
fiddly. The drill:

1. Sign each `.dylib` in `lib/` with Developer ID Application,
   hardened runtime, no entitlements.
2. Sign `qemu-system-sparc` with hardened runtime + JIT entitlements
   (`com.apple.security.cs.allow-jit`,
   `com.apple.security.cs.allow-unsigned-executable-memory`). TCG on
   Apple Silicon needs JIT or it falls back to interpreter and
   bootup goes from 90 seconds to 10+ minutes. This is the bug that
   eats release week if discovered late.
3. Bundle plugin into `.tar.gz`, hash it, ship.
4. Notarize the macXserver .app as normal; plugin contents are
   evaluated by Gatekeeper at expand time if signed by the same Team
   ID. Plugin tarball can also be notarized separately as a `.dmg`;
   mostly aesthetic.

Skipping step 1 (one unsigned `libglib-2.0.dylib`) means Gatekeeper
kills the binary at load time on the customer machine and the user
sees "Cannot open SPARCstation plugin." Easy to miss in dev because
the homebrew copy is on the dyld search path.

**Final sanity test before any release:** clean Mac (or fresh user
account), drag the .app, install the plugin, click Boot. The
homebrew `qemu-system-sparc` and dylibs must not exist anywhere on
the test machine. If anything links to `/opt/homebrew` or
`/usr/local` it'll fail here, not in dev.

## File plane architecture (Helios enablement)

The bundled-QEMU posture creates an opportunity Helios couldn't fully
exploit on bare-metal Suns: the Mac IS the NAS, and the AI dev loop
benefits from broad filesystem visibility into the guest. This section
captures the design direction; implementation lands alongside Helios
MVP. Background: `Helios-Mission.md`.

### Mac as NAS over slirp

`Helios-Mission.md` specifies NFS as the file plane (source of truth
on a shared mount, both sides see the same bytes). On bare-metal Suns
the NAS is a separate device. With the bundled emulator, the NAS
becomes the Mac itself running its built-in `nfsd`, served back to
the guest via slirp's gateway alias `10.0.2.2`. Same architecture,
no extra hardware.

Mechanics:

- macOS exports a workspace via `/etc/exports` to the slirp guest's
  fixed IP (10.0.2.15).
- Pin `nfsd` and `mountd` to fixed ports so slirp NAT works
  deterministically. NFS's portmapper-allocated dynamic ports are
  otherwise painful through user-mode NAT.
- Solaris 2.6 mounts via
  `mount -F nfs 10.0.2.2:/export/dev /mnt/dev`, with `nolock` to
  dodge macOS `nfsd`'s flaky locking layer.
- uid squashing: macOS exports with `-mapall=<tvernon-uid>` so all
  edits from the Mac side land as the guest's user regardless of
  which Mac account wrote them. This is exactly the
  `all_squash, anonuid=<nas-uid>` pattern Helios specifies, just
  with macOS as the server.

### Three boot architectures

How much of the guest's filesystem lives on NFS versus the qcow2 is
a spectrum, not a binary.

**Option A: boot from qcow2, NFS-mount only the workspace.** One
extra mount line in `/etc/vfstab`. AI sees the workspace; nothing
else. Slirp is sufficient. This is the Helios MVP path and what the
plugin v1 should ship.

**Option B: boot from minimal qcow2, NFS-mount most of `/`.** Boot
disk holds kernel, `/etc`, init scripts, NFS client tools. NFS-mount
`/usr`, `/opt`, `/export/home`, optionally `/var/sadm`. AI has near-
complete filesystem visibility. Slirp still works. This is the Sun
"dataless workstation" pattern from the 1990s, when full-diskless
was overkill but local disk was tight. Compelling middle ground for
Helios.

**Option C: full diskless. No qcow2.** Mac runs `bootparamd` +
`tftpd` + `nfsd`, exports a complete Solaris root. QEMU boots via
`-netdev vmnet-shared` (Apple's vmnet.framework, supported since
QEMU 7.x; prompts the user for permission once, no kext). OpenBOOT
issues `boot net`. The whole filesystem lives on the Mac. AI has
total visibility, including ability to edit `/etc/init.d` scripts
and watch them take effect on next boot. Most authentic Sun-
datacenter setup, biggest infrastructure lift, and requires layer-2
networking rather than slirp.

The shipping product picks A. Helios mode picks B (with the
workarounds below) or C. They share most of the NFS infrastructure;
the diff is the boot path and the network mode.

### Option B blind spots and workarounds

What stays opaque on the qcow2 in Option B clusters into "system-
level state" rather than "dev-level state." For Helios's MVP loop
(write source, build, run, observe) nothing important is lost. Where
it hurts is anything sysadmin-flavored.

Opaque from the Mac in Option B:

- **`/etc/*` system config.** `passwd`/`shadow`/`group`,
  `inetd.conf`, `rcS.d`/`rc2.d`/`rc3.d` init scripts, `vfstab`,
  `system`, `cron.d`, `nsswitch.conf`, `resolv.conf`,
  `profile`/`.login`, `dt/*` CDE defaults.
- **`/var/adm/messages` and `/var/log/*`.** Syslog and system logs.
  AI can't watch kernel messages, login failures, daemon errors from
  the Mac side without terminal puppetry, exactly when diagnosis
  benefits most from instant file access.
- **`/var/sadm/install/contents`.** Solaris package database. Can't
  see installed packages without running `pkginfo` over the
  terminal.
- **`/sbin`, `/kernel`, `/dev`, `/devices`, `/proc`.** Kernel-
  special or boot-time. AI doesn't need to edit these.

Cheap workarounds that close the worst gaps without going to
Option C:

1. **Symlink logs into NFS-visible space at image-prep time.**
   `mv /var/adm/messages /export/dev/sys/messages` then
   `ln -s /export/dev/sys/messages /var/adm/messages`. Syslogd
   writes through the symlink; the file lives on NFS; AI reads it
   instantly from the Mac. Same trick for the inetd log and any
   other chatty daemon log.
2. **Symlink selected `/etc` config to NFS.** Snapshot
   `/etc/inetd.conf`, `/etc/services`, `/etc/hosts` into
   `/export/dev/sysconf/` and symlink them back. Safe for service-
   config files. Do NOT do this for `passwd`/`shadow` (PAM cares
   about the actual inode).
3. **Pre-stage a system-snapshot script.** A Sun-side script dumping
   interesting state to NFS:
   `pkginfo > /export/dev/sys/installed`,
   `netstat -rn > .../routes`, etc. Run on boot and on demand. AI
   reads snapshot files instantly without terminal use.
4. **NFS-mount `/var/sadm` directly.** Post-boot stable, doesn't
   need to be local. AI gets read access to the package database.

With those four additions, Option B reaches roughly 90% of Option C's
visibility without the vmnet/bootparamd/tftpd lift. The shipping
posture for Helios mode is probably "Option B+" rather than B or C.

### NFS-mounted tools directory

The same NFS plane that enables file sharing also enables tool
extension. Sun's `/opt` convention was designed for exactly this:
self-contained package tree, no `pkgadd` ceremony, no reboot, no
package database. The plugin ports the convention onto the Mac side.

Structure:

```
/export/dev/tools/
  bin/      cross-compiled SPARC binaries: gcc, gmake, gdb, bash, less, gawk, gsed
  lib/      shared libs (or build static, sidesteps dependency hell)
  share/    man pages, headers, gcc support files
  etc/      tool config
  agent/    AI-curated scripts: ai-syscheck, ai-pkglist, ai-tail-messages
```

Mac side owns the entire tree. Drop a binary, the guest sees it on
next invocation. Remove a broken tool, same deal. AI iterates on its
own tooling without rebuilding the disk image.

PATH baked into `/etc/profile` at image-prep time:

```sh
PATH=/export/dev/tools/bin:$PATH
MANPATH=/export/dev/tools/share/man:$MANPATH
LD_LIBRARY_PATH=/export/dev/tools/lib:$LD_LIBRARY_PATH
export PATH MANPATH LD_LIBRARY_PATH
```

One terminal edit at image-prep, then permanent for every login.

System prompt to AI: "Sun-side tools are in `/export/dev/tools/bin`.
Prefer those over `/usr/ucb` and `/usr/bin` equivalents when both
exist; the curated set is GNU-ish, the shipped set is Sun-1996-ish."
That single sentence dissolves most of the Sun-shell-quirks guidance
in `Helios-Mission.md`. AI defaults to bash, gmake, gawk, GNU sed and
only falls back to the Sun originals when something specifically needs
them.

Seed tools worth shipping in the bundle:

- **gcc-3.x or gcc-4.x for `sparc-sun-solaris2.6`.** Sunfreeware /
  Blastwave-era binaries exist. The shipped Sun `cc` on a 2.6 install
  is the unbundled K&R cc (SunPro C was a paid add-on most installs
  lacked). Modern GCC is transformative: ANSI C, real warnings AI can
  act on, decent error messages, C++.
- **GNU make.** Solaris `make` lacks `$<` in non-suffix rules plus
  other GNU-isms AI expects.
- **bash.** AI's training is overwhelmingly bash-shaped; bash on the
  Sun removes a whole category of "use backticks not `$()`"
  corrections.
- **gdb.** AI's debugger fluency is gdb-shaped, not dbx-shaped.
- **AI-side toolkit.** `ai-syscheck`, `ai-pkglist`, `ai-tail-messages`:
  small scripts wrapping Sun tools and dumping output to NFS-readable
  files. Closes the Option B sysadmin gaps without terminal puppetry.

Real gotchas:

1. **NFS mounts often default to `nosuid`.** Setuid binaries on the
   share won't escalate. Not a problem for compilers/editors, but
   blocks `sudo`-like behavior from dropped-in tools. Consider
   whether the tools mount should drop `nosuid` (and accept the
   security posture).
2. **Static linking strongly preferred for seeded tools.** Sun's
   `libc.so.1` on 2.6 has specific symbol versions; cross-compiled
   binaries against a different libc fail at runtime in weird ways.
   `-static` or `-Bstatic` sidesteps the dependency hell. Bigger
   binaries, but it's NFS not floppy.
3. **`LD_LIBRARY_PATH` is the escape valve when static doesn't work.**
   Pre-set in `/etc/profile`, point at `/export/dev/tools/lib`.
   Dynamically-linked dropped-in tools find their bundled libs
   without polluting `/usr/lib`.

Shipping story: the plugin includes a pre-built `/export/dev/tools/`
tree as a resource in the .app bundle, copied to writable storage on
first launch alongside the qcow2. Out-of-the-box the user (or AI) has
a modern toolchain on the bundled SS-5 without compiling anything.
Much more delightful than "you've got a vintage Solaris box, now go
figure out how to install gcc on it."

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
