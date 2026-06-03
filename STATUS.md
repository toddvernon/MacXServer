# Status 2026-06-03 (end of day)

The big lift: device-coord internal regions landed. Every `clipList`,
`borderClip`, `boundingShape`, `clipShape`, and every `BoxRec` / `Region`
inside the server now runs at device-pixel granularity. The X-protocol
is a pure I/O format — logical pixels in on the wire, conversion at the
boundary, device pixels everywhere internally. This matches R6's
architecture at our display's native resolution; R6's clip is
pixel-precise on the screen framebuffer, ours is pixel-precise on the
retina backing.

The 2026-06-02 session's whole pile of compensating patches for the
dual-representation seam is deleted. Net delta for the refactor: +~700
lines of new device-coord plumbing, -~700 lines of dual-rep patches.

`DEVICE_COORDS_REFACTOR.md` has the design.

## Commits landed today (8)

- `47bc72a` — `DEVICE_COORDS_REFACTOR.md` plan doc.
- `05814ba` — Session WIP capture: yesterday's dual-representation
  patches as one commit so the journey survives in git history. Slated
  for phase 6 deletion (and gone, see `ee14017`).
- `f7af1e5` — Phase 1: `BoxRec.scaledToDevice` / `scaledToLogical` /
  same on `Region`; `ServerConfig.deviceScale` accessor. 8 new
  `RegionExtrasTests`. Conservative ceil/floor on the device→logical
  reverse so `ShapeGetRectangles` includes every logical pixel with any
  device coverage.
- `568d89b` — Phase 2+3: `ClipListEngine` and `ShapeExtension` to
  device coords. `recomputeClips(forTopLevel:in:scale:)` multiplies
  window box dims by scale internally; output `clipList`/`borderClip`
  are device-coord. `ShapeRectangles` / `ShapeMask` / `ShapeOffset`
  scale rects/offsets at the protocol boundary; `bitmapToRegion` reads
  device pixels via `readDepth1MaskDevicePixels`;
  `ShapeGetRectangles` / `ShapeQueryExtents` / `ShapeNotify` reply
  scale device→logical. `combineShape`'s `xOff/yOff` widened
  `Int16 → Int32` to keep room at device scale. `ServerConfig.default`
  flipped to `.scaleOne` so unit tests keep tight assertions; the live
  `macxserver` path builds its own `ServerConfig` with the picked
  retina display.
- `ee4cceb` — Phase 4: `withClip` builds the window-clip CG clip path
  under a temporary identity CTM so device-coord rects land at exact
  device pixels; concat back to scaled CTM for the drawing body so
  handlers continue to write at logical X coords. `paintWindowRects`
  same treatment. GC clip rectangles stay at logical drawable-local
  (matches X11's logical-pixel-granularity spec for
  `SetClipRectangles`).
- `fbea93f` — Mid-day STATUS roll (the hook fired).
- `14d2131` — Phase 5: drawing-handler unit-sweep. Every site that
  mixes `dx/dy` from `topLevelAndOffset` (logical Int16) with
  `clipList`/`borderClip` (device-coord) now scales properly.
  `exposeRectsForWindow` and the move-cascade Expose path scale
  device→logical for the wire payload via the conservative
  `scaledToLogical`. `handleClearArea`'s reqBox built at device.
  `CocoaWindowBridge.clearArea` fills under identity CTM.
- `ee14017` — Phase 6: deleted the 2026-06-02 dual-representation
  patches. ~700 lines removed: `boundingShapeDeviceRects` /
  `clipShapeDeviceRects` fields + setters; `paintShapedDescendantBg`
  bridge method; `ShapedDescendantPaint` struct;
  `paintsForShapedDescendantChange` + `mappedShapedDescendantPaints`
  helpers; `windowDeviceClipLookup` register/unregister/lookup;
  Configure-time device-rects invalidate block; move-cascade skip for
  shaped descendants; `bitmapToDeviceRects` helper; `windowUsesDeviceShapePaint`
  predicate; `FlippedXView`'s `boundingShapeDeviceRects` field + the
  dual clip-path build (now treats `boundingShapeRects` as device,
  divides by backingScale).

`setWindowShape`'s descendant branch reduced to ~30 lines: paint
parent's bg under the child's borderBox (device-coord intersect with
parent's clipList), `paintRectsForWindow` for the child's own
bg/border, Expose with device→logical conversion. No special shape
paint, no dual representation, no transient invalidation dance — the
curve lands at exact device pixels through the same code path every
descendant paint uses.

All 1262 tests green at each phase boundary.

## What's still pending

- **Live retina rendering check.** Test suite confirms the algebra at
  `scale=1`. The retina visual win comes from running the real
  `macxserver` (`ServerConfig` from `DisplayConfig.studioDisplay`,
  scale=3) and pointing xcalc at it. Should land smooth stadium
  buttons that survive press and resize, and the LCD's grey-border-with-
  rounded-corners rendering — without any of the artifacts we were
  chasing 2026-06-02. Todd to validate on the Sun box.
- **Capture replay validation.** Run
  `/tmp/swift-x-captures/2026-06-02T12-45-57-xcalc.xtap` (or later) as
  a sanity check that the wire decodes match the before-state.

## What's broken / known-not-done

- **Test coverage at `scale=3` is thin.** Every test runs at `scale=1`
  via `ServerConfig.default`. The device-coord conversions are
  exercised but the math difference doesn't bite. Worth adding a few
  scale=3 tests as a follow-up to make sure no per-coordinate site got
  missed.
- **`scaledToLogical` for an empty box.** A device box that scales to
  an empty logical box (rare — happens when a sub-pixel rect spans
  zero logical pixels in some axis) is filtered out by
  `Region.rects(_:order:)` which filters empty inputs. Probably fine
  but worth a property-based test.

## Carrying forward

- AllocColor pixel-value drift on cross-session replay (still parked).
- xmmap blit-on-move (Step F).
- The Preferences Display Size radio (Auto / Comfortable / Compact)
  shipped 2026-06-02 still wants live Sun-box validation. Same toggle,
  unchanged by this refactor.

## A note on the journey

2026-06-02 was a full day of patching the dual-representation seam
between logical SHAPE regions and device-resolution rect-band sidecars.
Each fix was correct in isolation and introduced a new "two coordinate
systems out of sync" bug. The lesson: when you find yourself patching a
seam between two representations of the same thing, the right fix is
usually one representation, not a better patch.

Phase 6 today deleted every one of those 2026-06-02 patches in one
commit. The refactor is bigger work but the resulting code is smaller,
clearer, and (the math says) pixel-precise.
