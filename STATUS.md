# Status 2026-06-28

## Headline: per-image QEMU host-port blocks (multi-OS groundwork) + SPARCplug code/resource split

Today was mostly SPARCplug-side, laying groundwork to eventually run three guest
OSes at once (Solaris 2.6, SunOS 4.1.4, NetBSD). The macXserver-repo deliverable
is `ImagePorts`: per-image telnet/ssh/helios host-port blocks so concurrent
images don't collide on Mac ports. The rest of the day was reorg in the sibling
`~/dev/SPARCplug` repo + the Dropbox resources dir.

## What landed in ~/dev/X (committed + pushed: f56c489)

- **ImagePorts.** Per-image host-port blocks replace the hardcoded
  2123/2222/2125 hostfwd. `QemuEngineConfig.ports` selects the block; the default
  is the Solaris 2.6 block, so the bundled image is byte-for-byte unchanged on
  the wire. Reserved blocks: SunOS 4.1.4 = 2133/2232/2135, NetBSD =
  2143/2242/2145. A test pins the per-image hostfwd output and asserts the three
  blocks don't overlap. Scheme documented in `SPARCSTATION_PLUGIN.md`. `swift
  build` + the buildArguments tests are green.
- macXserver still runs **one** image at a time. ImagePorts is only the
  groundwork; the concurrent-three-images runtime (multiple `QemuEngine`
  instances + per-image windows/console + lifecycle) is NOT built yet -- that's
  the next big piece (see What's next).

## SPARCplug work (sibling repo ~/dev/SPARCplug + Dropbox resources -- context, not this repo)

- **SunOS 4.1.4 ("sunos") networking squared away.** Renamed `ss2`->`sunos`,
  `le0` on slirp (10.0.2.15/24, gw 10.0.2.2), DNS 192.168.7.3 reachable via NAT,
  NFS left off; reboot-verified. Solaris box also renamed `SPARCplug`->`solaris`
  (done live over Helios). Two OSes ran concurrently with no port collision --
  ImagePorts proven live.
- **Image reorg.** `~/Dropbox/dev/SPARCplug/images/<os>/<os>-boot.qcow2`
  (solaris26 / sunos414 / netbsd). The 4.1.4 stack was flattened from its
  overlay+raw chain into a self-contained qcow2 (no more Desktop dependency).
  ~14G of unused images parked in `_archive/` (nothing deleted; purge later).
- **Code/resource split** (commit 9e4733f). Run scripts -> `emu/`, build/process
  docs -> `docs/`; the Dropbox dir now holds images/iso/tftproot/_archive only.
  Scripts run images in place with an `lsof`-by-inode guard (qemu's own locking
  is a no-op on macOS, so two writers would corrupt a qcow2). Images found via
  `IMAGES_DIR` (defaults to the Dropbox images dir).
- **macXserver Solaris image pref repointed** to
  `images/solaris26/solaris26-boot.qcow2` (it's a UserDefaults key,
  `sparcplug.diskImagePath`); boot-tested.

## What's next

- **#6: three per-OS launchers + concurrent runtime (the big one).** Let
  macXserver run Solaris 2.6 + SunOS 4.1.4 + NetBSD simultaneously: multiple
  `QemuEngine` instances, per-image windows/console, lifecycle, and a launcher
  per OS. ImagePorts already removes the host-port-collision blocker.
- NetBSD/sparc image doesn't exist yet (`images/netbsd/` is empty).
- Purge `~/Dropbox/dev/SPARCplug/_archive` (~14G) once satisfied.
- **Carryover from 2026-06-27 (still open):**
  - MUST DO before any public bundled-QEMU release: run
    `Tools/make-gpl-source-bundle.sh` and attach the tarball to the MacXServer
    GitHub release (GPL_SOURCE.md / the Acknowledgements screen promise a bundle
    that isn't live until it's posted).
  - Console terminal: scrollback (`sb_pushline`); reconcile terminal
    point-size/scaleFactor with FontResolver/XTERM_FONT_QUALITY; prune the
    unused ConsoleSanitizer.
  - xterm ctrl-button menu-orphan -- needs a capture past the ButtonRelease.

## Pointers

- ImagePorts: `Sources/SwiftXServerCore/QemuEngine.swift` (struct +
  `QemuEngineConfig.ports` + `buildArguments`); test
  `testBuildArgumentsPerImagePorts` in `Tests/SwiftXServerCoreTests/QemuEngineTests.swift`;
  port-block table in `SPARCSTATION_PLUGIN.md`.
- SPARCplug run scripts: `~/dev/SPARCplug/emu/{solaris-full,sunos414-full}.sh`;
  docs in `~/dev/SPARCplug/docs/`; images in `~/Dropbox/dev/SPARCplug/images/`.
