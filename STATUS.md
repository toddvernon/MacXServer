# Status 2026-06-03 (end of day)

The xcalc resize "wonky intermediate state" turned out to be a
two-day-old paint-region bug in `paintRectsForWindow`, not a dispatch
coalescing problem. The fix is two lines; the path to finding it
detoured through almost the entire DISPATCH_COALESCING_REFACTOR.

## What landed

`99c957c` -- paint PW_BORDER over `(borderClip - winSize)`, matches R6
mi/dix `dix/window.c:1403`. winSize = `clipShape ∩ interiorBox` when a
clipShape is set, otherwise interiorBox. The earlier 2026-06-02 fix
that narrowed border paint to `entry.borderClip.rects` was the right
direction but didn't go far enough -- it still painted border across
the children's areas for a top-level with children, and the bg paint
(over `clipList`, which has children's borderClips subtracted) never
reached those children's areas to overpaint. Result: every time the
xcalc top-level was painted on resize, all 40 child buttons went solid
black with the top-level's borderPixel (= 0x1 = black) until each
button's own paintRectsForWindow repainted it left-to-right
top-to-bottom.

Same commit also includes the shape-aware winSize, because the first
pass used `interiorBox` (the rect) for winSize, which left the
top/bottom of the stadium border un-painted on shaped buttons --
visible as `( label )` ghost outlines. Athena Command sets both
bounding and clip shape; using `clipShape ∩ interiorBox` makes the
border ring trace the stadium curve all the way around.

Validated end-to-end on the Sun: cadence and final pixels match
Sun-on-Sun visually.

Archived `DISPATCH_COALESCING_REFACTOR.md`. Phase 1 (accumulator
plumbing, `a4ff45f`) stays on main -- it's functionally a no-op with
per-call flush in place. Phases 2-5 aren't pursued. Today's
investigation showed our redraw cadence already matches Sun's once the
paint regions are right; the bottleneck was visible-pixel correctness,
not dispatch count.

## Test update

`testBorderRingPaintsClippedToBorderClip` had been asserting the
2026-06-02 behavior (border paints sum to borderClip area). The
assertion is now `< borderClipArea` plus a specific value for the
ring area (40px² for the test geometry, two 20×1 strips above and
below the interior). Updated and passing in the 1262-test sweep.

## Carrying forward

- AllocColor pixel-value drift on cross-session replay (still parked).
- xmmap blit-on-move (Step F).
- The Preferences Display Size radio (Auto / Comfortable / Compact)
  shipped 2026-06-02 -- still wants live Sun-box validation. Today's
  paint fix doesn't touch it.
- Resize-time delta cascade and ShapeMask flow: the chain still works
  correctly but the journey today exposed how interleaved
  `(ConfigureWindow, ShapeMask Bounding, ShapeMask Clip)` cascades
  are. Worth re-reading the cascade logic next time we touch shaped
  widgets -- it's load-bearing and subtle.

## What today's investigation cost

About a session of deep digging into the wrong layer (dispatch
coalescing, deferred-op accumulator semantics, end-of-batch vs
per-call flush) before the user's "watch sun-on-sun, the BG isn't
black" observation refocused the search on the actual bug. The Phase
2 work was speculative-but-buildable; the fact that it shipped and
"worked" without immediately revealing this bug is what kept us in
the wrong layer for so long. Lesson archived: validate against the
gold standard (Sun-on-Sun) BEFORE building optimization layers on top
of an assumed-correct paint stage.
