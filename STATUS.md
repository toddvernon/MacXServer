# Status 2026-07-04 (late)

## Headline: guest login convergence + template user shipped; then a cascade of real fixes (cm 2.8, real SS5 hardware, 3 macXserver launcher bugs, a hand-built color xterm)

Long, branchy day. The planned work (guest convergence) landed early; the
rest was emergent bugs, each fixed and committed. All code is pushed. The
color xterm lives on the 4.1.4 qcow2 image (an image artifact, not a repo).

## What's working / done this session

- **Guest login convergence COMPLETE** (SPARCplug 6b3cae3): one account
  scheme on all 3 guests (tvernon 1000:100 users, GECOS set), locked
  `template` user 1999:100 seeding a canonical home for macXserver's future
  add-user, canonical runtime-branched dotfiles in guest-config/,
  deploy-dotfiles.py, docs/guest-inventory.md (tool survey, raw material for
  the release "Claude guide"). Root pw Kemosabe1 / tvernon kemosabe on all 3.
- **Serial-console 24x80 dotfile fix** (SPARCplug 6c0014c): fixes cm wedging
  on the 0x0-winsize console; also fixed SunOS stty-acts-on-stdout no-op.
- **cm terminal-size done right** (cx 10628e4, cm 4587a7e): CxScreen::
  syncTerminalSize() = in-process resize(1) (DSR probe + TIOCSWINSZ + 24x80
  fallback, timeout-safe); removed the fixTerminalSize/system-resize +
  screenSubtract/Override hacks. Rebuilt + reinstalled cm on all 3 guests.
- **cmacs 2.8 released** (cm b054d93, tag v2.8): GitHub release with
  cmacs-macos.tar.gz + cmacs-linux.tar.gz; all 3 guests re-revved to 2.8.
- **Real SS5 hardware booting** off HD3_Sun414_512.img (from the 4.1.4
  image, ss5-configured network), on the LAN at 192.168.7.19, helios-
  reachable. See memory reference_qcow_to_real_sparc_zuluscsi.
- **3 macXserver launcher bugs fixed** (all "assumed target == bundled
  emulator"): HeliosClient getaddrinfo not inet_aton so hostnames resolve
  (e8fc3ea); filebrowser/launcher gating + secret only for the loopback
  target, external Suns enabled unconditionally (e01b36a); HeliosLauncher
  cd $HOME so launched apps open in home not / (7cac700). Tests updated.
- **X11R6 color xterm built + installed on the 4.1.4 image**: MIT X11R6
  xterm + Cray/SGI ANSI-color patch + my cursor-artifact fix
  (HideCursor/ShowCursor now push each cell's stored fg/bg into the GC like
  ScrnRefresh -- kills the blue cursor trail with cm). Built with cc (SPARC
  v7, runs on the SS2 too). Installed /usr/openwin/bin/xterm (Sun original
  = xterm.old). Source archived at /usr/local/src/colorxterm on the image
  (NOTES.txt + patch/ with both diffs). Staged at /Volumes/FTP/xterm.color
  for the SS2 to anon-FTP -- Todd confirmed the FTP grab works.

## What's broken / rough

- Nothing new open. The color xterm needs /usr/X11R6/lib (4.20 libs) on any
  target box (present if it runs mwm) -- documented, not a bug.
- Long-tail carries: 4.1.4 single-user-shell-is-tcsh mystery; NetBSD
  from-source builds not captured as guest scripts; helios shutdown no-ops
  on 4.1.4.
- Release-password question still open (images ship Kemosabe1/kemosabe).

## What's next

- Draft the release "Claude guide" from docs/guest-inventory.md +
  guest-config/README.md.
- macXserver add-user UI someday (template user + per-OS recipe are ready).
- Rebuild macXserver in Xcode to pick up the 3 launcher fixes (e8fc3ea /
  e01b36a / 7cac700) -- they're committed but the running app is older.
- Carried: sunfs tooling arc (read-only Sun/UFS extractor first).

## Committed this session (all pushed to origin/main)

- ~/dev/SPARCplug: 6b3cae3 (convergence + guest-config + inventory),
  6c0014c (console 24x80 + SunOS stty fix).
- ~/Dropbox/dev/cx/cx: 10628e4 (CxScreen syncTerminalSize).
- ~/Dropbox/dev/cx/cx_apps/cm: 4587a7e (size hacks removed), b054d93
  (Release v2.8, tag v2.8, GitHub release w/ both tarballs).
- ~/dev/X: e8fc3ea (getaddrinfo), e01b36a (launcher gating), 7cac700 (cd
  $HOME), plus STATUS rolls e8b0af1 / b0785c8 / this one.

## Not in any repo (by design)

- The color xterm binary + source live on the 4.1.4 qcow2 image only
  (/usr/openwin/bin/xterm, /usr/local/src/colorxterm). Copies of the binary:
  /Volumes/FTP/xterm.color (the FTP-share one Todd uses), ss5:/home/tvernon/
  xterm.color, /Volumes/NFS/hosts/ss5/xterm.color. sum = 37852 208.
- ss5 real-hardware image HD3_Sun414_512.img on the ZuluSCSI SD + NFS share.

## Switching Macs

- Let Dropbox finish syncing: cx tree, .claude-memory, and the 3 guest
  qcow2 images (login/passwd/dotfile changes + the color xterm + colorxterm
  source are all INSIDE the sunos414 qcow2 -- that's real churn).
- Guest passwords: root Kemosabe1 / tvernon kemosabe on all 3.
- macXserver has 3 committed launcher fixes not yet in a rebuilt app.
- Leftover test xterm windows may be cluttering the emulator screen (Todd
  can drop them anytime; harmless).
