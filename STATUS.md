# Status 2026-06-18 (end of day)

A full day of guest-side sysadmin: bootstrapping a real dev toolchain onto
the SPARCplug Solaris 2.6 image (SUN40G.qcow2) and learning, the slow way,
how to get files into a slirp-NAT'd guest. No macXserver or engine code
changed today -- this was all image-prep on the guest, plus a new dev-only
launch helper. Image synced + `init 0`, clean.

## What landed today

**Dev toolchain on the image.** SUN40G.qcow2 now carries **gcc 2.95.3 +
GNU Make 3.82** (already native) + **gdb 4.17** + **wget 1.12 (+https)**,
on top of the full sun26gnu GNU userland (bash, vim, less, curl, rsync,
sudo, sed, nano, screen) and the matched dependency closure (openssl,
libiconv, libintl, libidn, libgcc, gzip, ncurses, zlib). Verified:
`wget --version` clean, `ldd` fully resolved, `gdb --version`, gcc/make
present.

**`fullemu.sh`** (`~/Dropbox/dev/SPARCplug/`, NOT in git). A dev-only
image-prep launcher: runs the *homebrew* `qemu-system-sparc` (11.0.1,
`brew install qemu` today) against SUN40G.qcow2 with slirp's built-in TFTP
server and an optional `-cdrom` (`CDROM=... ./fullemu.sh`). The bundled
engine stays untouched; this is the fuller engine for hand-driven prep.

**The file-injection lesson.** Getting files into a slirp guest is the hard
part: FTP is dead (Solaris 2.6's client is active-only, can't traverse
slirp NAT), slirp's built-in TFTP works but times out past a few MB, so the
answer for anything big is mounting an ISO via `-cdrom`. The dependency-hell
unlock was **sun26gnu.iso** (archive.org, 274 MB) -- a precompiled GNU set
built for Solaris-2.6-under-QEMU whose `installgnu.sh` pkgadds the whole
matched dep closure at once. gdb 4.17 came from the ibiblio mirror (the
right version: gcc 2.95.3 emits stabs, 4.17 reads stabs natively).

**Root shell made livable.** `/.profile` hands off to **tcsh** (csh
history, matches the tvernon login; ksh fallback) with a live-cwd prompt
(`su -` required; Bourne can't do dynamic prompts). Fixed the long-standing
`/etc/profile` `stty erase ^H` bug (legacy Bourne reads `^` as a pipe ->
`H: not found` each login; quoted it).

All documented in `SPARCSTATION_PLUGIN.md` (new "Image-prep: bootstrapping
the dev toolchain" section + console/recovery/root-shell gotchas) and saved
to Claude memory.

## What's working / verified

- macXserver app + X server + bundled engine: untouched, still green.
- SUN40G.qcow2: boots, full toolchain installed and verified, clean
  shutdown via `sync` + `init 0`. Dated autobackup sibling intact.
- `fullemu.sh`: homebrew qemu launch + tftp + cdrom hooks, syntax-checked.

## What's next

1. **OpenSSH on the image (deferred).** The `scp -P 2222` path. Bigger lift:
   Solaris 2.6 has no `/dev/random`, so it needs **prngd** + host keys + a
   privsep `sshd` user + an rc script. Deps (openssl/zlib/libgcc) already
   installed. Off the critical path (wget covers pulls; Helios uses the
   agent channel), so deferred.
2. **Back to plugin v1** (the actual milestone, BEFORE Helios): **A5**
   `release.sh` (sign inside-out + notarize + staple), **A6** clean-Mac
   acceptance, **Track C** image downloader, **Restore-from-Backup UI**.
   See PLUGIN_V1_PUNCHLIST.md.

## Pointers

- Image-prep recipe: `SPARCSTATION_PLUGIN.md`, "Image-prep" section.
- Dev launcher: `~/Dropbox/dev/SPARCplug/fullemu.sh` (homebrew qemu).
- Bootstrap ISO: `~/Downloads/sun26gnu.iso` (archive.org/details/sun26gnu).
- Plugin v1 work: `PLUGIN_V1_PUNCHLIST.md`.
- Image + autobackup: `~/Dropbox/dev/SPARCplug/SUN40G.qcow2` (+ dated sibling).
