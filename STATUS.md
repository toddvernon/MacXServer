# Status 2026-06-03 (mid-day snapshot)

Mid-flight on a structural refactor: moving every internal region in the
server (`clipList`, `borderClip`, `boundingShape`, `clipShape`) from
X-protocol logical pixels to device pixels, so curve-shape rendering on
Retina lands at exact device pixels instead of staircasing at 3× steps
or threading through a parallel dual-representation. Design doc:
`DEVICE_COORDS_REFACTOR.md`. We aren't done yet — phases 5-7 still to land
later today.

The big-picture reason for the refactor: 2026-06-02 spent the whole day
adding side-car `boundingShapeDeviceRects` / `clipShapeDeviceRects`
fields, a `paintShapedDescendantBg` bridge path, a `windowDeviceClipLookup`
draw-time clip, and other patches to chase smooth xcalc buttons. Every
one of those patches kept introducing "two coordinate systems out of
sync" bugs (resize C-shape, press border erasure, ragged curves). Todd's
call: "the most structural solution that matches MIT (the gold) and
fulfills our mission of the BEST looking server for classic X apps on a
Retina Mac." So we're going to R6's architecture, at our display's
native resolution: one internal coordinate system (device pixels), the
X-protocol is just an I/O format. Phase 6 will delete every one of those
2026-06-02 patches as dead weight.

## Landed today (5 commits)

- `47bc72a` — `DEVICE_COORDS_REFACTOR.md` plan doc.
- `05814ba` — Session WIP capture: all the 2026-06-02 dual-representation
  patches as a single commit so the journey is in git history. Slated
  for deletion in phase 6.
- `f7af1e5` — Phase 1: `BoxRec.scaledToDevice` / `scaledToLogical` and
  the same on `Region`; `ServerConfig.deviceScale` accessor. 8 new
  `RegionExtrasTests`. Conservative ceil/floor on the device-to-logical
  reverse so `ShapeGetRectangles` includes every logical pixel that has
  any device-pixel coverage.
- `568d89b` — Phase 2+3: `ClipListEngine.recomputeClips` gains a
  `scale:` parameter; box construction multiplies window dimensions and
  child offsets by scale. `ShapeExtension` converts rects/offsets at the
  protocol boundary; `bitmapToRegion` now reads device pixels directly;
  `ShapeGetRectangles` / `ShapeQueryExtents` / `ShapeNotify` reply scale
  back to logical. `defaultBoundingRegion` / `defaultClipRegion` return
  device-coord boxes. `combineShape`'s xOff/yOff widened Int16→Int32.
  `ServerConfig.default` flipped to scale=1 (was `studioDisplay`'s
  scale=3) so unit tests keep their tight assertions; the live
  `macxserver` path builds its own `ServerConfig` with the picked
  retina display.
- `ee4cceb` — Phase 4: `withClip` applies window-clip rects at identity
  CTM so the device-coord coordinates are interpreted as exact device
  pixels. `paintWindowRects` same treatment. GC clip rectangles
  (`SetClipRectangles`) stay logical and go through the scaled CTM —
  matches X11's spec semantics for that opcode.

All 1263 tests green at every phase boundary.

## What's broken / partly done

- **Phase 5 not finished.** Auditing every consumer of
  `entry.clipList.rects` / `entry.borderClip.rects` for the device-coord
  switch. Found one bug already: `exposeRectsForWindow`
  (`ServerSession.swift:2266`) subtracts `dx, dy` from clipList rects.
  `dx`/`dy` come from `topLevelAndOffset` which still returns
  logical-coord Int16 offsets; subtracting them from now-device-coord
  rects is a unit-mismatch. Two options: scale at the call site, or
  return device-coord from `topLevelAndOffset` (invasive — many
  handlers use it for draw-position translation, those should stay
  logical because the CTM scales them). Going with scale-at-callsite.
  Other suspect call sites: `paintRectsForWindow` (emits paint rects
  from `borderClip` / `clipList`) — these are now device-coord which
  is what `paintWindowRects` expects post-phase-4. Should be fine but
  worth a read-through.
- **Phase 6: dead-code deletion** of the 2026-06-02 dual-representation
  patches. Big PR. The fields and methods to delete:
  `boundingShapeDeviceRects` / `clipShapeDeviceRects` on `WindowEntry` +
  setters; `paintShapedDescendantBg` bridge method;
  `windowDeviceClipLookup` register/unregister/lookup;
  `ShapedDescendantPaint` struct; `paintsForShapedDescendantChange` +
  `mappedShapedDescendantPaints` helpers; Configure-time device-rects
  invalidation block; move-cascade skip block for shaped descendants;
  `bitmapToDeviceRects`. The `setWindowShape` descendant branch reduces
  to "emit Expose; call paintRectsForWindow" because that now produces
  device-coord rects from the device-coord `borderClip` + `clipList`.
- **Phase 7: capture replay + STATUS roll.** Run the latest xcalc
  capture in `/tmp/swift-x-captures/2026-06-02T17-07-49-xcalc.xtap`
  against a fresh server to see the visible win. Live xcalc on the Sun
  box for press + resize validation.

## Test scale config

`ServerConfig.default` is now scale=1 so unit tests don't have to
multiply through. `macxserver` builds its own `ServerConfig` from
`DisplayConfig.forMainDisplay(...)` (scale=3 on Studio Display etc.) —
unaffected by the default flip. Live behavior is the same as before;
the change is the unit-test convenience.

## What to do next session if I don't finish today

Pick up at phase 5: read every `clipList.rects` / `borderClip.rects` /
`topLevelAndOffset` interaction in `ServerSession.swift` and verify
units. Then phase 6 dead-code deletion is a mechanical sweep —
delete-by-symbol-name — followed by a test pass. Phase 7 is the
victory-lap capture replay.

## Carrying forward

Same orthogonal threads as 2026-06-01/02:
- AllocColor pixel-value drift on cross-session replay.
- xmmap blit-on-move (Step F).
- Sun-box validation pass for `--scale 2` (the scale-picker Preferences
  UI from 2026-06-02 morning).
