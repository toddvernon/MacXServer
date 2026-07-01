# Status 2026-07-01 (evening)

## Headline: cx builds+tests green on all 3 SPARC guests; heliosAgent + cm deployed; login/shell convergence started

Big helios day. Drove Solaris 2.6, SunOS 4.1.4, and NetBSD 9.2 entirely over
the helios daemon from the desktop Mac Studio. Got the whole cx library +
test suite + heliosAgent building and passing on all three, fixed the real
portability bugs that surfaced, deployed heliosAgent and cm to all three, put
tcsh on NetBSD, and started converging the guest login experiences on a single
runtime-deciding dotfile.

## What's working / done this session

- **cx: all 3 SPARC guests green.** cx libs + cx_tests + heliosAgent build and
  pass on Solaris 2.6, SunOS 4.1.4, NetBSD 9.2. Ports: Solaris 2125, SunOS 2135,
  NetBSD 2145 (Mac side). Real bugs found + fixed (all committed, see below):
  - NetBSD had no gmake (no sparc/9.2 pkgs) -> built GNU make 4.4.1 from source,
    installed as /usr/local/bin/make. The cx thread library was never ported to
    NetBSD (guards omitted _NETBSD_) -> added it; NetBSD normal-makefile path now
    proven (build_helios_netbsd.sh is redundant, left in place for now).
  - Solaris "thread deadlock" was really usleep() being SIGALRM-based/thread-
    unsafe -> switched the two tests that use it to select(); thread now passes,
    gate flipped to sunos4-only. tz stays excluded on Solaris (g++ 2.95, no C++11).
  - formatTimeLength printed a time_t with %ld -> garbage on NetBSD/sparc
    (64-bit time_t, 32-bit long); fixed. tz makefile pinned -std=c++11.
  - SunOS CxFile::tempName used tmpnam -> switched to mkstemp (4.1.4 has it).
- **heliosAgent redeployed to all three** from the normal-makefile binary via
  the fixed deploy.sh. Running end-to-end deploys flushed out 3 real deploy
  bugs (all fixed + committed): binary-location by MKOS (not raw uname),
  atomic install (ETXTBSY on upgrade), and SunOS /var/run pidfile (no /var/run
  on 4.1.4 -> daemons had accumulated). Deploy over ssh (SunOS has no sshd ->
  detached helios). All 3 daemons answering `helios hello`.
- **cm built + installed on all three** (`make` + `make install`). Added a
  NetBSD branch to cm's install target. Default non-MCP build, no thread dep.
- **tcsh on NetBSD:** built tcsh 6.24.13 from source, tvernon shell set to it.
- **Login/shell convergence started (Solaris = reference).** tvernon + root
  now share ONE byte-identical `~/.cshrc` on all three, deciding at runtime:
  $OSTYPE -> path + console device, $uid -> root vs user prompt/history. .tcshrc
  retired. Console TERM=vt100 now picks the right device per OS (NetBSD serial
  console is /dev/ttya, not /dev/console). See memory project_image_convergence.

## What's broken / rough

- Guest-side login/shell + tcsh setup is NOT captured as repo scripts yet
  (applied ad-hoc, all backed up as .pre-converge / .pre-unify on the guests).
  The gmake + tcsh from-source builds on NetBSD likewise aren't scripted.
- Console TERM=vt100 verified by device-selection logic, not an actual on-
  console login (needs the console). NetBSD console tty confirmed /dev/ttya.

## What's next

- **Unify root ~/.profile** the same way (it's the last per-OS file; sh, so
  branch on uname not $OSTYPE).
- Decide where the canonical guest dotfiles live in the repo (proposed
  ~/dev/SPARCplug/guest-config/) so convergence stops being ad-hoc.
- Small nits: prompt %M->%m for short hostnames (NetBSD shows FQDN); whether the
  canonical prompt should set the xterm title (SunOS's old one did).
- `expand_414_fs.md` runbook (untracked in SPARCplug) is the plan to give SunOS
  4.1.4 a roomier single disk (its 28MB root is why cx has to build on /home2).

## Committed this session (all pushed to origin/main)

- `~/Dropbox/dev/cx/cx`: 431c01b (NetBSD thread port + portability fixes)
- `~/Dropbox/dev/cx/cx_tests`: ea91404 (select()-based sleep; thread gate sunos4)
- `~/Dropbox/dev/cx` (umbrella): 94defb6 (GUEST_TOOLING_NOTES.md)
- `~/Dropbox/dev/cx/cx_apps/heliosAgent`: 35fac44 + 599e4c1 + 4dadb60 (deploy fixes)
- `~/Dropbox/dev/cx/cx_apps/cm`: b99eac4 (NetBSD install branch)
- `~/dev/X`: this STATUS roll.

## Switching Macs

- **Let Dropbox finish syncing the cx tree + `.claude-memory/`** before opening
  the other Mac.
- All the guest-side changes (shells, tcsh, deploys, cm) live in the qcow2
  images on THIS Mac's disk, not in git. The other Mac's images won't have them
  until you copy the images or re-run the steps.
- All three VMs were LEFT RUNNING this session. If you open the other Mac, shut
  them down first (or it'll show remoteLocked on the image).
