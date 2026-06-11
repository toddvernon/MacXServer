# Region engine port plan

Status: planning, 2026-05-25. Goal: faithfully port MIT X11R6's region
math + window cascade to Swift, replace our hand-rolled equivalents,
and use it as a stable foundation for resize/move/uncover correctness.

## Source files to port

### `reference/X11R6/xc/programs/Xserver/mi/miregion.c` (~2420 lines)

The region engine. Self-contained — no X server dependencies beyond
its own types. Estimated ~1500 lines of Swift.

Functions to port:

| C function | Purpose |
|------------|---------|
| `miRegionCreate(rect, size)` | Construct a region containing one rect with initial capacity |
| `miRegionInit(pReg, rect, size)` | Init existing region |
| `miRegionDestroy` / `miRegionUninit` | Free / clear |
| `miRegionCopy(dst, src)` | Deep copy |
| `miIntersect(newReg, reg1, reg2)` | A ∩ B |
| `miUnion(newReg, reg1, reg2)` | A ∪ B |
| `miSubtract(regD, regM, regS)` | A − B |
| `miInverse(newReg, reg1, invRect)` | invRect − reg1 |
| `miTranslateRegion(pReg, x, y)` | Shift by (dx, dy) |
| `miRectIn(region, prect)` | Containment test |
| `miPointInRegion(pReg, x, y, box)` | Hit-test |
| `miRegionsEqual(reg1, reg2)` | Structural equality |
| `miRegionNotEmpty(pReg)` / `miRegionEmpty(pReg)` | Cheap empty checks |
| `miRegionExtents(pReg)` | Bounding box |
| `miRegionValidate(badreg, pOverlap)` | Normalize after construction |
| `miRectsToRegion(nrects, prect, ctype)` | Build region from rect array |
| `miRegionReset(pReg, pBox)` | Reset to one-rect region |
| `miRegionAppend(dstrgn, rgn)` | Append (used internally) |

Internal helpers (also need porting):
- `miCoalesce`, `miAppendNonO`, `miRegionOp` — the heart of the band-arithmetic algorithms
- `miSetExtents` — recompute bounding box

### `reference/X11R6/xc/programs/Xserver/mi/miwindow.c` (~1145 lines, port ~400-600)

Selective port of the resize/move cascade. Skip the save-under and
backing-store entries.

| C function | Purpose |
|------------|---------|
| `miSlideAndSizeWindow(pWin, x, y, w, h, pSib)` | The main cascade. Move + resize + gravity preservation + expose computation. |
| `miMoveWindow(pWin, x, y, pNextSib, kind)` | Pure-move variant |
| `miMarkOverlappedWindows(pWin, pFirst, ppLayerWin)` | Identify which windows need recompute |
| `miHandleValidateExposures(pWin)` | Walk subtree emitting Expose for each window's accumulated exposed region |

Skip:
- `miClearToBackground` — already in our `handleClearArea`
- `miCheckSubSaveUnder` / `miChangeSaveUnder` / `miPostChangeSaveUnder` — we don't do save-under
- `miSetShape` — XShape extension; we don't ship it
- `miChangeBorderWidth` — separate path; handle later if needed
- `miMarkUnrealizedWindow` — destroy/unmap; existing path handles it

### `reference/X11R6/xc/programs/Xserver/mi/miexpose.c` (selective, ~200 lines)

| C function | Purpose |
|------------|---------|
| `miWindowExposures(pWin, prgn, other_exposed)` | Emit Expose for the given region of the window |
| `miPaintWindow(pWin, prgn, what)` | Paint bg over the given region |
| `miSendExposures(pWin, pRgn, dx, dy)` | Emit Expose events on the wire |

Skip:
- `miHandleExposures` — GraphicsExpose for CopyArea, our existing path handles
- `miClearDrawable` — pixmap clear, separate

## What we DON'T port

- `mibstore.c` (backing store) — explicitly excluded per DECISIONS 2026-05-14
- `mibitblt.c` (CopyArea/CopyPlane implementation) — we have our own
- `cfb*` (color frame buffer DDX) — we have CGContext
- Server scaffolding: `ScreenPtr`, `DrawablePtr`, `WindowPtr`, `ProcVector`,
  `Dispatch` — different architecture; use our existing `WindowEntry` etc.
- Atom dispatch, GC validation, font dispatch — different concerns

## Adapter shim

A small bridge between MIT's data structures and ours:

- `MIWindowRec` wrapper around our `WindowEntry`: provides `parent`,
  `firstChild`/`nextSib`, `clipList`/`borderClip`, `winSize`, `bitGravity`,
  `winGravity`, `borderWidth`, `mapped`/`realized`, `valdata` slot for
  per-resize transient state.
- `MIScreen` wrapper: provides the `CopyWindow` callback that maps to
  our bridge, `WindowExposures` callback that emits to `OutboundQueue`,
  `PaintWindow` callback for bg-paint, etc.
- Region/clipList integration: WindowEntry's `clipList: Region` becomes
  the MIRegion-backed type.

Estimated shim: ~200-400 lines.

## Phasing / commit plan

### Phase 1: port miregion only
- Add new `MIRegion` Swift type alongside existing `Region`/`RegionOp`
- Tests against MIT-known edge cases (empty, multi-band, complex overlap,
  translate-then-intersect, contains-multiple, etc.)
- Existing region tests in our codebase to compare against MIRegion
- Land as `Sources/SwiftXServerCore/Region/MIRegion.swift` (single file
  initially; can split later if it grows)

### Phase 2: replace Region/RegionOp internal call sites with MIRegion
- Swap `recomputeClips`, `paintRectsForWindow`, `exposeRectsForWindow`,
  `repaintParentOverUncovered` to use MIRegion
- Existing server tests still pass
- Delete `Region/Region.swift` + `Region/RegionOp.swift`

### Phase 3: port miSlideAndSizeWindow + miMoveWindow
- Add new `MIWindowResize.swift` containing the ported cascade
- The shim around WindowEntry to provide WindowRec-equivalent access
- Initially called as a SHADOW path: run alongside existing
  handleConfigureWindow logic and assert outputs match. Or just diff
  output regions in tests.

### Phase 4: cut over
- Replace handleTopLevelResize cascade with miSlideAndSizeWindow call
- Replace handleConfigureWindow's repaintParentOverUncovered +
  paintRectsForWindow + Expose cascade with miSlideAndSizeWindow/
  miMoveWindow call
- Strip `mappedBackgroundPaints` (the one we just stripped already)
- Strip `repaintParentOverUncovered` (now subsumed by miSlideAndSize)
- Strip `mappedDescendantSnapshots` Expose cascade (handled by
  miWindowExposures)

### Phase 5: test broadly
- Walk the app matrix: xcalc, xterm, dtcalc, dtterm, dthelpview, dtpad,
  quickplot × {resize-grow, resize-shrink, modal-dialog}
- The "small gray rectangles" class should be closed (ancestor cascade
  handles it for free)
- Wire-latency redraws should be unchanged
- xcalc CWBorderPixel ring should still draw (miSlideAndSize includes
  it via miPaintWindow)

### Phase 6: bit-blit experiments
After cascade lands and verifies, try optional optimizations:
- Honor `bit_gravity` (descendant bit preservation per-window)
- Possibly save-under for popup menus (NSWindow-level, transient)
- Strategic re-add of any specific optimization that proves to add
  value once we have a correct foundation

## Estimated effort

- Phase 1 (miregion port): full day. Big file, mechanical, lots to test.
- Phase 2 (cut over to MIRegion): half day. Mostly compiler-driven.
- Phase 3 (miSlideAndSizeWindow port): full day.
- Phase 4 (cut over cascade): half day with tests.
- Phase 5 (broad app test): half day + iteration.
- Phase 6 (experiments): open-ended, only when motivated.

Total focused work: 2-3 days. Could be faster if Phase 1 is delegated
to an agent for mechanical translation (faithful function-for-function
port, no reinterpretation).

## Risk

Translation errors in the port (off-by-one in band arithmetic,
sort-order assumption flipped, etc.). Mitigation: extensive unit tests
against MIT-known inputs/outputs. The C code's comments are very good
about invariants — preserve those as Swift comments verbatim.

The other risk is the shim — adapting MIT's WindowRec-pointer-based
data flow to our value-typed WindowEntry. Probably want to keep MIT's
shape (use reference types and pointers internally) and only translate
at the API boundary.

## Caveat

Reverting our recent strip would mask whether the port is doing its
job. Skip the revert — work against the current (slightly cosmetic-
regressed) state. The visible regressions are then a forcing function:
when the port works, they'll close.
