# Status 2026-07-28 (Mac Studio, end of day)

## Headline: big UX-consolidation day. Launcher seeding + the orphaned
## reserved-usernames work landed in the morning; the afternoon drove
## everything to the dashboard and cleaned up the config surface.

## What happened today

**Morning (already pushed):** the /sos found the reserved-usernames
feature uncommitted from a prior session; reviewed and landed it
(X d832ff6 + SPARCplug b78dc89). Per-OS curated launcher seeding
(Phase 3c) shipped (0087fd7): bundled fixtures seed the 7 cascaded
xterms plus the hand-verified per-OS app lists (Solaris CDE apps
sandwiched between xterms and classic X apps; 4.1.4 and NetBSD
alphabetical), scatter-positioned so nothing stacks; maze is
getopt-only so it gets -g. Studio's live machines.json reseeded and
parity-verified; laptop fixtures still carry the old xterm-only seed
(one-shot edit next time there, or live with it -- code seed is in).

**Afternoon (committed at this /eos):**

- Install wizard Network step gained an optional domain name; first
  boot writes "domain X" + "nameserver Y" to /etc/resolv.conf (same
  BSD resolver syntax on all three guest OSes).
- Settings reorg: the tabbed Preferences window and its app-menu item
  are dead. The four panes are individual X11Server menu items now
  (Display / Mouse / Cut and Paste at top level, Capture Settings
  inside the Capture submenu); the empty Network tab died. Windows
  pin to design size (unpinned NSHostingView + maxHeight-infinity
  panes grew to full screen).
- New-user seed = my runtime settings except display=auto and capture
  OFF (reversed my own "exactly like mine" call: a .xtap records
  KeyPress events, so capture-by-default = recording keystrokes).
  Pointer-defaults drift fixed: the Key comment's "identity" lie,
  PointerConfig.default documented as the deliberate inert core
  baseline, UI fallback aligned.
- ~/.macxserver-launchers is KILLED: DefaultLaunchers.swift deleted,
  dead reconcile(withMigrated:) removed, loadOrMigrate deletes the
  legacy file after import and sweeps it on already-migrated installs
  (laptop cleans itself on next launch). Mouse-pipeline audit done
  first: architecture legit, single remap authority holds.
- The two config gaps fixed: Machines > Disk Image Folder... (view +
  change images.directory, moves machine-referenced images with the
  setting, refuses while affected machines run) and Forget Password
  on the machine form (clears Keychain entry + cleartext in one go).
- Menus drive to the dashboard (new DECISIONS entry): per-machine
  submenus and the status-item dot list are gone; Machines menu is
  static (Machines... Cmd-Shift-M + Disk Image Folder...).

## What's working / what's broken

- swift build clean, zero warnings; 1587 tests green all day.
- xcodegen re-run (DefaultLaunchers deletion); project.pbxproj in
  this commit batch. Xcode should build clean.
- The Debug app running during the day predates ALL of this; restart
  it to see the new menus/launchers. If it wrote machines.json before
  restart, re-check the fixture launcher seed.
- Known theoretical edge from the mouse audit, documented not fixed:
  chorded same-wire-mapped buttons across an xterm scrollbar +
  content can strand a pendingButtonOverride (default 1/1/3 maps
  left and wheel to the same wire button).

## What's next

1. Xcode rebuild + click through everything: wizard domain field,
   four settings panes, seeded launcher positions on all three
   guests, image-folder mover, Forget Password, slimmed menus.
2. Todd's phase-1 publish half: pick the published root password,
   cut/strip --root-password/gate/--publish x3, stranger download
   test (strip now also captures release accounts + forces public
   DNS; catalog carries reservedUsernames).
3. A6 clean-Mac acceptance with the v0.9.9 beta artifact.
4. Laptop: machines.json fixture reseed (optional; new installs get
   the new seed anyway).
5. Carried: CanonicalDotfiles DISPLAY decision, UserAdmin live test
   on 2.6/4.1.4.

## Committed / push state

- X, main: morning d832ff6 / 0087fd7, plus this /eos batch (hashes
  in the /eos summary). Pushed.
- SPARCplug, main: b78dc89 (morning). Nothing new this afternoon.
- cx tree: untouched all day.

## Switching Macs

- git pull X on arrival; SPARCplug already synced from morning.
- Laptop's ~/.macxserver-launchers deletes itself on next app launch
  there; its machines.json fixture launchers are still old-seed.
- Three qemu guests were left running on the Studio under the Debug
  app (netbsd / solaris26 / sunos414 off ~/TESTIMAGES). No locks
  under Dropbox; nothing blocks the laptop.
- Let Dropbox finish syncing memory before opening the laptop.
