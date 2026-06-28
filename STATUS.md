# Status 2026-06-28

## Headline: NetBSD 9.2/sparc is the third SPARCplug guest (built + verified)

Two sessions today. Earlier: macXserver `ImagePorts` (per-image QEMU host-port
blocks, committed f56c489). This session was all SPARCplug-side -- stood up a
NetBSD guest to join Solaris 2.6 and SunOS 4.1.4. macXserver (`~/dev/X`) itself
has no code changes today; this is a STATUS roll plus the SPARCplug work in the
sibling repo.

## NetBSD guest (sibling repo ~/dev/SPARCplug, commit f863ad0)

- **NetBSD 9.2/sparc installed and booting from disk.** Picked 9.2 because it's
  the last sparc release with a bootable ISO (9.3+ are miniroot/netboot only,
  which is miserable under qemu's NFS-less slirp). Same 9.x kernel gen / sun4m
  support as 9.4, far easier install.
- **The one gotcha worth remembering:** boot the install CD with `-cdrom ISO
  -boot d`. That hits OpenBIOS's CD-boot routine, which reads the Sun-disklabel
  boot blocks correctly. Booting the bare `sd@N` device path by hand fails
  ("Not a bootable image"), and there's no `cdrom` devalias. Full recipe in
  `~/dev/SPARCplug/docs/netbsd-install.md`.
- **Disk:** 40 GiB qcow2 (matches Solaris ceiling; sparse, ~1.25 GB real).
  Single root + 1 GB swap on purpose -- no separate /usr, so adding packages
  can't run a small /usr out of space.
- **Sets:** base, comp (dev tools), man, kernel, and the X11 *client* sets
  (xterm/xclock/libs/fonts in /usr/X11R7/bin). No Xorg server -- macXserver is
  the display.
- **Access:** root has NO password (cleared via /etc/master.passwd +
  pwd_mkdb; passwd refuses empty even as root). User `tvernon` / `kemosabe`
  (wheel, ksh). `ssh -p 2242 tvernon@localhost` then `su`. SSH verified end to
  end. NetBSD host-port block: telnet 2143 / ssh 2242 / helios 2145.
- **Run it:** `~/dev/SPARCplug/emu/netbsd-full.sh` (disk-only boot, mirrors the
  other two). Image at `~/Dropbox/dev/SPARCplug/images/netbsd/netbsd-boot.qcow2`,
  ISO at `~/Dropbox/dev/SPARCplug/iso/NetBSD-9.2-sparc.iso` (both Dropbox, not
  git). Quit the VM with Ctrl-A X; clean shutdown is `halt -p`.

## What's working

- All three SPARCplug guests installed: Solaris 2.6, SunOS 4.1.4, NetBSD 9.2.
- NetBSD boots from disk, networks (le0 10.0.2.15 via slirp), ssh in as tvernon.

## What's open / next

- **tcsh on NetBSD (Todd wants it as login shell).** Not in base (base = csh +
  ksh), and 32-bit sparc has NO official binary packages (only sparc64 does), so
  pkg_add/pkgin won't work. Must build from pkgsrc source:
  `cd /usr; ftp .../stable/pkgsrc.tar.gz; tar xzf; cd /usr/pkgsrc/shells/tcsh;
  make install clean; chsh -s /usr/pkg/bin/tcsh tvernon`. comp set is installed
  so the base toolchain bootstraps pkgsrc. Not done yet.
- pkgsrc tree not fetched yet -- once it's there, that's the path for any future
  package on this box.
- Carryover from earlier today (macXserver, still open):
  - **#6: three per-OS launchers + concurrent runtime** -- let macXserver run
    Solaris + SunOS + NetBSD at once (multiple QemuEngine instances, per-image
    windows/console/lifecycle, a launcher per OS). ImagePorts already removed the
    host-port-collision blocker; NetBSD now exists as the third image.
  - MUST DO before any public bundled-QEMU release: run
    `Tools/make-gpl-source-bundle.sh` and attach the tarball to the GitHub
    release (the Acknowledgements screen promises a bundle that isn't live yet).
  - Console terminal scrollback; xterm ctrl-button menu-orphan capture.

## Pointers

- NetBSD run script: `~/dev/SPARCplug/emu/netbsd-full.sh`; recipe
  `~/dev/SPARCplug/docs/netbsd-install.md`; memory
  `project_sparcplug_netbsd_guest.md`.
- Port-block table: `~/dev/SPARCplug/emu/README.md` and `SPARCSTATION_PLUGIN.md`.
