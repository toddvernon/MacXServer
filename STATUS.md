# Status 2026-07-02 (evening)

## Headline: SunOS 4.1.4 single-disk expansion DONE; image locking unified across scripts + macXserver

Two big SPARCplug wins today, both shipped and verified. No macXserver /
swift-x code touched (this repo just gets the STATUS roll).

## What's working / done this session

- **4.1.4 disk expansion executed end-to-end** (runbook `expand_414_fs.md` in
  the SPARCplug repo, narrative log `expand_414_fs_LOG.md` -- written as
  OldSilicon post material). One 5.4G disk replaces the old 2G boot + 2G
  /home2 pair: 1G root+var (was 28MB!), 256M swap, 2G /usr, 2G /home. /home2
  retired: content merged into /home, passwd homes moved, fstab cleaned, one
  straggler script fixed. Old pair archived in Dropbox
  `_archive/pre-expand-2026-07-02/` (that's the rollback). New qcow2 is 1.7G
  on disk vs 3.9G for the pair. Boots multiuser via the unmodified script
  path, helios-verified, tvernon login lands in /home/tvernon.
  - Build tricks that are now reusable (memory: reference_sunos414_image_surgery):
    Sun VTOC written host-side by `build414/sunlabel.py` (kernel accepted it,
    no interactive format ever); dump-to-FILE not pipes (4.1.4 restore dies
    silently on big pipe streams); serial-console bridge+marker harness
    (`build414/bridge.py` + `drive.py`); tty drops input past ~256 chars.
  - Gotchas found: single-user shell on the 4.1.4 image behaves as tcsh
    (60-min autologout exited a maintenance session mid-build -> multiuser;
    guard: `exec /bin/sh` first; root-cause open). helios `shutdown` verb
    no-ops on 4.1.4 -- use `run "sync; sync; /usr/etc/halt"`.
- **Image locking unified** (the queued task -- DONE). New
  `emu/imagelock.sh` shared by all three run scripts: writes + checks
  macXserver's exact `<image>.macxserver-lock` format, so script-held images
  show "in use" in macXserver and vice versa, and the other Mac sees
  remoteLocked via Dropbox. Stale same-host locks self-heal (pid check);
  remote locks hard-stop with FORCE=1 override (accepted: Dropbox latency can
  leave brief false positives; no LAN check by design). Cross-validated
  against compiled ImageLock.swift -- caught a host-case mismatch
  (ProcessInfo.hostName is lowercase, hostname(1) isn't). Also settled
  empirically: qemu's own fcntl lock DOES block same-Mac double-open on
  macOS; old script comments claiming otherwise fixed.
- **Console-input regression found and fixed same-day:** first lock version
  ran qemu as a backgrounded child, which POSIX-reassigns stdin to /dev/null
  -- console login went deaf. Now: lock written with $$, detached monitor
  releases it on pid death, qemu exec'd in the FOREGROUND (tty identical to
  pre-lock behavior). Verified under a real pty (expect typed at OpenBIOS and
  got answers).

## What's broken / rough

- heliosAgent `shutdown` verb doesn't actually halt 4.1.4 (BSD init, no
  runlevels). Needs an OS-aware daemon fix someday.
- Single-user-shell-is-tcsh contradicts the convergence design (base sh,
  exec tcsh only if interactive); mechanism unverified -- root-cause when
  convergence work resumes.
- `build414/big.img` (raw, 5.3G, local disk) kept until the new qcow2 proves
  itself over a few sessions; `build414/boot-work.img` is deletable anytime.
- Guest-side setup still not captured as repo scripts (gmake/tcsh from-source
  on NetBSD, shell convergence steps) -- carried over.

## What's next

- Carried from yesterday: unify root ~/.profile (one file, branch on uname);
  decide canonical guest-dotfile home (~/dev/SPARCplug/guest-config/
  proposed); prompt %M->%m; xterm-title decision.
- Discussed today, not started: "sunfs" tooling arc -- read-only Sun/UFS
  extractor CLI -> Swift library in macXserver (browse disk images) -> FSKit
  read-write Finder mount ("drag files onto a Sun disk"); creator via
  NetBSD makefs lift. Staged plan is in the 2026-07-02 session transcript;
  extractor is the de-risking first step.

## Committed this session (all pushed to origin/main)

- `~/dev/SPARCplug`: d200d4f (disk expansion + runbook + LOG + build414
  tools), c86b368 (image locking unified), d4910bb (console input fix).
- `~/dev/X`: this STATUS roll.
- cx repos: untouched today.

## Switching Macs

- Let Dropbox finish syncing (images changed: new sunos414-boot.qcow2, old
  pair moved to _archive -- that's ~4GB of churn; plus .claude-memory/).
- **NetBSD VM is RUNNING on this Mac** (relaunched via the new lock-aware
  script; it holds netbsd-boot.qcow2.macxserver-lock). The other Mac will
  correctly see remoteLocked until it's shut down here and the lock deletion
  syncs. Solaris + SunOS VMs are down, no locks.
- The new 4.1.4 image (and all guest-side state) lives in THIS Mac's Dropbox;
  wait for the sync before booting it over there.
