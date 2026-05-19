# Status 2026-05-19 — End of day

Three real X-server bugs closed, one cosmetic gap left open with a
clear diagnostic path for tomorrow. dtcalc, dthelpview, and
quickplot all visibly better than this morning.

## Headline

**Three closes:**
1. **dtcalc LCD shows "0.00" + typed digits**, full visual parity with SS2.
   Root cause: `SetClipRectangles` rects (in drawable-local coords) were
   handed to `CGContext.clip(...)` at top-level coords without translating
   by the widget's `windowOffset`. dtcalc's XmText LCD sets a `(5,5,25,15)`
   clip rect; without translation that clip landed in the top-left corner
   of the calculator's NSWindow and excluded every glyph. Fix centralized
   in `CocoaWindowBridge.withDrawContext`.

2. **Quickplot text entry fields work** — same root cause as #1 (any
   XmText widget that sets clip rects on its drawing GC). The 2026-05-10
   "weird spacing" diagnosis was wrong; text was rendering correctly into
   a clipped-out region.

3. **dthelpview man-page area renders.** Different bug: when a
   non-top-level window maps and its parent chain was already viewable,
   every already-mapped descendant also becomes viewable simultaneously
   and needs Expose. Our non-top-level MapWindow handler only emitted
   Expose for the directly-mapped window. dthelpview maps DisplayArea +
   scrollbars BEFORE the wrapper shell, so without the cascade the
   DisplayArea never got Expose. Fix in `ServerSession.handleMapWindow`
   non-top-level branch — walk `mappedDescendantSnapshots(of: r.window)`
   and emit Expose for each with ExposureMask.

**One cosmetic remaining (open for tomorrow):**
- dthelpview man-page content area renders on Motif fallback blue
  instead of white, and the window aspect is wider than SS2's.
- Canonical CDE Dt.ad resource overrides added to Tier 1 but didn't
  take effect on `-manPage` mode. Full diagnostic path in the dedicated
  memory note `project_dthelpview_cosmetic_open`. Short version: read
  the DisplayArea's CreateWindow bytes via fresh capture, don't guess
  at resource paths.

## What landed (with file pointers)

### Clip-rectangle translation (the dtcalc / quickplot fix)

- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` `withDrawContext` —
  translates `clipRectangles` by `(dx, dy)` when target is `.window`.
  Pixmap path unchanged.
- `Sources/SwiftXServerCore/GCState.swift` line ~45 — corrected
  misleading comment ("already top-level coords" → "drawable-local;
  bridge translates").
- New test `Tests/SwiftXServerCoreTests/FontDispatchTests.swift`
  `testPolyText8PassesClipRectanglesInDrawableLocalCoords` — locks in
  the handler→bridge contract (drawable-local rects; translation in
  withDrawContext).

### Descendant Expose cascade on MapWindow (the dthelpview fix)

- `Sources/SwiftXServerCore/ServerSession.swift` MapWindow non-top-level
  branch (search for "every already-mapped descendant also transitions")
  — after the existing per-window Expose, walks the mapped subtree and
  emits Expose for each descendant with ExposureMask. Mirrors what
  `emitMapSequence` does for the top-level path.
- No replay-test baselines moved (existing fixtures don't exercise the
  "children-mapped-before-wrapper" pattern). Would surface if we add a
  dthelpview replay test.

### ColorTable becomes server-global; AllocColor honors shared cells

- `Sources/SwiftXServerCore/ColorTable.swift` — thread-safe, `rgbToPixel`
  reverse map, `allocate()` checks for existing-RGB match before
  allocating new. `whitePixel` (0), `blackPixel` (1), and defensive
  `0xFFFFFF` are pinned at init with lowest-pixel-wins canonicalisation.
  `AllocColor(rgb=white)` now returns `whitePixel` like a real X server.
- `Sources/SwiftXServerCore/ServerCoordinator.swift` — `public let colors`
  added next to `atoms`.
- `Sources/SwiftXServerCore/ServerSession.swift` — `colors` is now a
  passthrough property to `coordinator.colors`.
- Dormant 22-pixel CDE palette pre-seed deleted.
- New test `Tests/SwiftXServerCoreTests/ColorTableTests.swift` (7 cases).
- Originally pitched as the LCD fix; turned out NOT to be (capture-diff
  showed wire-level identity with SS2 regardless). Still a real X-spec
  correctness fix, still retires SHORTCUTS:32 cleanly.

### Tier 1 RESOURCE_MANAGER additions

- `Sources/SwiftXServerCore/DefaultMotifResources.swift` — added CDE
  Dt.ad's canonical DisplayArea bg/fg overrides + `Dthelpview*manBox.rows/columns`.
  Publishes cleanly (GetProperty reply grew 1911→2598 bytes) but doesn't
  fix the dthelpview cosmetic gaps (see open item).

### Tooling improvements (permanent, not debug scaffolds)

- `Sources/SwiftXCaptureCore/ChronoDumper.swift` — `CreateGC` and
  `ChangeGC` now decode value lists and print `[fg=0x1 bg=0x0]` inline.
  Made the wire-level dtcalc diagnosis tractable in one capture run.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` `drawPolyText8` log
  line — now includes `fg=` and `clip=`.

### Docs / ledgers

- `SHORTCUTS.md` — two Closed entries (clip-rect translation, MapWindow
  descendant Expose cascade); one Open entry (dthelpview cosmetic gaps
  with diagnostic path).
- `OPCODE_STATUS.md` — `AllocColor` (entry 84) raised to high confidence
  + shared-cell text. `MapWindow` (entry 8) updated with the descendant
  cascade.
- `DECISIONS.md` — entry for the ColorTable coordinator move +
  postscript noting it wasn't the LCD fix.
- Memory updates: `project_motif_quickplot_status` (open issue #2
  closed; #4 likely closed pending re-verification),
  `project_dt_apps_status` (today's three closes summarized),
  `project_dthelpview_cosmetic_open` (NEW — focused handoff for
  tomorrow's first task), `feedback_wire_matches_gold` (NEW — diagnostic
  lesson learned).

### Tests
541 tests pass, 4 skipped, 0 failures. 8 new tests today (7
ColorTable + 1 clip-translation regression).

## What's still open (tomorrow's queue)

1. **dthelpview cosmetic** (TOP PRIORITY — fresh in our heads). See
   `project_dthelpview_cosmetic_open` memory for the full diagnostic
   path. Short version: take a fresh `dthelpview -manPage` capture vs
   SS2 gold; read the DisplayArea's CreateWindow `valueMask` to check
   whether CWBackPixmap=ParentRelative (=1) or CWBackPixel resolves
   blue. Don't guess at resource paths first — read the bytes.

2. **Smoke other dt-apps for clip-rect regressions.** dtcalc was the
   visibly-affected case; with the fix in we should sanity-check
   dthelpview text widget interactions, dtterm if it sets clip,
   anywhere XmText is used. Most likely already-fixed by the same
   commit; just want to confirm.

3. **`PutImage` to depth-1 pixmaps silent-drop.** Surfaced today as
   "dtcalc's caret stipple pixmap gets all-zero bits, so the LCD caret
   is invisible." Same shape would affect any XmText-style blinking
   cursor. Long-standing SHORTCUTS entry. Cosmetic but easy to fix.

4. **dt-Motif button chrome from 2026-05-18.** Still parked. With LCD
   text + dthelpview content + quickplot text fields all working, the
   visual gap to SS2 is narrowing; this is the last big item.

5. **Framer-shared bug investigation** (deferred again).

## Working tree at end of day

Two commits today on `main`:
- `a8729d1` — dtcalc LCD: translate clip rects by widget windowOffset
  (also bundles ColorTable cleanup, ChronoDumper improvements, fresh
  captures, CLAUDE.md preflight fix)
- `9291950` — dthelpview: cascade Expose to descendants when wrapper
  shell maps (also bundles partial CDE resource additions + STATUS update)

Plus this STATUS rewrite (pending commit, not yet staged).

## Reflection

Two lessons from the day worth remembering:

**Capture first, speculate second.** I went deep on the wrong
diagnosis for the dtcalc LCD ("Motif fallback gives pixels[6].bg =
near-white, so white-on-white invisible"). It was internally consistent
with dtcalc's source but didn't actually match the wire. Todd's pushback
— "on SS2 the LCD text is black, how can that be?" — was the right
counter. A capture-diff took five minutes and pointed straight at
the clip-rect bug. Memory `feedback_wire_matches_gold` captures this
specifically.

**The ColorTable cleanup landed anyway.** Wrong diagnosis still
produced real correctness work — coordinator-owned colormap, shared
cells, retires SHORTCUTS:32. The wrong-path cost was the time spent on
it; the output stands on its own merits.

**Centralized translation > per-handler fixes.** The clip-rect fix
landed in one place (`withDrawContext`) and instantly fixed three
visible bugs (dtcalc LCD, quickplot text fields, probably
quickplot about-dialog animations). Same shape for the MapWindow
descendant cascade — one helper (`mappedDescendantSnapshots`) reused
in two places. Both fixes are roughly 8 lines each, but only because
the right factoring already existed in the codebase.
