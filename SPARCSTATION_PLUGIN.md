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

## What landed 2026-06-16: SPARCplug repo, proven minimal build, distribution shape

Two things firmed up on 2026-06-16: the engine got its own home and a
real build, and the distribution architecture got decided. The sections
further down (Path to product, Distribution and bundling mechanics) were
written before these calls; where they disagree, this section wins.

**The engine is now its own project: SPARCplug.** Standalone private
repo `github.com:toddvernon/SPARCplug` (local working tree `~/dev/SPARCplug`),
deliberately separate from the macXserver repo. It builds and ships
independently. Cross-machine rule: editable source rides git, big
never-edited blobs (the qcow2, ROM, snapshot, final binary) ride Dropbox
at `~/Dropbox/dev/SPARCplug`, the same split macXserver uses for
`reference/`. QEMU is vendored, not forked: `qemu/` is a clean import of
qemu-9.2.4 (roms/ pruned, since a sparc-only build uses the pre-built
`pc-bios/openbios-sparc32` blob), provenance in `qemu.lock`. "In the
repo" is the sync mechanism, not a fork commitment.

**The minimal build is real and proven.** `build-qemu.sh` produces an
8.6 MB headless `qemu-system-sparc` (one target, sparc-softmmu, TCG +
slirp only, every UI/codec/crypto/audio feature off) that boots
Solaris 2.6 to a `login:` prompt on emulated SS-5. Non-system dylib
deps are down to just `libslirp` (our own bundled subproject) and the
glib quartet (gio/gobject/glib/gmodule), plus glib's transitive
libintl/pcre2/libffi. So the only real external dependency is glib.
Two trims worth recording: `--disable-png` (PNG screendump, dead on a
headless build) and `--disable-pixman`. Pixman turned out NOT to be
mandatory: QEMU carries an internal fallback for the TCX framebuffer
surface, and that surface is a cold path here anyway since the guest's
X clients render over the X protocol to macXserver, not through the
guest framebuffer. Verified to still boot.

macOS build gotcha (load-bearing, see SPARCplug README): homebrew's
`python@3.14` ships a broken pyexpat that breaks QEMU's build-venv
creation and glib's gdbus-codegen. `build-qemu.sh` sidesteps it with an
isolated system-python (3.9) venv and `--disable-dbus-display`.

**Distribution decision: code ships in the app, data downloads on
demand.** This supersedes the "Plugin-as-downloadable-bundle" layout
below, which put the qemu binary in the downloadable payload. The
seam is code-vs-data, not engine-vs-image:

- The **engine** (qemu helper binary + glib dylibs) ships *inside*
  `MacXServer.app` and is signed and notarized as part of the normal
  app release. All the hard parts (Developer ID signing, notarization,
  JIT entitlements, hardened-runtime load checks, the no-sandbox
  constraint) fold into the app pipeline we already run.
- The **disk image** is the only thing downloaded on demand. It's pure
  data: no signing, no notarization, and (fetched via NSURLSession) no
  quarantine xattr, so no Gatekeeper prompt on it. "Install SPARCplug"
  fetches it, verifies a sha256, decompresses into Application Support;
  the menu then flips to "Run SPARCplug" and the launcher entry ungrays.

Why this and not the engine-in-the-download: it collapses the only
genuinely hard packaging problem (trusting a downloaded executable) into
work we already do, and leaves the on-demand path as plain data. The
one cost (can't ship an engine update without an app release) is near-
zero because QEMU's sun4m emulation is frozen; we'll essentially never
patch it.

**It's one app bundle, not one fused binary, and not a separate
installer.**
- macXserver and SPARCplug stay as two Mach-Os in one bundle: the app
  in `Contents/MacOS/`, the engine as a nested helper (e.g.
  `Contents/Helpers/qemu-system-sparc`) spawned as a subprocess. Fusing
  them into a single executable is the wrong call: QEMU isn't a library
  (it owns its own main loop, threads, signals, and process exit),
  in-process TCG would spread the JIT entitlement to the whole app and
  kill its hardened-runtime posture, a qemu crash would take the app
  down, and they communicate over sockets anyway (X protocol through
  slirp). The user still sees one icon, one download, one notarization.
- No `.pkg` installer. Drag-to-Applications survives intact because the
  engine rides inside the app and the image lands in user-writable
  `~/Library/Application Support/macXserver/` with no privileged files,
  no system mutations, no admin rights. A `.pkg` would add a separate
  Developer ID Installer cert and its own notarization for zero benefit.
  One rule to keep this true: the app must write/read the image by
  absolute Application Support path, never relative to its own bundle,
  so macOS app-translocation can't hide it.

**Disk-image numbers (for the download UX).** The image is 42.9 GB
*virtual* (what Solaris sees) but only ~1.3 GB actual on disk (qcow2 is
sparse) and ~250 MB gzipped. So the "40 GB image" is a 250 MB download.
The virtual size is just a growth ceiling as the guest writes data.

**How the bundled glib gets loaded (not homebrew's).** dyld doesn't
search for libraries; it loads the exact path baked into each
`LC_LOAD_DYLIB`. As built, those point at `/opt/homebrew/...`, which is
why packaging is mandatory: `dylibbundler` copies the dylibs into the
bundle, rewrites every load path to `@rpath/lib...`, adds one rpath
pointing at the bundle's Frameworks dir, and fixes the transitive
inter-dylib refs. After that dyld can only resolve our bundled copies,
and hardened runtime makes it ignore any `DYLD_*` override. The audit
is `otool -L` showing zero `/opt/homebrew` or `/usr/local` paths,
verified on a clean account with no homebrew.

## Next milestone: shippable plugin v1

> **RESEQUENCED 2026-06-20.** The original framing ("do this BEFORE Helios,
> Helios not started until v1 ships") is **superseded**. The control holes we
> hit building v1 (orphan/lock/shutdown, 06-19/20) showed that the right
> shippable control channel *is* the Helios guest agent -- so Helios's first
> use case (the **control plane**: graceful shutdown, liveness, orphan
> recovery, image-repair GUI) now comes *before* the release, not after. The
> SPARCplug release is parked behind the control plane. The agentic-coding
> use case (Claude Code + a SPARCplug MCP server) is still later. See
> `Helios-Mission.md` (rewritten 06-20) and DECISIONS 2026-06-20. The three
> deliverables below remain valid v1 packaging work; they just no longer gate
> all Helios work, and the daemon's control verbs now interleave with them.

This is the agreed next batch of work, decided 2026-06-16 (resequenced
2026-06-20 per the banner above).

Plugin v1 is the first end-to-end shippable form: a user downloads one
app, installs the disk image from a menu, and boots a working
SPARCstation with the console visible.

**Deliverable 1: a shippable app binary with the engine built in, no
disk image.** Bundle SPARCplug's `qemu-system-sparc` + glib dylibs into
`MacXServer.app` (`Contents/Helpers/` + `Contents/Frameworks/`), run the
`dylibbundler` relink (zero `/opt/homebrew` paths), codesign with the
JIT entitlements, and notarize as part of the normal app release. Result
is one uploadable `.app` that carries the engine but NOT the ~250 MB
qcow2. This is the code-vs-data seam from the decisions above made real.

**Deliverable 2: the menu installs the disk image on demand.** Before
install the SPARCplug menu offers only "Install SPARCplug" (or similar).
Selecting it downloads the gzipped Solaris image (~250 MB), verifies its
sha256, and decompresses it to `~/Library/Application Support/macXserver/`
(absolute path, never relative to the bundle). Once present, the menu
flips to "Run SPARCplug" and the SPARCplug launcher entry un-grays. State
keys off "is the qcow2 in Application Support."

**Deliverable 3: launch with an observation window + enable the
launcher.** "Run SPARCplug" spawns the bundled engine as a subprocess
(`-nographic` serial console) and routes that console stream into an
observation window in macXserver so the user can watch the boot and the
serial console. When it's up, the SPARCplug launcher entry is enabled so
the user can launch X clients (xterm, CDE) into the guest, which render
through macXserver as normal. The observation window is also the
foundation Helios later builds its split-window terminal on, but for v1
it's just a read-only console view.

Acceptance: on a clean Mac with no homebrew, drag the app in, "Install
SPARCplug" (downloads image), "Run SPARCplug" (boots, console visible in
the observation window, launcher enabled), launch xterm into the guest.

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

The full set of edits needed to turn a generic Solaris 2.6 install
into a slirp-shaped baseline lives in
`Tools/sparcstation-baseline-config.sh`. The script is canonical;
this section just sketches what it does so the recipe is readable
without opening the file.

What ends up on the guest:

- `/etc/hostname.le0` contains `10.0.2.15`. Slirp's `hostfwd` rewrites
  inbound packets with destination IP `10.0.2.15:N`; if le0 is on any
  other address Solaris drops them at the IP layer.
- `/etc/hosts` maps `10.0.2.15` to the guest's hostname (also includes
  `loghost` alias so syslogd is happy).
- `/etc/inet/netmasks` has an entry for `10.0.0.0 255.255.255.0` so
  le0 comes up at first plumb with the correct `/24` mask instead of
  class-A default.
- `/etc/defaultrouter` contains `10.0.2.2`. Slirp's gateway alias.
- `/etc/init.d/defaultroute` + `/etc/rc3.d/S99defaultroute` re-adds
  the default route late in boot. `inetinit`'s `/etc/defaultrouter`
  handling races against interface bring-up in some QEMU/Solaris
  combos and silently fails with "Network is unreachable"; the S99
  script catches that case. Harmless if `inetinit` already succeeded
  (kernel rejects the duplicate).
- `/etc/resolv.conf` points at public DNS (`8.8.8.8` + `1.1.1.1`) so
  the image works on any network. The plugin install UX may want to
  let the user override this — see the Distribution section.
- `/etc/nsswitch.conf` `hosts:` line includes `dns` so libc's
  `gethostbyname` consults the resolver (Solaris 2.6 defaults to
  `files nis` only).
- `/etc/profile` runs `stty erase ^H` so the Mac Delete key erases
  instead of echoing `^H` (xterm sends `^H` for the BackSpace keysym
  by default).

The script backs up every file it touches to
`/var/tmp/macxserver-baseline-backup/` before overwriting, prints a
running progress log, and is safe to re-run. Run it as root inside
the guest, then `init 6` to verify the boot trajectory comes up clean
(no "Network is unreachable" message, default route present in
`netstat -rn`, `telnet google.com 80` connects). Then snapshot.

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

### Image-prep: bootstrapping the dev toolchain (sun26gnu.iso)

The `go` script above is the day-to-day boot. For *image-prep* -- modifying
the qcow2 to add tools -- there's a sibling
`~/Dropbox/dev/SPARCplug/fullemu.sh` that runs the **homebrew**
`qemu-system-sparc` (11.x) instead of the bundled engine, with two extra
hooks: slirp's built-in TFTP server (`tftp=<dir>` on the `-nic`) and an
optional `-cdrom` (`CDROM=... ./fullemu.sh`). We use the homebrew engine
for prep because the bundled one is built `--disable-vmnet` and finds its
firmware only via the app's `-L`; the homebrew build is fuller and
self-locates firmware, so it's the friendlier hand-run engine. Prep writes
the image in place; a dated `SUN40G autobackup ...qcow2` sibling is the undo.

**Getting files INTO the guest is the hard part, because slirp.** What we
learned the slow way (2026-06-18):

- **FTP is a dead end.** Solaris 2.6's stock `ftp` client is active-only,
  and active mode can't traverse slirp NAT -- the server has to open a data
  connection back to the guest at `10.0.2.15`, unreachable from outside
  slirp. Same wall both directions. A passive-capable client (wget/ncftp)
  fixes guest-initiated pulls; nothing fixes Mac-pushes-in over FTP.
- **slirp's built-in TFTP** (`tftp=<dir>`; guest does `tftp 10.0.2.2`,
  `binary`, `get`) needs no host daemon and crosses no NAT, but it's
  512-byte lockstep with an ancient client and **times out past a few MB**
  (2.5 MB fine, 20 MB not). Good for one small bootstrap binary, useless
  for a toolchain.
- **Mounting an ISO via `-cdrom` is the answer** for anything big: no size
  limit, no protocol, no dependency chase.

**The dependency-hell shortcut: `sun26gnu.iso`.** A precompiled GNU set
built *for Solaris-2.6-under-QEMU* (`archive.org/details/sun26gnu`, 274 MB)
with an `installgnu.sh` that `pkgadd`s the whole **matched dependency
closure** at once. That closure is the point: hand-chasing sunfreeware deps
(wget -> openssl -> libiconv -> libintl -> libidn -> libgcc, each pulling
more) is a multi-hour trap. vold auto-mounts the disc at `/cdrom/sun26gnu`.
Install non-interactively:

```sh
# printf the admin file -- heredocs corrupt over the serial console
printf 'mail=\ninstance=overwrite\npartial=nocheck\nrunlevel=nocheck\nidepend=nocheck\nrdepend=nocheck\nspace=nocheck\nsetuid=nocheck\nconflict=nocheck\naction=nocheck\nbasedir=default\n' > /tmp/noask
cd /cdrom/sun26gnu/gnu/pkgs
for p in * ; do pkgadd -n -a /tmp/noask -d "$p" all ; done
```

(ISO filenames mangle -- dashes become underscores, versions truncate --
because the disc has no Rock Ridge and 2.6 `hsfs` falls back to bare
ISO-9660. File *content* is intact, so glob `*`, not a dash pattern.)

**Toolchain manifest (on SUN40G.qcow2 as of 2026-06-18):**

| Tool | Version | Source |
|---|---|---|
| gcc | 2.95.3 | already native on the image (emits stabs) |
| GNU make | 3.82 | already native |
| gdb | 4.17 | ibiblio mirror, `GNUgdb.4.17.SPARC.Solaris.2.6.pkg.tgz` |
| wget | 1.12 (+https) | sun26gnu.iso |
| bash, vim, less, curl, rsync, sudo, screen, sed, nano | various | sun26gnu.iso |
| openssl, libiconv, libintl, libidn, libgcc, gzip, ncurses, zlib | -- | sun26gnu.iso (the dep closure) |

gdb 4.17 is the *right* version, not a compromise: gcc 2.95.3 emits stabs
and 4.17 reads stabs natively; a newer gdb is harder to build on 2.6 and no
better here. It ships as a `.pkg.tgz` (directory-format, not a datastream):
`gzip -dc … | tar xf -`, then `pkgadd -d /tmp all`.

**Still missing: OpenSSH/sshd** (the `scp -P 2222` path). Bigger lift than
the rest: Solaris 2.6 has no `/dev/random`, so OpenSSH needs the **prngd**
entropy daemon, plus host-key generation, a privsep `sshd` user + `/var/empty`,
and an rc script. Deps (openssl/zlib/libgcc) are already on. Deferred for
now -- wget covers guest-side pulls, and the Helios agent (not scp) is the
production transfer path anyway.

**Solaris 2.6 gotchas worth not re-learning:** `crle` does not exist
(Solaris 8+); set library search via `/etc/profile` PATH, and the
sunfreeware binaries carry baked-in RPATHs (`-R/usr/local/lib`,
`-R/usr/local/ssl/lib`) so `LD_LIBRARY_PATH` is usually unnecessary.

**Console + recovery gotchas (the part that actually ate the day):**

- **Don't paste multi-line text into the QEMU console.** The emulated
  serial/keyboard overruns -- the screen floods with "processor level 12
  onboard interrupt not serviced" (the sun4m Zilog SCC interrupt) and the
  console wedges. Heredocs are the worst (an indented terminator or a
  dropped byte derails the whole thing); full-screen `vi` pastes scramble.
  Deliver files via tftp or ISO; build throwaway files with `printf`, not
  heredocs.
- **Recover a wedged console without killing the VM:** from a second Mac
  terminal, `telnet 127.0.0.1 2123` straight into the guest. Only the
  serial console is flooded; the kernel and inetd are fine, so telnet gives
  a clean shell. `sync` there before any reset.
- **A hard kill is survivable.** Installed packages are already on the
  qcow2; an unclean stop just triggers a routine `fsck` on next boot.
  Relaunch with `fullemu.sh`.

**Root shell setup (Bourne is grim out of the box):**

- `su` with no dash reads no profile and keeps your tcsh env; **use
  `su -`** for a real root login that reads `/.profile` (root's home is
  `/`, not `/root`).
- Pure Bourne `/sbin/sh` can't do a live-cwd prompt (`PS1` is static), so
  root's `/.profile` `exec`s an interactive shell once it has a tty.
  **tcsh** is preferred (matches the `tvernon` login, and the csh history
  is the point) with a `/.tcshrc` (`set prompt = "[PiSPARC:[%n]:%/]# "`,
  `set history` / `savehist`); **ksh** is the fallback, with a `/.kshrc`
  (via `$ENV`) using `PS1='[PiSPARC:[root]:${PWD}]# '`. Keep `/sbin/sh` as
  the *login* shell (single-user safety); the hand-off only fires once
  `/usr/local` is up. Use `su -` (not bare `su`) so `/.profile` is read.
- **`/etc/profile` `stty erase ^H` bug:** the legacy Bourne shell reads
  `^` as a synonym for the pipe `|`, so `stty erase ^H` parses as
  `stty erase | H` and prints `H: not found` on every login (the
  `2>/dev/null` doesn't catch the shell's own message). Quote it:
  `stty erase '^H'`. The baseline config script (`sparcstation-baseline-config.sh`)
  should emit it quoted.

## Shared folder (TFTP) — getting files into a running guest

Shipped 2026-06-19. Preferences → SPARCstation → "Use a shared folder to
copy files into the SPARCstation" (off by default). Points slirp's built-in
TFTP server at a Mac folder (default `~/macXserverTFTP`, created on enable);
`QemuEngine` appends `,tftp=<dir>` to the `-nic` line. In the guest:

```
tftp 10.0.2.2          # the slirp gateway, NOT 10.0.0.2
tftp> binary           # required, or binaries arrive corrupted
tftp> get <file>
tftp> quit
```

Read-only, one file at a time, no directory listing — tar a set into one
file for a batch (`tar --format=ustar`, not pax; 2.6 chokes on pax headers).
The setting is read only when the engine launches, so toggling it requires
a shut-down + Run (the dialog shows a "restart to apply" note while the
engine is running). The dev `fullemu.sh` defaults to the same folder. Gotcha
worth knowing: with the toggle *off*, a guest `tftp get` returns "Access
violation" (slirp answers on :69 but has no prefix to serve), not a timeout
— a wrong address gives the timeout.

## OpenSSH on the image (2026-06-20)

Got OpenSSH 5.1p1 running on the 2.6 image, which gives `scp -P 2222`
file-out (retiring the FTP-volume workaround) and a clean remote shell.
It's a fiddly bring-up; the `guest/` scripts automate it:

- **Source.** The sunfreeware Solaris 2.6 SPARC tree is mirrored (live) at
  `http://download.nust.na/pub3/solaris/sunfreeware/pub/unixpackages/sparc/5.6/`
  (plain HTTP — important, you can't TLS-fetch the SSL libs you don't have
  yet). `guest/get-openssh.sh` wgets the matched set straight onto the guest
  over slirp NAT (avoids tftp's few-MB ceiling).
- **The OpenSSL soname trap.** The only 2.6 OpenSSH builds are from 2008 and
  link `libcrypto.so.0.9.8`. The image already had OpenSSL **1.0.0**
  (`SMCossl`), and `pkgadd` won't install a second `SMCossl`. Fix without
  disturbing 1.0.0: `guest/add-openssl098-libs.sh` extracts just the 0.9.8
  runtime `.so` files (via `pkgtrans`, no install) into `/usr/local/ssl/lib`
  alongside the 1.0.0 set. The loader picks each by soname, so wget/curl keep
  1.0.0 and sshd gets 0.9.8. The unversioned compile-time symlinks stay on
  1.0.0.
- **Privilege-separation user.** 2.6 has no `sshd` user. Create it +
  `/var/empty` (755 root:sys) or sshd exits with "Privilege separation user
  sshd does not exist".
- **Host keys** live in `/usr/local/etc/` (`ssh_host_rsa_key`,
  `ssh_host_dsa_key`); generate once with `ssh-keygen`. Skip the v1
  `ssh_host_key` — sshd just disables protocol 1.
- **Entropy.** No `/dev/random` on 2.6, so `prngd` feeds OpenSSH via
  `/dev/egd-pool`. Seed it from `/var/adm/messages`.
- **Boot persistence.** `guest/sshd-init.sh` -> `/etc/init.d/sshd` with
  `S98sshd`/`K30sshd` rc links brings prngd + sshd up on every reboot (it
  sets `LD_LIBRARY_PATH=/usr/local/ssl/lib:/usr/local/lib` since there's no
  `crle` on 2.6, and avoids `pkill`, which 2.6 lacks).
- **Connecting from a modern Mac.** macOS ssh disables the vintage
  algorithms (and removed `ssh-dss` entirely). The working client options
  are baked into a `Host sparcplug` block in `~/.ssh/config`:
  `HostKeyAlgorithms +ssh-rsa`, `KexAlgorithms +diffie-hellman-group1-sha1,
  diffie-hellman-group14-sha1`, `Ciphers +aes128-cbc,3des-cbc`. Then
  `ssh sparcplug` / `scp file sparcplug:` just work.

Still off the Helios critical path (the agent uses its own port), but the
file-out and shell convenience is real.

## Helios daemon on the image (2026-06-23)

Baking the Helios control daemon into the image (the C2 step). Unlike the
sunfreeware bring-ups above, the daemon isn't on a mirror — it's the cx tree
on this Mac — so `guest/get-helios.sh` runs **on the Mac** and ships the
source up, rather than wgetting it down on the guest. The flow:

1. **Build source tars.** The top-level cx makefile already has the targets:
   `make cxlibs_unix.tar cxapps_unix.tar` (ustar, no .o/.a, into `cx/ARCHIVE`).
2. **Transfer.** helios `put_file` if the daemon's already up (the upgrade
   path), else `scp` to the guest (the from-scratch bootstrap). Both land the
   tars under `$ROOT` (default `/export/home/tvernon`).
3. **Build on the guest** (g++ 2.95): the daemon links the cx static libs, so
   the cx libs build first (`cd cx && make`), then the agent
   (`cd cx_apps/heliosAgent && make`). `cx/`, `cx_apps/`, and the built `lib/`
   have to be siblings under `$ROOT` (the makefile's `../../lib` / `-I../..`
   are relative to `cx_apps/heliosAgent`). The cx makefile is platform-aware —
   it builds every lib but skips what g++ 2.95 can't compile (tz/cctz), so a
   plain `make` is correct; no manual lib subset. **`make clean` before each
   build** (libs, then agent): the untarred source carries its Mac mtime, often
   older than a prior run's `.o` on the guest, so without the clean `make`
   would think nothing changed and redeploy a stale binary. A fresh image has
   no `.o` so it only bites the re-run/upgrade path, but the clean makes every
   run deterministic.
4. **Install.** `cx_apps/heliosAgent/deploy.sh` drops the binary, wires the
   `S98`/`K30` rc links (start at multiuser, kill on the way down), restarts.

The build + install run over `ssh sparcplug`, not over helios — deploy.sh
restarts the daemon, which would sever a helios connection mid-step. Only the
transfer uses helios.

- **The `eeprom`-on-PATH gotcha (cost us once).** The init script reads the
  per-boot secret with `eeprom` (`/usr/sbin/eeprom`). If the PATH used to run
  `deploy.sh` omits `/usr/sbin`, the restart silently comes up with **no
  secret — an unlocked daemon** — and nothing errors except a one-line
  `eeprom: not found`. `get-helios.sh` exports `/usr/sbin:/sbin` for exactly
  this reason. The boot rc environment has them, so a real reboot is fine; it's
  only the deploy-time restart that needs the explicit PATH.
- **Boot marker.** The init script echoes `heliosAgent started` to the console
  on a successful start (it's this script's stdout during rc2) — a reliable
  late-boot landmark that coincides with when `hello` first answers.
- **Real-Sun caveat.** On emulated SPARCplug the build is tolerable because a
  fast modern host CPU is doing the work. On a *real* SPARCstation the same
  clean-rebuild will be far slower (it's genuinely a mid-90s CPU). Fine as a
  one-time prep step, but don't expect SPARCplug timings on iron.

## Surprises and gotchas (lessons from the bring-up)

Things that ate time today, recorded so they don't eat time again.

- **Debug builds silently kill the bundled engine (code signing).** Xcode
  ad-hoc signs the Debug `.app`, but the embedded qemu helper is
  Developer-ID + hardened runtime. A hardened-runtime Dev-ID binary nested
  in an ad-hoc bundle is an inconsistent context, so AMFI SIGKILLs it at
  launch: exit 137, no console output, the SPARCstation window just sits on
  "Stopped" with no error. Same bytes run fine from `dist/` or `/tmp` —
  only the in-`.app` location dies. Fix: `project.yml`'s Debug-only embed
  post-build step re-signs the helper + dylibs ad-hoc after copying. Release
  is unaffected (uniform Dev-ID + hardened + notarized — the only correct
  ship posture; see PLUGIN_V1_PUNCHLIST A3–A5). Diagnose with
  `…/Contents/Helpers/qemu-system-sparc --version`: exit 137 = broken.
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

- **Build a stripped QEMU.** DONE 2026-06-16, in the SPARCplug repo
  (`build-qemu.sh`). `--target-list=sparc-softmmu` plus disable every
  UI/codec/crypto/audio/optional feature. Result is an 8.6 MB binary
  that boots Solaris 2.6 to login, deps down to glib + bundled libslirp.
  Goes as a nested helper in `MacXServer.app/Contents/Helpers/`. Not a
  fork — vendored qemu-9.2.4, see the 2026-06-16 section above and the
  SPARCplug `qemu.lock`.
- **Bundle the OpenBOOT ROM.** OldSilicon's distribution side
  solves the legal question. Embed as a resource alongside the
  binary. (`pc-bios/openbios-sparc32`, already in the build tree.)
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
without homebrew, Terminal, or any setup step.

> **Superseded in part by the 2026-06-16 decision above.** The
> code-vs-data split moved the engine (qemu binary + dylibs + ROM)
> *into* `MacXServer.app`, so the on-demand payload is now just the
> disk image, not a self-contained plugin bundle carrying the binary.
> The download/verify/Install-flow UX below still holds; the bundle
> *contents* shrink to the image. Kept for the install-flow detail and
> the alternatives-considered record.

### On-demand payload (UX shape)

Keep macXserver's base download small-ish. The engine rides in the app;
the Solaris disk image is the optional payload the app pulls down on
demand from the OldSilicon CDN (which already distributes the image).

On-demand payload on disk:

```
~/Library/Application Support/macXserver/
  SS5-cde-ready.qcow2  Solaris 2.6 image + a savevm snapshot "cde-ready"
                       (downloaded gzipped ~250 MB, decompressed ~1.3 GB)
```

The engine the image needs (`qemu-system-sparc`, glib dylibs, the
`openbios-sparc32` ROM) is already present inside `MacXServer.app`,
signed and notarized with the app. The image is pure data: just a file,
no signing, removable with one `rm`. It's written to this writable path
directly (by absolute path, never relative to the app bundle), so user
state persists and re-install doesn't nuke it.

Distribution: a single `.tar.gz` of the plugin plus a tiny
`manifest.json` (version, URL, sha256, size) hosted alongside it.
macXserver fetches the manifest only when the user clicks Install. No
background polling, no telemetry on first launch.

Install flow inside macXserver:

- `macXserver → Install SPARCplug…` opens a sheet: "Adds a working
  SPARCstation 5 with Solaris 2.6 and CDE. ~250 MB download. From
  oldsilicon.com." (Engine's already in the app; this fetches only the
  disk image.)
- Click Install: NSURLSession streams the gzipped image with a progress
  bar, SHA256 verified against the manifest before decompressing, atomic
  move into Application Support.
- One small wizard question before first boot: "DNS server (optional)."
  Default `8.8.8.8 / 1.1.1.1` (which works on any network with
  outbound Internet); the user can override to their own resolver
  (their pi-hole, their corporate DNS, their LAN DNS box) if they
  have one. The chosen value gets written into the writable copy of
  `SS5-cde-ready.qcow2`'s `/etc/resolv.conf` before the first boot
  via a tiny one-shot guest agent OR by mounting the qcow2 on the
  Mac side and editing the file directly (qemu-img's qcow2 driver
  supports this offline). Saves users from rediscovering that the
  default `8.8.8.8` is fine but suboptimal in their environment.
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
- **Mac-side DNS forwarder daemon at `10.0.2.3`** (or another fixed
  slirp-internal address). Instead of baking a static
  `/etc/resolv.conf` into the disk image, run a tiny resolver on the
  Mac that forwards guest queries to whatever resolver the user
  prefers, with macXserver's Preferences exposing the choice. The
  guest's `/etc/resolv.conf` stays unchanged across user network
  swaps (home → coffee shop → corp VPN). Costs: bind permission on
  port 53 (sandbox awkwardness), more moving parts, replicates work
  libslirp's stub forwarder is supposed to do (the same forwarder
  that's broken on macOS and started this whole detour). Lean: defer
  to "v2 networking" if the static `/etc/resolv.conf` proves too
  brittle in the wild; not worth shipping in v1.

### QEMU bundling mechanics (the homebrew-style dep tree problem)

Homebrew's QEMU is a fat developer install: every target, every UI
backend, every codec, every optional feature, ~30 dylibs of deps.
None of that is what we want to ship. The right move is to NOT ship
the homebrew binary at all; build our own trimmed QEMU and bundle the
few surviving dylibs into the plugin.

**Step 1: collapse the dep list at configure time.** For headless
SPARC-only QEMU driving slirp networking, almost every homebrew dep
is dead weight. The canonical, working flag set lives in SPARCplug's
`build-qemu.sh` (don't hand-copy from here; that script is the source
of truth and was validated against qemu-9.2.4's actual options). The
shape, for reference:

```
./configure --target-list=sparc-softmmu \
  --enable-tcg --enable-slirp \
  --disable-fdt --disable-pixman \
  --disable-sdl --disable-gtk --disable-cocoa --disable-curses --disable-vnc \
  --disable-dbus-display \
  --disable-opengl --disable-virglrenderer --disable-spice \
  --disable-gnutls --disable-nettle --disable-gcrypt \
  --disable-libssh --disable-curl --disable-libnfs --disable-libusb --disable-brlapi \
  --disable-coreaudio --disable-png \
  --disable-bzip2 --disable-lzo --disable-snappy --disable-zstd \
  --disable-rdma --disable-vde --disable-capstone --disable-vmnet \
  --disable-attr --disable-libdaxctl --disable-tools --disable-docs
```

Notes from the real build: `--enable-slirp` uses the bundled slirp
subproject (the old `=internal` syntax is gone in 9.2). `--disable-fdt`
(no device tree on sun4m), `--disable-pixman` (QEMU's internal fallback
backs the cold-path TCX surface), `--disable-png`, `--disable-coreaudio`
all trim further than the original guess. `--disable-dbus-display` also
dodges a broken homebrew gdbus-codegen (see the macOS python gotcha in
the 2026-06-16 section). After this, `otool -L qemu-system-sparc`
shows just libslirp (bundled) + the glib quartet:

- `libslirp` (our bundled subproject, already `@rpath`)
- `libglib-2.0` + `libgobject-2.0` + `libgio-2.0` + `libgmodule-2.0`
  (glib bundle)
- `libintl`, `libpcre2`, `libffi` (glib's transitive deps)
- `libz`, `libiconv`, `libSystem`, `libc++` (system; don't bundle)

(pixman is gone now that we `--disable-pixman`.) That's the glib
quartet + 3 glib deps + our libslirp to bundle. Stripped binary
~8.6 MB, bundled deps add ~5 MB, total ~14 MB in the binary layer.
Disk image dominates the download.

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

## Licensing and attribution (bundled engine)

How we stay compliant when we ship the engine. Decided 2026-06-16. Not
legal advice, but this is the standard, uncontroversial reading for
bundling copyleft, and it's a deliberately good-faith posture: name
everything, version everything, link the source, hide nothing.

**We're allowed to redistribute it, free or not.** QEMU is GPLv2 (as a
whole). GPL permits redistribution, bundled and commercial alike;
"we're giving it away" changes nothing, because the obligations trigger
on *distribution*, not on sale. The obligations are light.

**Bundling does not make macXserver GPL.** This is why the "two Mach-Os,
spawn qemu as a subprocess" decision matters legally as well as
technically. We don't link QEMU's code into the Swift app; we ship it
as a separate executable and talk to it over sockets. That's mere
aggregation, so macXserver keeps its own license and only the QEMU
binary (and its source) carries GPL obligations. Had we fused them into
one binary, this would be murky. We didn't, so it's clean.

**Two obligations, two mechanisms:**

1. *Include the license texts + attribution.* Lives in the app's About /
   Licenses panel. Bundle the full `COPYING` texts (not summaries, not
   just links to them), one entry per component.
2. *Make the corresponding source available.* For a component we use
   **unmodified**, the upstream source at the exact version we bundle
   *is* the corresponding source, so an upstream link at that version
   satisfies it. We host SPARCplug (our QEMU source) ourselves; for the
   prebuilt deps we link upstream at-version.

**The compliance surface (the About/Licenses panel) lists, per
component: name, exact version, full license text, an "unmodified"
statement, and a source link:**

- **QEMU** (GPLv2) -> tagged public SPARCplug repo (our build is
  unmodified upstream qemu-9.2.4, sparc-only headless; roms/ pruned).
- **OpenBIOS ROM** `openbios-sparc32` (GPLv2) -> upstream OpenBIOS source
  at the revision QEMU built the blob from. *Needs an explicit link
  because we pruned `roms/`, so the ROM's source isn't in our tree.*
- **glib** + **gettext/libintl** (LGPLv2.1) -> GNOME source at the bundled
  versions. Bundled as dylibs (dynamic linking satisfies LGPL's relink
  clause); source link satisfies the rest.
- **libslirp** (BSD), **pcre2** (BSD), **libffi** (MIT) -> permissive,
  notice text only, no source obligation. (libslirp's source also rides
  in the SPARCplug tree under `qemu/subprojects/`.)

**Two load-bearing rules:**

- *The "unmodified" statement must stay true.* It's what lets an
  upstream link stand in for hosting our own source. The day we patch
  QEMU (or anything), upstream no longer matches what we shipped, and we
  must publish *our* modified tree instead. SPARCplug going public is
  that safety net.
- *Tag SPARCplug at the exact commit each released binary was built
  from,* and keep the repo public and reachable for as long as we ship
  that binary. "Corresponding source" means the source for *that* build;
  a tag keeps it unambiguous across future QEMU bumps.

Optional bulletproofing: host our own copies of every source tarball
next to the download rather than leaning on upstream URLs surviving for
years. Strictly the obligation is ours, not GitHub's. Negligible risk
for a project this size; the upstream-at-version links are widely
accepted.

**Out of scope here: the Solaris image.** That's proprietary (Oracle),
a genuinely hard redistribution question, not a GPL checklist. It lives
with OldSilicon's distribution posture, and the NetBSD/SPARC option in
Open Questions is the legally-unencumbered hedge.

## Control plane architecture (Helios enablement)

> **Deprecated 2026-06-17 -- do not implement the NFS design below.**
> This section originally specified an NFS/NAS file plane ("Mac as NAS
> over slirp", the three boot architectures, the Option B blind-spot
> workarounds, the NFS-mounted tools directory). That whole approach is
> **superseded**. Helios now reaches the guest through a single
> **Sun-side agent on a TCP port** that proxies both command execution
> and filesystem access, with the serial console as a mix-in for
> boot/recovery. No NFS, no NAS, no shared mount, no uid squashing;
> reachable from the Mac via slirp `hostfwd`. Because the agent runs *on*
> the Sun it has total local filesystem visibility, so the entire
> boot-architecture spectrum and its blind spots evaporate -- boot from
> the qcow2, full stop. The authoritative model is `Helios-Mission.md`;
> the rationale is in DECISIONS.md (2026-06-17). The one piece that
> survives the pivot is the **modern-toolchain idea** below (gcc/gmake/
> bash/gdb on the guest), except it's baked into the qcow2 at image-prep
> time rather than NFS-mounted. The subsections that follow are kept only
> for historical context.

**Near-term payoff the agent unlocks: a curated image-repair GUI.** The
agent's file read/write also backs a Mac-side GUI that edits the ~10
things a guest image commonly needs fixed (`/etc/vfstab`, network/DNS,
timezone, root password, default shell, `inetd.conf` services, X/CDE
defaults). Structured forms, no terminal, and -- because we ship the
image -- validated against known paths and templates rather than guessed.
This can ship before or alongside the full Helios loop and is the biggest
reason the console can stay a glass TTY. Detail in `Helios-Mission.md`.

### Mac as NAS over slirp (deprecated — historical)

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

### Three boot architectures (deprecated — historical)

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

### Option B blind spots and workarounds (deprecated — historical)

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

### NFS-mounted tools directory (deprecated — toolchain now baked into the image)

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
