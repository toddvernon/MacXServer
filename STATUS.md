# Status 2026-07-04 (evening)

## Headline: guest logins fully converged + template user; cm terminal-size fixed the right way

All SPARCplug/cx work today; no macXserver / swift-x code touched (this repo
just gets the STATUS roll).

## What's working / done this session

- **Guest login convergence COMPLETE across all three guests** (SPARCplug
  6b3cae3). One account scheme everywhere: tvernon 1000:100(users) with GECOS
  "Todd Vernon" (was 100:wheel on SunOS, 1000:adm on Solaris; renumbered +
  chowned), users(100) group created where missing, Solaris sshd privsep moved
  1001:100 -> 22:22, /home -> export/home symlink on Solaris (autofs /home
  retired from auto_master) so /home/<user> resolves identically on all three.
  Root passwords set on SunOS + Solaris (both were EMPTY): Kemosabe1
  everywhere, tvernon kemosabe everywhere (already was, hash-verified).
- **template user (1999:100, locked password) on all three guests** with a
  canonical skeleton home. This is the stamp macXserver's future add-user
  copies; new users get uid 1001+. Per-OS add-user recipes documented in
  guest-config/README.md.
- **Canonical dotfiles now live in the repo**: ~/dev/SPARCplug/guest-config/
  (dot.cshrc / dot.login / dot.profile + deploy-dotfiles.py). One file each,
  runtime-branched ($OSTYPE / uname -r). Backlog items settled: prompt %M->%m,
  xterm title escape in the prompt (literal ESC/BEL bytes in dot.cshrc), root
  .profile unified into one uname-branched file. SunOS SMI .login tset relic
  killed. Serial-console branch sets stty rows 24 columns 80 (6c0014c).
  Deployed to all nine homes; verified by real telnet/ssh logins on all three.
- **NetBSD telnetd enabled** (plain, no -a valid) so the 2143 hostfwd actually
  serves telnet like the other guests.
- **Guest tool inventory**: ~/dev/SPARCplug/docs/guest-inventory.md (generator
  helios/inventory-all.py). Cross-guest tool matrix, flavor notes, helios
  traps (daemon PATH is minimal!, old Bourne sh, HOME=/). Raw material for the
  release "Claude guide".
- **cm serial-console wedge root-caused and fixed properly** (Todd verified on
  Mac + all 3 guests). Serial ttys report 0x0 winsize; cm busy-looped on 0
  rows. New CxScreen::syncTerminalSize() (cx 10628e4) = in-process resize(1):
  DSR probe with select() timeout, TIOCSWINSZ write-back, 24x80 fallback.
  getCursorPosition timeout-protected too. cm's three old hacks
  (fixTerminalSize/system resize, screenSubtract*, screenOverride*) removed
  (cm 4587a7e); stale .cmrc keys silently ignored. Rebuilt + installed
  /usr/local/bin/cm on all three guests (sunos4_sun4m / solaris6_sun4m /
  netbsd_sparc, all green).

## What's broken / rough

- Nothing new. Long-tail carries: 4.1.4 single-user shell tcsh-ish mystery;
  NetBSD from-source builds (tcsh, gmake) not yet captured as guest scripts;
  helios shutdown verb no-ops on 4.1.4.
- Release-password question: images ship with known passwords
  (Kemosabe1 / kemosabe). Decide before any public image release.

## What's next

- Draft the release "Claude guide" from docs/guest-inventory.md +
  guest-config/README.md (per-OS pages: identity, transport, toolchain,
  landmines).
- macXserver add-user UI someday: the guest-side recipe + template user are
  ready for it.
- Carried: sunfs tooling arc (read-only Sun/UFS extractor first); guest-side
  setup scripts for reproducibility.

## Committed this session (all pushed to origin/main)

- ~/dev/SPARCplug: 6b3cae3 (login convergence + guest-config + inventory),
  6c0014c (console 24x80 + SunOS stty-on-stdout fix).
- ~/Dropbox/dev/cx/cx: 10628e4 (CxScreen syncTerminalSize + timeout DSR).
- ~/Dropbox/dev/cx/cx_apps/cm: 4587a7e (size hacks removed, probe wired in).
- ~/dev/X: this STATUS roll.

## Switching Macs

- Let Dropbox finish syncing: cx tree (source + rebuilt Mac libs), the three
  guest images (dotfile/passwd/etc changes are INSIDE the qcow2s), and
  .claude-memory/.
- All three VMs were RUNNING on this Mac at close (script-launched, each
  holding its lock). If they stay up, the other Mac correctly sees
  remoteLocked until they're shut down here.
- Guest passwords now: root Kemosabe1 / tvernon kemosabe on ALL three.
  Pre-surgery backups on each guest: /var/tmp/dotfiles-pre-20260704.tar and
  /etc/*.bak-20260704.
