# Risk register: Drawing + GCs

Three buckets. Each entry calls out severity, missing piece, the trigger that
would expose it, and the shape of the fix. Evidence is by `file:line`.

## Bucket 1 — Actively bleeding now (named client)

### 1.1 PolyArc sweep direction is visually reversed
**Severity:** high (cosmetic) for xclock; high (functional) for any client that
relies on direction-sensitive arc rendering. **Missing:** the arc-path builder
uses ordinary `sin`/`cos` of the angle into a context whose CTM has been flipped
on Y (`FlippedXView` does `scaleBy(1, -1)` at line 309 of `FlippedXView.swift`).
The math doesn't compensate. X spec is explicit: "positive indicating
counterclockwise motion." With our Y-flip, a positive `angle2` traces visually
clockwise. **Evidence:**
`Sources/SwiftXServerCore/CocoaWindowBridge.swift:1333-1357` `ellipseArcPath`
computes `cy + ry * sin(start)` which under the flipped CTM points the +sin
direction visually down. Verified by reading the comment block in
`FlippedXView.swift:288-310` confirming the CTM flip is in effect for all
drawing calls. **Trigger:** xclock minute/second hand sweep direction; any clock
or gauge UI. Probably reads as "the second hand goes backwards" or "the pie
chart is mirrored about the horizontal axis." **Fix shape:** negate `angle1` and
`angle2` (or equivalently negate the `sin` term) inside `ellipseArcPath`, with a
unit test driven off a fixture arc that draws a 0..90° wedge and checks which
quadrant it lands in.

### 1.2 PolyPoint is a flat BadRequest
**Severity:** high — pure spec gap. **Missing:** opcode 64 is not in the
Framer's `Request` enum, has no handler, has no bridge call. Anything sending
PolyPoint gets BadRequest. **Evidence:** `grep -rn "PolyPoint"
Sources/Framer/Requests/` returns only the opcode-name string. `grep -n
"polyPoint" Sources/SwiftXServerCore/ServerSession.swift` returns no handler.
Falls through `case .unknown(let op, _):` at `ServerSession.swift:3918` and
emits BadRequest via `emitError(.request, ...)`. **Trigger:** any client drawing
scatter points or single-pixel updates — `xeyes` pupils sometimes, scientific
plot apps, anything in `quickplot`'s plotting paths (Todd's named test app).
**Fix shape:** add `Framer/Requests/PolyPoint.swift` mirroring PolyLine
structure, wire `case .polyPoint(let r): handlePolyPoint(r, ...)` and a
`bridge.drawPolyPoints(...)` that does a 1x1 fill per point (CG can do them as a
batched path of zero-width strokes or as a sequence of 1px rects).

### 1.3 Drawing into pixmaps silently dropped
**Severity:** high — broken feature, masked by a fake-success path. **Missing:**
`validateDrawTarget` returns nil for any drawable that isn't a top-level window,
logs, and the handler bails without erroring. CDE dt-apps build per-button
chrome in offscreen pixmaps then `CopyArea` them to a window. That entire path
renders nothing because every draw into the pixmap is a no-op. **Evidence:**
`Sources/SwiftXServerCore/ServerSession.swift:1624-1634` `validateDrawTarget` —
`if let target = topLevelAndOffset(for: drawable) { return target }
log?.log("…known (pixmap or root) but not renderable; dropping op opcode=…")
return nil`. **Trigger:** every dt-app's button widget, anything Motif renders
via the pixmap-backed shadow widget. Also generic Athena widget chrome (which is
why SHORTCUTS / INVESTIGATION_MOTIF_INPUT.md exist). **Fix shape:** real pixmap
rendering. Allocate a `CGBitmapContext` per pixmap entry, route the same draw
routines through it, do real CopyArea pixmap→window via `ctx.draw(image, in:
rect)`. Big chunk of work, but every PRODUCT_2 milestone past M3 effectively
requires it. It's the next obvious sweep.

### 1.4 GC `function` (raster op) only honored by PolyFillRectangle
**Severity:** medium-high — works for Athena, breaks for anyone XOR-stroking.
**Missing:** `state.function` is materialized into GCState (`GCState.swift:44,
68`) but the only bridge call that takes `function` is `drawPolyFillRectangle`.
PolyLine, PolySegment, PolyRectangle, FillPoly, PolyArc, PolyFillArc all
silently drop it — they use GXcopy regardless of the GC. **Evidence:** `grep -n
"state.function" Sources/SwiftXServerCore/ServerSession.swift` returns one hit
at line 2009 (handlePolyFillRectangle). Compare to
`reference/xquartz-xserver/dix/gc.c:139-151` where `ChangeGC` accepts any `alu
<= GXset` (i.e. 0–15) and the fb backend honors the function on every op via the
fbCombine* macros. **Trigger:** xeyes XOR pupils, rubber-band selection
rectangles (xterm selection — does PolyRectangle with GXxor), MIT Athena List
widget hover highlight (PolySegment-based), drag outlines in old window
managers. **Fix shape:** thread `function` through every draw bridge call, do
`setBlendMode(.difference)` for GXxor as the existing pattern. Real fidelity
needs raw pixel ops (CG `.difference` is `|D - S|`, not bitwise XOR) but that's
a separate ledger entry — see comparison doc Surprises.

### 1.5 GraphicsExposures GC bit ignored on CopyArea
**Severity:** low-medium — works in practice because the bit defaults to True
and we always emit NoExpose. **Missing:** the GC's `graphicsExposures` value
isn't materialized into GCState at all (mask bit exists at `GCState.swift:21`
but `GCState.materialise` does not read it). Server always emits a single
NoExposureEvent for CopyArea — including when graphicsExposures=False, in which
case the spec says emit nothing. **Evidence:**
`Sources/SwiftXServerCore/ServerSession.swift:2166-2172` emits NoExpose
unconditionally with the explanatory comment about xterm's CopyWait. No code
path checks `state.graphicsExposures`. **Trigger:** clients that explicitly set
`XGCValues.graphics_exposures = False` and read other events synchronously —
they'll see a NoExpose they didn't ask for, which could confuse event-loop
bookkeeping. Rare but real. **Fix shape:** materialize the bit, gate the
`outbound.append(noExpose…)` on it.

## Bucket 2 — Will bleed when X happens

### 2.1 No CG line-cap / line-join set; client requests are ignored
**Severity:** medium — silent until a client wants Round or Projecting.
**Missing:** `capStyle` (bit 1<<6) and `joinStyle` (bit 1<<7) are read into the
entry's `values` dict but never materialized into GCState. `applyStrokePlane` in
`CocoaWindowBridge.swift:575-579` sets only line width and a half-pixel
translate; it never calls `setLineCap`/`setLineJoin`. The CG defaults are butt
cap + miter join, which match X11 *defaults*, so unmodified GCs work. A client
setting `CapRound`/`JoinRound` is silently downgraded. **Evidence:** `grep -in
"setLineCap\|setLineJoin\|kCGLineCap" Sources/SwiftXServerCore/` returns
nothing. **Trigger:** anything calling `XSetLineAttributes` with a non-default
cap or join. Motif drawing chrome with thick rounded-corner lines (some
scrollbar trough styles). Toolkit-drawn focus rings. **Fix shape:** materialize
cap/join in GCState, map to CG enums in `applyStrokePlane`, apply with
`ctx.setLineCap` / `ctx.setLineJoin`.

### 2.2 No line-style support (Solid / OnOffDash / DoubleDash)
**Severity:** medium — dashes work via SetDashes path, but `lineStyle =
DoubleDash` (which says "draw the off-segments in background color") is not
modelled at all. `lineStyle = OnOffDash` happens to work because we accept
SetDashes data and feed it to `setLineDash`, but the GC's own `lineStyle`
attribute is never consulted to decide whether to dash. **Missing:** `lineStyle`
(bit 1<<5) not in GCState; no DoubleDash code path. **Evidence:** `grep -n
"lineStyle" Sources/SwiftXServerCore/GCState.swift` returns only the mask-bit
declaration. **Trigger:** plot apps using DoubleDash to render two-color dashed
reference lines. **Fix shape:** materialize lineStyle, gate dashes on `lineStyle
!= Solid`, implement DoubleDash by stroking twice (foreground for on, background
for off) with offset dash phases.

### 2.3 No fill-style support (Tiled / Stippled / OpaqueStippled)
**Severity:** medium — most clients use FillSolid by default. xfig, plot apps,
and Motif gadget chrome that uses stippled greys for disabled state will bleed.
**Missing:** `fillStyle` (bit 1<<8), `tile` (1<<10), `stipple` (1<<11),
`tileStippleXOrigin` (1<<12), `tileStippleYOrigin` (1<<13) — all six bits are
read into the entry dict but none is materialized or consulted. Every fill uses
`applyFill(ctx, foreground)`. **Evidence:** `grep -n "fillStyle\|tile\|stipple"
Sources/SwiftXServerCore/CocoaWindowBridge.swift` returns nothing in the fill
paths. **Trigger:** "disabled" greyed-out Motif buttons that should be
50%-stippled. Resource monitors that use stippled fills for legend entries.
**Fix shape:** materialize the fill-style group; for Tiled, build a tiling
`CGPattern` from the tile pixmap (which requires the pixmap-rendering fix from
1.3); for Stippled, treat the 1-bit stipple as an alpha mask via a masked-image
fill.

### 2.4 No plane-mask support
**Severity:** low for TrueColor visuals, high if/when we expose pseudocolor.
**Missing:** `planeMask` (bit 1<<1) not in GCState. Every pixel op writes all
bits. **Evidence:** as above. No CG analog directly; would need an offscreen
bitmap and a masked compositing step. **Trigger:** apps drawing into specific
planes of a pseudo-color visual (legitimate X11R6-era pattern — overlay planes
for crosshairs, cursors). None of the named test apps do this against a
TrueColor visual. **Fix shape:** low priority for the TrueColor-only swift-x
present.

### 2.5 SetClipRectangles "ordering" parameter ignored, no error on inconsistency
**Severity:** low — most clients pass `Unsorted` and trust the server.
**Missing:** `handle.setClipRectangles` doesn't take or check the ordering
parameter. Spec allows the server to optionally emit a Match error for
inconsistent ordering claims; we don't (we accept any ordering claim).
**Evidence:** `Sources/SwiftXServerCore/ServerSession.swift:3281-3292`. The
Framer struct may or may not parse the ordering byte — check
`Sources/Framer/Requests/SetClipRectangles.swift` — but the handler doesn't
care. **Trigger:** none currently. Pure spec-compliance corner. Listed for
completeness. **Fix shape:** not urgent; on the "spec audit" wishlist.

### 2.6 GC value-range validation is absent → no BadValue
**Severity:** medium — affects testing correctness more than rendering, but
explicitly contradicts the project's "XErrors are real protocol output" policy.
**Missing:** `applyValueList` in `ResourceTables.swift:265-286` accepts any 4
bytes for any bit. xorg's `ChangeGC` in
`reference/xquartz-xserver/dix/gc.c:139-405` validates every enum-valued
attribute and returns `BadValue` with `errorValue = the bad value`.
**Evidence:** `grep -n "BadValue\|errorValue"
Sources/SwiftXServerCore/ResourceTables.swift` returns nothing. **Trigger:** an
X client deliberately probing the server with bad GC values (common in
protocol-correctness test suites — XTS). Less common in real clients. **Fix
shape:** an enum table per GC bit with the legal value range; emit `BadValue` on
out-of-range, matching xorg's behavior exactly. Tedious but mechanical.

### 2.7 ArcMode `Chord` not implemented (PolyFillArc always pie)
**Severity:** low-medium — PolyFillArc with chord-mode draws the *segment* (arc
+ chord between endpoints), not the pie slice. We always do pie. **Missing:**
`arcMode` (bit 1<<22) not in GCState; `drawPolyFillArc` hard-codes
`includePieCenter: true`. **Evidence:**
`Sources/SwiftXServerCore/CocoaWindowBridge.swift:765-783`, comment "default
arc-mode=PieSlice; chord mode is unhandled". **Trigger:** any client filling
chord segments (statistical visualization, clock-face shading). Not present in
named clients. **Fix shape:** materialize arcMode; when chord-mode, build the
path as arc-then-line-back-to-start (no center vertex).

## Bucket 3 — Theoretical / spec-only

### 3.1 CG antialiasing on by default for all stroke and fill
The X spec says "no pixel of the region is drawn more than once" for FillPoly
and "no pixel is drawn more than once" for PolyRectangle. CG's default AA
softens edge pixels into a blended-alpha band — those edge pixels are partially
drawn. For TrueColor visuals against a stable backdrop this is invisible quality
goodness; for compositing scenarios (XOR rubber bands, copy planes, multi-pass
clip ops) the spec assumption is violated and you can't recover the original.
`setShouldAntialias(true)` is set explicitly only for text; elsewhere it's CG's
default (also on). No bleed in named clients.

### 3.2 Bevel-join geometry implementation-dependent
Spec calls this out as "implementation dependent" so any reasonable answer is
spec-conformant. CG's bevel produces a clean miter-then-truncate that matches
X11R6's miPolyArc bevel within a pixel or two. Not a bug, but worth
acknowledging in the design doc.

### 3.3 Thin-line algorithm differs from Bresenham
X spec for line-width=0 thin lines requires translation invariance and gives
implementations latitude. CG's `setLineWidth(1)` is "geometric line of width 1
at the CTM scale", which is not Bresenham and so won't produce pixel-identical
output to a real Sun X server. The `applyStrokePlane` +0.5-pixel translate gets
it close. The captured-corpus xclock comparison is the right test for whether
this matters visually.

### 3.4 NotLast cap-style endpoint omission missing
Spec: `NotLast` is `Butt` except for line-width=0, where the final endpoint is
not drawn. CG has no equivalent — and since we don't honor capStyle at all
(2.1), this is doubly unimplemented. Only matters if you care about lines joined
end-to-end at zero line-width meeting at a single pixel rather than two.
