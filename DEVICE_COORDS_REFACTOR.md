# Device-coord internal regions

Started 2026-06-02. The mission: match R6 architecture at our display's native resolution. All internal clipping and region operations run at device pixels. The X-protocol layer becomes purely an I/O format.

## Motivation

R6's `mi` layer (`miregion`, `miComputeClips`, etc.) stores rectangle bands at screen-pixel granularity. Drawing is clipped against window regions at screen-pixel granularity. The framebuffer is rasterized at screen-pixel granularity. The reason R6's shaped buttons look right is that there's exactly one coordinate system — the screen pixel — and the SHAPE region intersected against `clipList` is an exact-pixel clip on the destination.

We diverged. We store regions at *X-protocol logical pixel* granularity (1280×900-ish at scale=3 on a Studio Display) but render the backing buffer at *device pixel* granularity (3840×2700). The CG context's CTM bridges between them. That CTM is the seam where everything keeps breaking:

- A region rect at logical `(x, y, w, h)` becomes a 3-device-pixel-aligned band when CG rasterizes the clip path. Curves staircase at 3-device-pixel steps. That's the original quality complaint.
- Sub-pixel device rect coords (`Double(r.x) / scale`) introduced as a "fix" land at inconsistent device pixels through FP precision. That's the C-shape and ragged-edge bugs.
- Two parallel representations (logical region for protocol + device rect bands for paint) need atomic updates that we keep getting wrong. That's most of the patches I added in the 2026-06-02 session.

R6 doesn't have any of this because they're 1:1. We need the same internal model at our display's native resolution.

## Principles

1. **`WindowEntry` keeps protocol-stored values** (`x`, `y`, `width`, `height`, `borderWidth`) at logical pixels. Those are the values the wire format gives and takes — `CreateWindow`, `ConfigureNotify`, `GetGeometry` round-trip them verbatim. We do not change protocol semantics here.

2. **Every internal derived state runs at device pixels.** `clipList`, `borderClip`, `boundingShape`, `clipShape`, every `BoxRec`, every `Region`. The semantic unit becomes "1 device pixel" instead of "1 X-protocol pixel". The storage type (`BoxRec` with `Int32` fields, `Region` as y-x banded rects) is unchanged; only the meaning of the values shifts.

3. **Conversion happens at exactly two boundaries.** Logical → device when a client request enters the internal logic; device → logical when a reply or event goes back on the wire. No mid-pipeline conversions, no parallel logical copies.

4. **The CG context CTM stays scaled.** Drawing handlers continue to take logical X coords and the CTM converts them to device pixels exactly as today — that's a clean abstraction for things like `PolyText8` that benefit from CG's sub-pixel positioning. The change is in clip paths only: clip rects are built under a temporary identity CTM so they land at exact device pixels, while the drawing body inside the clip scope uses the original scaled CTM.

## Conversion model

Helper symbols added in phase 1:

```swift
extension Region {
    func scaledToDevice(by s: Int32) -> Region          // multiply each box by s
    func scaledToLogical(by s: Int32) -> Region         // floor x1/y1, ceil x2/y2; conservative
}
extension BoxRec {
    func scaledToDevice(by s: Int32) -> BoxRec
    func scaledToLogical(by s: Int32) -> BoxRec
}
extension ServerSession {
    var deviceScale: Int32 { Int32(config.displayConfig.scale.rounded()) }
}
extension WindowEntry {
    func deviceInteriorBox(at baseDx: Int32, baseDy: Int32, scale: Int32) -> BoxRec
    func deviceBorderBox(at baseDx: Int32, baseDy: Int32, scale: Int32) -> BoxRec
}
```

`scaledToLogical` uses floor on `x1`/`y1` and ceil on `x2`/`y2` — represents "every logical pixel that has any device-pixel coverage," which is the conservative reading for `ShapeGetRectangles` clients. They get a slightly bigger logical region than the device truth in the worst case, which is harmless because they don't draw outside it anyway.

## Phase plan

### Phase 1 — Helpers

Add the scale/conversion helpers above. No semantic changes. Tests stay green by construction.

### Phase 2 — `ClipListEngine`

`recomputeClips(forTopLevel:)` computes `topBorderBox` in device coords (multiply `entry.borderWidth/width/height` by scale). `recomputeSubtree`'s `baseDx`/`baseDy` parameters carry device-coord offsets; `entry.borderWidth/width/height` are multiplied by scale at the local box construction. `entry.boundingShape`/`entry.clipShape` are now device-coord regions, so their `.translated(dx: baseDx, dy: baseDy)` works as-is.

Output: `clipList` and `borderClip` are device-coord regions in top-level-device-local coordinates.

Tests in `ClipListPopulationTests.swift` get rect assertions multiplied by `scale` (or use `scale=1` to avoid the multiply — most test configs already do).

### Phase 3 — `ShapeExtension`

- `ShapeRectangles` request handler scales each input rect to device before building the region (`Region.rects(boxes, order: ...)` from already-device boxes).
- `ShapeMask` request handler: `bitmapToRegion` reads at device resolution (already does via `readDepth1MaskDevicePixels` — we just retire the parallel logical reader and the `bitmapToDeviceRects` sidecar function).
- `ShapeCombine`/`ShapeOffset` operate on device-coord regions; `xOff/yOff` are scaled to device on entry.
- `ShapeGetRectangles` reply scales each output box back to logical with the `scaledToLogical` convention.
- `ShapeQueryExtents` reply scales the extent.

The `boundingShapeDeviceRects` and `clipShapeDeviceRects` sidecar fields on `WindowEntry` go away (subsumed into `boundingShape`/`clipShape`).

Tests in `ShapeExtensionTests` and `ShapeOnDescendantTests` get device-coord expected values, or default to `scale=1`.

### Phase 4 — Bridge

`CocoaWindowBridge.withClip` accepts `windowClip` as device-coord rects. Inside the body it:

1. `ctx.saveGState()`
2. Save current CTM
3. `ctx.concatCTM(currentCTM.inverted())` — sets CTM to identity for the path build
4. Build the CG clip path from device-coord `CGRect`s
5. `ctx.clip()`
6. Restore CTM to the original (scaled) CTM
7. Run the drawing body
8. `ctx.restoreGState()`

`paintWindowRects` similarly fills device-coord rects under identity-CTM, restoring for any subsequent draws (none here, but the pattern is consistent).

GC clip rectangles (from `SetClipRectangles`, applied per-op alongside the window clip) are scaled to device by the session before passing into the bridge.

Bridge protocol: signatures unchanged structurally; doc comments updated to declare the rects' coordinate space as device pixels.

### Phase 5 — Drawing handlers

Each draw op handler in `ServerSession.swift` converts incoming GC clip rectangles to device coords before passing to the bridge. Window/pixmap target identification is unchanged. Coordinate math like `target.windowOffset` becomes device-coord (computed from the entry's logical fields × scale).

The drawing body inside `withDrawContext` continues to write at logical X coords through the bridge — the CTM scaling delivers those to device pixels correctly. Only the clip layer is device-resolution now.

### Phase 6 — Cleanup

Remove the session-of-patches that were compensating for the dual representation:

- `boundingShapeDeviceRects` / `clipShapeDeviceRects` fields on `WindowEntry` + their setters
- `windowDeviceClipLookup` register / unregister / lookup body in `CocoaWindowBridge` and `WindowBridge` protocol + the closure registered by `ServerSession`
- `paintShapedDescendantBg` bridge method (subsumed by `paintWindowRects` since `borderClip`/`clipList` are now device-coord)
- `ShapedDescendantPaint` struct
- `paintsForShapedDescendantChange` helper
- `mappedShapedDescendantPaints` helper
- Configure-time device-rects invalidation block in `handleConfigureWindow`
- Move-cascade skip block for shaped descendants
- `bitmapToDeviceRects` helper in `ShapeExtension`
- `ShapedDescendantPaint` related test code

The `setWindowShape` descendant branch reduces to: emit Expose on the changed window (already there); `paintsForShapedDescendantChange` is replaced with a direct call to `paintRectsForWindow(entry: child, ...)` because that now emits device-coord rects through the now-device `borderClip`/`clipList`.

### Phase 7 — Tests + status

Sweep `Tests/SwiftXServerCoreTests/Region/*Tests.swift` and any region-asserting tests in the other suites for hardcoded logical-coord expectations. Two options per test:

1. **Multiply expected values by `scale`** when the test pins a value derived from a window's protocol coord (`width=200` → expected clipList rect at device coords).
2. **Use `scale=1`** when the test is checking region algebra and doesn't care about scale (lots of `RegionAlgebraTests` qualify).

Roll `STATUS.md` with what landed. Update `OPCODE_STATUS.md` entries for SHAPE opcodes (renew their notes for the new architecture).

## Non-goals

- `WindowEntry.x/y/width/height/borderWidth` stay logical (protocol wire format).
- `GetGeometry`, `QueryTree`, `ConfigureNotify` etc. stay logical (protocol wire format).
- Drawing handler coordinate inputs stay logical (drawing CTM continues to convert to device pixels).
- Per-descendant `NSView` / `CALayer` hierarchy. The mission-critical fix is unifying the coordinate system, not rebuilding the rendering substrate.

## Decision log

- 2026-06-02: Per CLAUDE.md ("speculative refactors OK"), proceeding with this architectural change against Todd's explicit ask for "the most structural solution that matches MIT." This entry in `DECISIONS.md` lands when phase 7 completes.

## Risk + open questions

- **Tests:** the bulk of the work after the substantive refactor is updating regions-asserting tests. Expect ~50-100 test value updates.
- **GC clip rectangles:** users (`SetClipRectangles`) pass rects at logical drawable-local coords. The session translates them via `clipXOrigin/clipYOrigin` (`GCState.materialise`). The translation stays logical; scale to device happens once at the bridge boundary.
- **Pixmap pixel storage:** `PixelBuffer` already allocates at device scale. No change. `readDrawablePixels` still has a logical view that some callers use; we keep it but the SHAPE bitmap reader switches to the device-resolution variant.
- **Window-local SHAPE region translation:** `boundingShape`/`clipShape` are stored in window-local device coords. `ClipListEngine` translates by `baseDx`/`baseDy` (now device-coord) before intersecting. Works without change.
- **Identity-CTM clip path build:** the standard CG pattern. The only risk is if any draw op relies on cumulative CTM state outside the clip scope, which they don't.

## Done condition

- All 1256+ tests green.
- xcalc replay capture matches a clean trace.
- Live xcalc on the Sun box renders smooth stadium buttons that survive press and resize without artifacts.
- `STATUS.md` updated, `DECISIONS.md` entry added.
- The 6 patches that grew this session (listed in Phase 6) are deleted.
