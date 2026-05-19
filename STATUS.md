# Status 2026-05-19 — End of day

dtcalc's LCD now renders text correctly. The fix took two real bug
closes and one wrong-diagnosis detour through ColorTable. The wrong
diagnosis still produced a worthwhile cleanup, so it stays.

## Headline

**dtcalc LCD shows "0.00" + typed digits, full visual parity with SS2.**
Same fix also unblocked quickplot's text entry fields (same root cause —
XmText widget sets clip rects on its drawing GC). Likely also closes
the about-dialog animation artifact (open issue #4 in
project_motif_quickplot_status memory); pending re-verification.


Root cause was that `SetClipRectangles`' rects (in drawable-local coords)
were being handed to `CGContext.clip(...)` at top-level coords without
translating by the widget's `windowOffset`. dtcalc's XmText display
widget sets a (5,5,25,15) clip rect; without the translation, that clip
landed in the top-left corner of the calculator's NSWindow — far from
the LCD widget at (273, 37) — and excluded every glyph the client drew.
Buttons didn't trip this because their GCs never had SetClipRectangles
called on them. Comment on `GCState.clipRectangles` even claimed the
rects were already in top-level coords, but only `clipXOrigin`/`Yorigin`
were folded in. Fix is centralized in `CocoaWindowBridge.withDrawContext`:
when the target is a window, translate the clip rectangles by the
target's `(dx, dy)` before passing to `withClip`. Pixmap targets pass
through unchanged.

## What landed

### ColorTable becomes server-global; AllocColor honors shared cells

- `ColorTable` moved from `ServerSession.colors` to
  `ServerCoordinator.colors` (parallel to `atoms`). Thread-safe via
  `NSLock`. Sessions read through a passthrough property so call sites
  stay unchanged.
- `allocate(...)` now does shared-cell RGB matching: if the requested
  RGB is already in the table, returns the existing pixel rather than
  allocating a new one. `whitePixel` (0), `blackPixel` (1), and the
  defensive `0xFFFFFF` are pinned at init with lowest-pixel-wins
  canonicalisation. `AllocColor(white)` now returns 0 as a real X
  server does.
- Dormant 22-pixel CDE palette pre-seed deleted (was kept as a safety
  net after 2026-05-18 CDE retirement; with shared-cell matching it
  became strictly harmful — coincidental RGB hits would land on the
  dormant indices).
- This was originally pitched as the LCD fix. It turned out the LCD
  bug was elsewhere (see above), but the ColorTable cleanup stands —
  it's real X-spec correctness, retires SHORTCUTS:32, and unblocks the
  per-session-vs-global cleanup that DECISIONS.md 2026-05-18 line 470
  flagged as step (1) of any future CDE re-add path.

### Clip-rectangle translation (the actual LCD fix)

- `CocoaWindowBridge.withDrawContext` now translates `clipRectangles`
  by `(dx, dy)` when the target is `.window`. Pixmap path unchanged.
- Misleading comment in `GCState.clipRectangles` ("already top-level
  coords") corrected — rects are drawable-local; bridge translates.
- Capture-diff tooling improvement: `ChronoDumper` now decodes
  `CreateGC` / `ChangeGC` value lists for foreground / background and
  prints them inline (`[fg=0x1 bg=0x0]`). Made the wire-level diagnosis
  tractable. Permanent addition, not a debug scaffold.
- Bridge-log improvement: `drawPolyText8` now includes the foreground
  RGB and the clip-rectangle list in its log line, so a future class-of-bug
  ("wire matches gold but rendering is wrong") gets diagnosed in one log
  pass instead of three rounds of "let me add another print."

### Tests

541 tests pass, 4 skipped, 0 failures.

- New `ColorTableTests.swift` (7 cases): whitePixel/blackPixel canonical
  IDs, repeated-RGB shared-cell hit, distinct-RGB distinctness, RGB
  round-trip, cross-session sharing via the coordinator.
- New `FontDispatchTests.testPolyText8PassesClipRectanglesInDrawableLocalCoords`:
  locks in the contract that handlers pass drawable-local rects and
  the bridge does the translation.
- `CapturedAppReplayTests` baselines rebased twice: once for the
  ColorTable change (lower per-app `colors` counts post-shared-cells +
  deleted-CDE-palette), once for the fresh dtcalc gold capture the
  user retook today (1918 requests vs prior 2047 — different
  pre-CDE-retirement era).

## What didn't land today

- **dt-Motif widget chrome (button shadows + labels)** — still
  unresolved from 2026-05-18. dt-app smoke is now mostly clean; the
  remaining cosmetic gap is the deep button-hierarchy chrome.
- **`PutImage` to depth-1 pixmaps is still silent-dropped** per the
  long-standing SHORTCUTS entry. Surfaced today as "dtcalc's caret
  stipple pixmap (0x44000ef) gets all-zero bits, so the caret is
  invisible." Not blocking the LCD-text fix; queued for the next
  depth-1-PutImage real-implementation pass.
- **Framer-shared bug investigation** (deferred again from 2026-05-18).

## Working tree at end of day

All implementation changes committed-pending. Untracked / modified:

- `connection.json` — set today for the u5→capture→swiftx capture run,
  output points at `dtcalc-running-on-u5-display-on-swiftx.xtap`.
- `captures/dtcalc-running-on-u5-display-on-ss2.xtap` +
  `.json` — fresh gold capture the user retook today.
- `captures/dtcalc-running-on-u5-display-on-swiftx.xtap` +
  `.json` — fresh swiftx capture from after the ColorTable fix
  (pre-clip fix, so still has the invisible-LCD-text symptom).

## Tomorrow's recommended starting points

1. **Smoke other dt-apps for LCD-style clip regressions.** Now that
   we know SetClipRectangles + sub-window draws was broken for over
   a week with nobody noticing (only dtcalc tripped it visibly), it's
   worth a smoke pass: quickplot (which uses XmText for plot labels
   maybe?), dthelpview's text area, dtterm if it sets clip anywhere.
2. **The depth-1 `PutImage` silent-drop.** Today's diagnosis surfaced
   that dtcalc's LCD caret stipple pixmap is all-zero because we drop
   the `PutImage` that should populate it. Caret is invisible (small
   cosmetic gap, but worth fixing — needed for any XmText-style
   blinking-cursor app to look right).
3. **dt-Motif widget chrome from 2026-05-18.** Still parked; with LCD
   text working the visual delta against gold is narrowing.

## Reflection

Two lessons from the day. First: the diagnosis-by-capture-diff path
worked exactly as the project conventions promise. When the wire was
identical between SS2 and swiftx for the LCD widget — same opcodes,
same pixel values, same order — the bug had to be in our rendering.
Adding `fg=…` to the dumper's `ChangeGC` output and adding clip-rect
logging to the bridge made the bug visible in one capture run.

Second: I went down a wrong-diagnosis path early ("Motif fallback
gives pixels[6].bg = near-white, so white-on-white invisible") that
was internally consistent with the dtcalc source but didn't actually
match the wire. Todd's question — "on SS2 the LCD text is black, how
can that be?" — was the right counter. The hypothesis I had didn't
predict what real SS2 does. When that gap appears, the right move is
to stop speculating and take a capture, not to add another layer of
"maybe also..." reasoning. The ColorTable cleanup still landed and is
worth having, but I should have caught earlier that it wasn't going to
fix the visible bug.
