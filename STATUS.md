# Status 2026-06-25 (end of day, session 4)

## ⚠️ NEXT SESSION FIRST -- xterm ctrl-button menu regression

Tonight's `border_width` origin fix (commit c6f2911) very likely broke xterm's
native ctrl-button menus: **Ctrl+Left = Main Options, Ctrl+Right = VT Fonts now
misbehave.** The fix made a child's interior origin `parent + x + border_width`
(per X11R6 `dix/window.c:669`) in `topLevelAndOffset` + `ClipListEngine`, which
fixed the scrollbar but almost certainly shifted bordered popup-menu placement /
event coords. **Decide: fix properly or disable.** If fixing: there are probably
OTHER spots that compute parent->child origins and still ignore `borderWidth` --
I only patched those two. Start by grepping for origin math that sums `x`
(or `entry.x` / `childEntry.x`) without adding `borderWidth`, especially in the
event-coordinate and menu-placement paths.

## Today, part 2 -- xterm scrollbar polish + an archaeology find

Spent the evening matching the Motif-skinned xterm scrollbar to the window-frame
chrome, and in the process surfaced a 30-year-old X11 quirk. All in c6f2911:

- **Scrollbar matches the frame's scale.** The frame draws at the AppKit backing
  scale (points); the scrollbar is X content at the X display scaleFactor. On the
  Studio Display (X 3x, backing 2x) the scrollbar's 1px bevels were 3 device px
  vs the frame's 2. Now counter-scaled by backing/scaleFactor and drawn in points
  so they match exactly. Same device footprint.
- **Crisp arrow.** AA-off so the stepper-arrow's diagonal edges are hard 1px like
  the frame and real Motif. Render regression test flags any AA blend.
- **Follows focus.** Picks active vs inactive palette from the window's key state
  (same signal as MotifFrameView.isActiveWindow); `handleFocusChange` re-issues
  the paint across the whole subtree on focus change (the scrollbar is a
  grandchild in xterm: Shell -> VT100 -> scrollbar).
- **Cursor pinned vertical.** Athena sets sb_right_arrow during a thumb drag
  (Scrollbar.c StartScroll 'c'); we now keep the up/down cursor.
- **THE ARCHAEOLOGY: honor `border_width` in the child-window origin.** xterm
  places its scrollbar at (-1,-1) with border_width=1 so the content lands flush
  at the parent origin (the border falls off-parent and is clipped) -- correct
  X11, relies on the server adding border_width. We never did, so the scrollbar
  was shifted up-left a pixel (clipped top/left bevel highlights, down-arrow
  lifted off the base). Invisible for 30 years because xterm's flat gray fill
  didn't care about a 1px shift; the Motif bevels do. xterm was right all along;
  the bug was ours. Diagnosed against `dix/window.c:669`.

## The larger thread (today, part 1) -- VM control Stages 1-3 + reconnect

Earlier today: drove `VM_CONTROL.md` to completion. macXserver drives the captive
qemu through two planes -- Helios (guest OS) and QMP (the VM). Done + live-
validated: serial console on a `-serial unix:` socket (Stage 2), lock-as-VM-handle
+ qcow2-clean orphan QMP recovery (Stage 3), Design-2 **reconnect to an orphaned
VM on launch** (engine adoption, no child Process), the **Quit-and-Detach** quit
dialog, and dev-secret continuity across a detach. See VM_CONTROL.md.

## What's working

- Full suite green: **1418 tests, 0 failures** (31 skipped = live tests).
- Scrollbar: width-matched, crisp, focus-following, vertical cursor -- all
  confirmed live by Todd.
- border_width fix is systemic + correct (dix/window.c:669); the one clip test
  that encoded the old inverted interpretation was corrected, plus a regression
  pinning the (-1,-1)+bw=1 scrollbar case.
- VM control reconnect validated live (Xcode-stop -> relaunch -> reconnect).

## What's broken / rough edges

- **xterm ctrl-button menus** (see the banner up top). The one real known
  regression from tonight.
- Console-reconnect "Ignore at launch" edge (VM control): declining the reconnect
  prompt while the VM runs leaves Claude's dev-secret file wiped until you
  reconnect. Minor, non-v1.

## What's next

1. **Decide fix-vs-disable on the ctrl-button menu regression** (banner up top).
   Most likely the first thing to look at.
2. **Stage 4 (post-v1): snapshot fast-launch.** `snapshot-save`/`snapshot-load`
   for "boot once, snapshot at the CDE desktop, fast-launch in ~2s". sun4m
   vmstate verified in VM_CONTROL.md; wants a live round-trip before banking it.
3. **Helios:** C6 more guided-sysadmin tasks; B6 daemon `make test` on Solaris +
   2 hardening items (orphan-reap, shutdown euid/exit-status).

## What's committed (recent, all pushed)

- `~/dev/X` (ahead 0 / behind 0):
  - 4974ace -- STATUS: flag the ctrl-button menu regression.
  - c6f2911 -- xterm scrollbar match-the-frame (scale/bevel/focus/cursor) +
    honor border_width systemically.
  - 9609698 -- STATUS roll for the VM control session.
  - 12b4871 / 0de9591 -- dev-secret-on-detach + Quit-and-Detach dialog.
- `~/dev/SPARCplug` (ahead 0 / behind 0) and the cx tree: unchanged this session.

## Switching to the other Mac

- VM is not running; no image lock. Clean.
- Let Dropbox finish syncing the memory dir before opening the other Mac.
- `git pull` X (SPARCplug / cx unchanged but pull anyway).
- `/sos` first -- it'll surface the menu-regression banner.

## Pointers

- Scrollbar: `MotifScrollbarRenderer.swift` (renderer, AA-off),
  `CocoaWindowBridge.paintMotifScrollbar` (point-unit scale + focus colors),
  `ServerSession` (`resolveCursorGlyph` cursor pin, `handleFocusChange` +
  `repaintSkinnedScrollbars` focus repaint, `topLevelAndOffset` border_width).
- border_width: `ServerSession.topLevelAndOffset` + `Region/ClipList.swift`
  (childBaseDx/Dy). Both cite dix/window.c:669.
- VM control: `VM_CONTROL.md`, `QemuEngine.swift`, `SerialConsoleClient.swift`,
  `QmpClient.swift`, `ImageLock.swift`, `AppDelegate.swift` (reconnect + quit
  dialog).
