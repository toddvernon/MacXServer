# Status 2026-06-30

## Headline: documented the "detect guest OS from the qcow2 itself" idea

Short session, no code. Captured a design I want to build into macXserver:
identify which OS an image is (Solaris 2.6 / SunOS 4.1.4 / NetBSD) by reading
the *bytes of the qcow2*, with no qemu tooling and no subprocess -- pure Swift,
run on the image path before we wire up ports/launcher/guest assumptions. Wrote
it up in `SPARCSTATION_PLUGIN.md` under the host-port-blocks section (new
subsection "Detecting the guest OS from the image itself").

The gist, so I don't have to re-derive it next time:
- `qemu-img` writes **uncompressed** clusters by default, so guest data sits in
  the file verbatim (metadata just interleaves between data clusters). A literal
  ASCII run like `SunOS Release 5.6` physically exists, contiguous, in the file.
  Confirm qcow2 magic (`QFI\xFB`), then `mmap` + `memmem` for a few banner
  signatures. Sub-second; scans the *physical* (allocated) size, not the 40 GB
  virtual.
- Structural discriminators DON'T work: Sun VTOC `0xDABE` is on Solaris + SunOS
  + NetBSD/sparc; UFS/FFS magic `0x011954` is on all three. Use the kernel
  banner strings instead -- `SunOS Release 5.6` (Solaris 2.6), `SunOS Release
  4.1.4`, `NetBSD 9.2`. Unique, no collisions.
- Robust because each string appears many times in the image; a cluster-boundary
  straddle can't hit every copy.
- Caveat: a `-c` (compressed) image would defeat the scan. Defense = don't
  compress (build scripts don't today) + make `.unknown` explain itself by
  checking the L2 compressed-cluster flag. Bulletproof upgrade is a real qcow2
  L1/L2 walk, ~150 lines, still no qemu. Ship the linear scan first.

This slots into open item #6 (concurrent three-images runtime): if macXserver
juggles all three at once, self-identifying each image from content beats
trusting a config field, and catches "wrong file dropped at diskImagePath" for
free.

## What's working

- All three SPARCplug guests installed: Solaris 2.6, SunOS 4.1.4, NetBSD 9.2.
- macXserver `ImagePorts` per-image host-port blocks in place (one image at a
  time today; ports wired so concurrent-three can land without a redesign).
- NetBSD boots from disk, networks (le0 10.0.2.15 via slirp), ssh in as tvernon
  on port 2242.

## What's open / next

- **Build the OS-detection helper** documented today: a pure-Swift
  `detectGuestOS(qcow2:)` returning an enum + logging the matched banner. Start
  with the linear scan.
- **#6: three per-OS launchers + concurrent runtime** -- let macXserver run
  Solaris + SunOS + NetBSD at once (multiple QemuEngine instances, per-image
  windows/console/lifecycle, a launcher per OS). ImagePorts already removed the
  host-port-collision blocker; NetBSD now exists as the third image. The
  OS-detection helper is a natural companion here.
- **tcsh on NetBSD** (Todd wants it as login shell). Not in base; 32-bit sparc
  has no official binary packages, so build from pkgsrc source:
  `cd /usr; ftp .../stable/pkgsrc.tar.gz; tar xzf; cd /usr/pkgsrc/shells/tcsh;
  make install clean; chsh -s /usr/pkg/bin/tcsh tvernon`. comp set is installed
  so the toolchain bootstraps pkgsrc. pkgsrc tree not fetched yet.
- MUST DO before any public bundled-QEMU release: run
  `Tools/make-gpl-source-bundle.sh` and attach the tarball to the GitHub release
  (the Acknowledgements screen promises a bundle that isn't live yet).
- Console terminal scrollback; xterm ctrl-button menu-orphan capture.

## Committed this session

- `~/dev/X`: SPARCSTATION_PLUGIN.md -- OS-from-image detection design.

## Switching Macs

- Let Dropbox finish syncing the cx tree + `.claude-memory/` before opening the
  other Mac.
- VM was not running this session; no stale lock to worry about.
- `git pull --ff-only` in `~/dev/X` and `~/dev/SPARCplug` on the other Mac (this
  session pushed to `~/dev/X`).
