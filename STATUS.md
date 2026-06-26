# Status 2026-06-26 (session 5)

## Ctrl+Right xterm menu fixed; Ctrl+Left works; menu-orphan still open

- **Ctrl+Button3 (VT Fonts) restored.** Our server-side xterm right-click
  Copy/Paste override (`FlippedXView.rightMouseDown`) was swallowing button 3
  unconditionally, so Ctrl+Right popped OUR menu instead of xterm's native VT
  Fonts menu. Now gated on `!ctrlHeld` -- Ctrl is xterm's own menu modifier
  (Ctrl+Btn1 = Main Options, Ctrl+Btn2 = VT Options, Ctrl+Btn3 = VT Fonts), so
  when Ctrl is held we fall through and send button 3 on the wire and xterm
  pops its own menu. Plain right-click still gets the Copy/Paste menu. Builds
  clean and **verified live** -- Ctrl+Right brings up VT Fonts as expected.
- **Ctrl+Left (Main Options) works today** per Todd -- the border_width
  coordinate worry from the session-4 banner seems to have been a non-issue (or
  is masked); leaving the banner's other half closed unless it resurfaces.

### OPEN: orphaned ctrl-button menu window (needs a past-the-release capture)

Todd saw a menu window orphan on screen again (same class as the older
move-during-menu grab bug) but couldn't reproduce on demand. Dug the last
xterm capture from session 4: `/tmp/macxcapture/2026-06-25T20-26-30-xterm.xtap`.
The menu is window `0x440002B` (child of root, override-redirect, save-under,
140x410 -- the Main Options / Ctrl+Btn1 Athena popup). Lifecycle:

- seq 2504 Map -> 2533 Unmap   (clean)
- seq 2538 Map -> 2567 Unmap   (clean)
- seq 2572 Map -> **never unmapped**

After 2572 it's all menu-highlight `PolyFillRectangle` + `MotionNotify
state=Ctrl|Button1`, then seq 2630 `ButtonRelease button=1` + `EnterNotify
mode=ungrab`, and the **capture ends right there**. No `UnmapWindow` for
`0x440002B`. Consistent with the orphan, BUT the recording stops exactly at the
release -- xterm's popdown (Notify -> XtPopdown -> UnmapWindow) would land
microseconds later and we can't see it. So: strongly suggestive, not proof.
Earlier cycles popped down cleanly, so the path works in general; something
about that last release is different.

**Next step to confirm:** reproduce with capture still running, hold past the
release. If `0x440002B` is still mapped ~100ms after the ButtonRelease it's a
real orphan, and the prime suspect is how we deliver the grab-release
Enter/Leave (mode=ungrab) that xterm's SimpleMenu relies on to pop down.

### NEW: interactive console terminal -- scoped AND spiked

Now that VM control no longer relies on the serial console (Helios drives the
guest, QMP drives the VM), turning the console teletype into a real terminal so
a user can run `vi`/`top`/`format` during recovery -- the guided-repair story
(Helios C6). Decision: **vendor libvterm (Vim/Neovim's `:terminal` core, MIT)
built from source + keep our Core Text cell renderer**; not SwiftTerm (whole
NSView + its own rendering), not a port of xterm (`charproc.c` welded to
Xt/Xaw, unliftable). vt100 / fixed 80x24 / scrollback / 16-color for v1. Zero
external deps -- one vendored source we own (same posture as bundled qemu). Full
v1 scope in **`CONSOLE_TERMINAL.md`**, decision in **`DECISIONS.md`
(2026-06-26)**.

**Spike landed this session (vendor + both halves proven):**
- **`Sources/CVTerm/`** -- vendored libvterm 0.3.3, MIT, built from source.
  Wired into *both* build systems: SwiftPM C target (`Package.swift`) and an
  XcodeGen `library.static` (`project.yml`, with `link: true` -- the default
  build-order-only dep did NOT link, symbols were undefined until forced).
  Provenance + update steps in `Sources/CVTerm/VENDOR.md`.
- **`TerminalEmulator.swift`** -- pull-based wrapper (no C callbacks):
  `feed(Data)` -> grid via `vterm_screen_get_cell`, cursor via
  `vterm_state_get_cursorpos`, input via `vterm_keyboard_*` + drained through
  `vterm_output_read`. Colors pre-resolved to RGB.
- **`TerminalView.swift`** -- NSView rendering the grid with Menlo integer
  cell metrics (ascent+descent, ceil'd), reverse/bold/underline + block
  cursor, `keyDown` -> emulator -> `onInput` bytes. The integration unknown
  (our Core Text drawing of libvterm's grid) is **resolved** -- offscreen
  render test asserts real pixels.
- **Tests:** 8 emulator (plain text, CRLF, the `ESC[2J ESC[H` erase vi uses,
  SGR bold/reverse, color->RGB, typing->bytes, Enter/arrow DECCKM, Ctrl-C->ETX)
  + 2 offscreen-render. Full suite **1428 tests, 0 failures**. Framework AND
  full app build clean in Xcode.

**Wired into the console window this session (interactive, not read-only):**
`SparcPlugConsoleWindowController` now hosts the `TerminalView` (via an
`NSScrollView`/`NSViewRepresentable`) in place of the `AttributedString` scroll
area -- the boot thermometer, header graphic + title, and Shut Down / Force
Quit buttons are unchanged; only the text area was swapped. Data path:
`SerialConsoleClient.write` added (the `-serial unix:` socket is bidirectional);
`QemuEngine.onConsoleData` (raw bytes, escape sequences intact) +
`QemuEngine.sendConsole`; AppDelegate feeds `onConsoleData -> feedConsoleData ->
emulator.feed/refresh` and binds `TerminalView.onInput -> engine.sendConsole`.
Focus on show + click-to-focus. Caption now "Interactive serial console."
**Live-verified** (Todd booted it, ran vi + cm). Follow-up fixes from that
session:
- **Perf -- the ~5s `top`/`ls` paint was the CONSOLE BAUD, not our rendering.**
  Diagnosed via Todd's `/usr/bin/time ls /etc`: 0 CPU but ~5s wall with `ls`
  blocking = a baud-limited tty (5KB / 5s = 960 B/s = exactly 9600). Same `ls`
  in an xterm (pty + X-over-TCP, no UART) is instant. The emulated ESCC itself
  doesn't pace (`hw/char/escc.c`: Tx immediate, no FIFO/timer) -- the pacing is
  guest-side (OpenBIOS/Solaris pacing by `ospeed`). **Fix: `-prom-env
  ttya-mode=38400,8,n,1,-`** (was the 9600 default; 38400 is the sun zilog max
  per the escc comment). ~4x faster, confirmed live. -prom-env is runtime-only.
  Open: test whether the guest honors >38400 (115200) since we're emulated.
- Two rendering optimizations also landed, orthogonal to the baud fix and still
  worth keeping: (1) dirty-rect diff (`TerminalView` invalidates only changed
  cells, `draw` honors `needsToDraw`); (2) coalesced `setNeedsRefresh()` so a
  burst of feed chunks collapses to one grid rebuild + draw per runloop turn.
- **Alt-screen:** `vterm_screen_enable_altscreen` on, so vi/curses' ?1047/1049
  use the alt buffer instead of scribbling the main screen. The old ?47 form
  is unhandled by libvterm 0.3.3 (cm uses it -> still redraws main screen); a
  vendored 47->1047 patch is the follow-up if it matters.
- **libvterm stderr spam** (`Unhandled CSI t`, `Unknown DEC mode 47/2026`) was
  its `DEBUG_LOG`, active because the project's Debug `DEBUG=1` was inherited by
  the CVTerm compile. Overrode CVTerm to `NDEBUG` (project.yml) + `-UDEBUG`
  (Package.swift); silent now in both build systems.
- **Priority inversion** (pre-existing, surfaced on `init 5`): `QmpClient.close`
  joined its reader thread from a higher-QoS caller -> Thread Performance
  Checker backtrace. Bumped `QmpClient` + `SerialConsoleClient` reader queues to
  `.userInitiated`.
- **Dirty-rect erase bug:** `draw` blanket-filled the dirty *bounding box*
  before redrawing only the dirty cells, erasing live cells between scattered
  changes (text vanished under a cursor jump). Removed the wholesale fill --
  each cell paints its own bg, redraw only cells intersecting the dirty region.
- **cm hung at startup ("hit Enter 3x")** = our emulator was a one-way street.
  cm runs `/usr/openwin/bin/resize`, which sends `ESC[999;999H ESC[6n` and
  blocks reading the cursor-position reply. libvterm queues that reply during
  `feed()` but we only drained its output on the *keyboard* path. Now `feed()`
  drains too and routes via `TerminalEmulator.onOutput -> engine.sendConsole`.
  The far-corner clamp makes the reply report exactly 24;80, so resize learns
  the right size. (DA `ESC[c` answered too.)
- **top/clear root cause = TERM**, confirmed (`setenv TERM vt100` fixes top).
  Added a **"Set Up Terminal" button** (visible when running) that types
  `setenv TERM vt100; stty rows 24 columns 80; clear` at the guest (csh/tcsh).

**Still open for v1:** scrollback (`sb_pushline`); the cm alt-screen case (cm
uses the old `?47`, unhandled by libvterm 0.3.3 -> a vendored `47->1047` patch
is the fix if cm still misbehaves after the resize fix); reconcile
point-size/scaleFactor with `FontResolver`/`XTERM_FONT_QUALITY`; default the
guest console TERM in the image (SPARCplug side) so the Set-Up button isn't
needed; prune the now-unused `ConsoleSanitizer` (still feeds the String marker
path in `ingest`).

Commits this session: `306a35a` (launcher seed helios-port doc), the Ctrl+Right
fix, `671f13b` (console-terminal scope docs), and the spike. Session-4 notes
below still stand.

---

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
