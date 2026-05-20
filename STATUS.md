# Status 2026-05-19 — End of day

The X server's bg-paint contract is now honored end-to-end. Three big
visible fixes plus a tooling boost that paid for itself the day it
landed. dthelpview, xterm, and most of quickplot's open plot-window
artifacts all unstuck by a single architectural correction.

## Headline

**Three closes:**

1. **dthelpview renders with proper white DisplayArea and blue form
   border, no leftover blue rectangles after expand.** Root cause was
   two-part: (a) draw ops weren't clipped to the window's visible region
   (`clipList`) so a parent's bg paint or Motif's `ClearArea` on the
   form bled right through descendant windows; (b) `handleConfigureWindow`
   updated geometry + emitted Expose but never painted the descendant's
   bg into newly-claimed pixels, so the form's L-shape of new pixels
   after expand stayed as fresh-bitmap-white.

2. **xterm `-bg black -fg cyan` renders correctly black with cyan text
   on black cells.** `GCState.background` default was `0xFFFFFF`, which
   resolved to whitePixel after the 2026-05-19 (earlier today) ColorTable
   canonicalization. xterm relies on the spec default for GC bg
   (background=1 = blackPixel per X11 spec); we were handing it white.
   One-line fix to GCState; verified live.

3. **Quickplot's plot-window drawing artifacts mostly resolved as a
   bonus.** Todd reports today's bg-paint-contract fixes closed "a lot
   if not all" of quickplot's open plot-window issues. Most likely the
   blue-line-at-y=50 artifact on selected pages (open issue #5 in
   `project_motif_quickplot_status`) — textbook "parent's bg paints into
   descendant area" which is exactly what the new clipList composite-clip
   prevents. Re-verify and formally close next session.

**One architectural unlock:** Todd's "Athena widgets just *were* a
color" observation. Once stated, it became the lens for both fixes
(server owns bg paint on every visibility transition; widgets just
declare bg via CWBackPixel). Memorized as `reference_x11_server_owns_bg_paint`
so future "white where bg should be" bugs route to "find the missing
paint, not the wrong color."

## What landed (with file pointers)

### Bridge-layer visible-region clipping (the dthelpview-content fix)

- `Sources/SwiftXServerCore/DrawTarget.swift` — `.window` case now
  carries `id` alongside `topLevel`/`offsetX`/`offsetY` so the bridge
  can look up per-window clipList.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` —
  `windowClipLookup` closure (set by session, mirrors `pixmapBufferLookup`);
  `withDrawContext` for `.window` targets calls the lookup and sets
  `CGContext.clip` to the clipList rects BEFORE the GC user-clip, per
  X.org `mi/migc.c:miComputeCompositeClip`. New `withClip` overload
  takes both window- and GC-clip args. `clearArea` bridge signature
  changed from single-rect to `rects: [Rectangle]` (session does the
  intersection now).
- `Sources/SwiftXServerCore/ServerSession.swift` — `handleClearArea`
  intersects request rect with `entry.clipList`, passes surviving
  rects to bridge. `paintRectsForWindow` clips inner bg rect to the
  window's clipList. Session registers `windowClipLookup` on the
  bridge at init.
- `Sources/SwiftXServerCore/WindowBridge.swift` — protocol updates for
  new `clearArea` shape + `setWindowClipLookup`. MockWindowBridge
  default-impls updated.

### Paint-on-grow for descendant ConfigureWindow (the dthelpview-form fix)

- `Sources/SwiftXServerCore/ServerSession.swift` `handleConfigureWindow`
  — when descendant grows or moves, calls `paintRectsForWindow` on the
  descendant and emits via `paintWindowRects`, so its bg lands in its
  new visible region before the Expose. Mirrors the X server's
  contract per `reference_x11_server_owns_bg_paint`.
- `handleTopLevelResize` reordered: `recomputeClips` now runs BEFORE
  `mappedBackgroundPaints` (correctness no-op so the top-level's paint
  sees its fresh clipList).
- New `descendantBgPaints(of:byteOrder:)` helper — mirrors the 2026-05-19
  Expose cascade for the non-top-level MapWindow path so the dthelpview
  "children mapped before wrapper shell" pattern paints each descendant's
  bg as the subtree becomes viewable.

### GCState bg default (the xterm fix)

- `Sources/SwiftXServerCore/GCState.swift` — `background: UInt32 = 1`
  (was `0xFFFFFF`). Spec default per X11 protocol §7. The 0xFFFFFF
  sentinel was harmless until the 2026-05-19 ColorTable change pinned
  it to whitePixel.

### ChronoDumper value-list decoders (the tooling that made today fast)

- `Sources/SwiftXCaptureCore/ChronoDumper.swift` — three new inline
  decoders:
  - `decodeWindowAttrs(mask:values:)` for `CreateWindow` +
    `ChangeWindowAttributes` value-lists. Surfaces `bg-pixmap`,
    `bg-px`, `border-px`, `bit-grav`, `win-grav`, `override`,
    `save-under`. The smoking gun decoder — killed three wrong
    hypotheses for the DisplayArea bg in five minutes.
  - `decodeConfigureWindow(mask:values:)` for `ConfigureWindow`'s
    `x`/`y`/`w`/`h`/`bw`/`sibling`/`stack-mode` value-list.
  - `AllocColor` / `AllocNamedColor` reply pixel value formatting
    (`→ pixel=0x10 rgb=(...)`) so we never have to mentally count
    allocations to figure out what pixel `0x13` is.

### Docs / ledgers

- `SHORTCUTS.md` — three new Closed entries (clipping, paint-on-grow,
  GCState bg default). dthelpview cosmetic open entry rewritten —
  bg+aspect-ratio gaps separated; bg now closed, aspect-ratio remains.
  Two new Open entries: `subWindowMode=IncludeInferiors` untracked;
  border-ring rect not clipped to borderClip.
- New memory `reference_x11_server_owns_bg_paint.md` — the
  architectural principle behind both fixes. Linked from MEMORY.md.
- `project_motif_quickplot_status` — 2026-05-19 stamp noting today's
  fixes likely closed open issue #5 (and possibly #4); re-verify next
  session before formally closing.

### Tests

- New `DrawingDispatchTests.testClearAreaClippedByMappedChildren`
  locks in parent-ClearArea-clipped-by-children invariant. Existing
  `testClearAreaUsesWindowBackground` updated (post-fix, unmapped
  windows have empty clipList so the test now maps the window first).
- `CapturedAppReplayTests.testReplayDthelpview` baseline rebased to
  843 requests for the fresh `-manPage`-mode capture taken today
  (previous was 414 pre-`-manPage`; intermediate was 875 from an
  earlier capture).
- 542 total tests pass (294 server + 248 capture/framer), 4 skipped, 0 failures.

## What's still open (next session's queue)

1. **Verify quickplot fixes formally.** Open issues #4 (about-dialog
   animations) and #5 (blue-line-at-y=50 plot artifact) likely closed
   by today's clipping + paint-on-grow work, but unverified
   end-to-end. Should be the first thing — quick visual check on the
   live app, formally close the memory entries if confirmed.

2. **dthelpview aspect ratio wider than SS2.** Width comes out wider
   by ~80px. Likely font cell-width metric divergence
   (`manBox.columns=80` × cell width feeds the dialog's preferred
   width). Diff OpenFont/QueryFont calls between captures.

3. **Smoke other dt-apps and Motif clients post-clipping.** dtcalc,
   dtterm, dticon — quickplot got bonus fixes, others probably did too.
   Walk through each, note what's improved, what's still off.

4. **Motif button chrome on Expose / resize.** Still parked from
   2026-05-18. Today's button-bar buttons in dthelpview look thinner
   after resize than before — might be a related re-paint-on-grow
   gap, or might be the original parked issue. Worth re-checking with
   today's clipping in place.

5. **Framer-shared bug investigation.** Deferred again. Still open.

## Working tree at end of day

Two commits today on `main`:

- `ef0d6eb` — Honor X server bg-paint contract: clip draws + paint on
  grow + fix GC bg default (the big one — clipping + paint-on-grow +
  GCState + ChronoDumper value-list decoders + 1 new regression test)
- `44f30ea` — quickplot memory: note that bg-paint-contract fixes
  resolved plot-window artifacts

Six commits ahead of `origin/main` total.

## Reflection

Three lessons from the day worth keeping:

**Tooling pays back disproportionately when it surfaces "what's
actually on the wire?".** The `CreateWindow` value-list decode was 50
lines added to ChronoDumper and immediately killed three hours of
hypothesis-spinning. Yesterday's GC fg/bg decode did the same for the
dtcalc LCD bug. Pattern: when a draw-related bug class shows up,
spend 30 minutes adding the relevant decoder before going deeper —
the diagnosis time saved is huge. Added two more decoders proactively
today (ConfigureWindow value-list, AllocColor/AllocNamedColor reply
pixel) on the same theory. Stopping there per "add when we hit the
same bug shape twice."

**Capture-first / screenshot-diff-first beats speculation every
time.** I went down two wrong paths today (ParentRelative hypothesis;
"the remaining blue strips are correct-by-spec"). Both got killed by
data Todd produced — the swiftx capture for the first, the
SS2/swiftx side-by-side for the second. `feedback_wire_matches_gold`
keeps being right. When I can't explain a pixel, ask for a comparison
shot or a capture before guessing.

**One architectural lens can unify N seemingly-unrelated bugs.**
Todd's "Athena widgets just *were* a color" observation didn't just
explain dthelpview — it instantly told me where the xterm
white-text-bg bug had to be (broken GC bg default; not a paint path
issue). And it predicted quickplot's plot-window artifacts would
close as a side effect. The right lens is force-multiplying; the
memory entry preserves it for the next session that hits a
"wrong-color-where-bg-should-be" symptom.
