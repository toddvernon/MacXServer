# Drawing + GCs: three-way comparison

X spec is authority. X11R6 is era-correct intent. xorg+XQuartz is what's
actually still maintained and shipping on macOS. swift-x is read-only here.

## Scope

Every GC component the X11 spec defines, plus the eleven core drawing opcodes:
`PolyPoint` (64), `PolyLine` (65), `PolySegment` (66), `PolyRectangle` (67),
`PolyArc` (68), `FillPoly` (69), `PolyFillRectangle` (70), `PolyFillArc` (71),
`ImageText8` (76), `ImageText16` (77), `PolyText8` (74), `PolyText16` (75). Also
`SetClipRectangles` (59), `SetDashes` (58), `ChangeGC` (56), `CopyGC` (57).

---

## Spec (authority)

GC components, defaults, and where each one is consumed (from
`reference/x11-protocol-spec/x11protocol.html`):

| Component | Type | Default | Used by |
|---|---|---|---|
| function | enum 0..15 (GXclear..GXset) | GXcopy (3) | every draw op |
| plane-mask | CARD32 | all-ones | every draw op |
| foreground | pixel | 0 | every drawn-mode op |
| background | pixel | 1 | ImageText*, DoubleDash, OpaqueStippled |
| line-width | CARD16 | 0 (thin line) | line/segment/arc/rectangle |
| line-style | Solid/OnOffDash/DoubleDash | Solid | line/segment/arc/rectangle |
| cap-style | NotLast/Butt/Round/Projecting | Butt | line endpoints |
| join-style | Miter/Round/Bevel | Miter | line junctions |
| fill-style | Solid/Tiled/Stippled/OpaqueStippled | Solid | all fills |
| fill-rule | EvenOdd/Winding | EvenOdd | FillPoly |
| tile | PIXMAP | foreground-filled | Tiled fills |
| stipple | PIXMAP | single 1-bit | Stippled fills |
| tile-stipple-x-origin | INT16 | 0 | Tiled/Stippled |
| tile-stipple-y-origin | INT16 | 0 | Tiled/Stippled |
| font | FONT | server-default | Text ops |
| subwindow-mode | ClipByChildren/IncludeInferiors | ClipByChildren | all draws |
| graphics-exposures | BOOL | True | CopyArea/CopyPlane |
| clip-x-origin | INT16 | 0 | clip translation |
| clip-y-origin | INT16 | 0 | clip translation |
| clip-mask | PIXMAP or None | None | all draws |
| dash-offset | CARD16 | 0 | dashed line phase |
| dashes | LISTofCARD8 | [4,4] | dashed line pattern |
| arc-mode | Chord/PieSlice | PieSlice | PolyFillArc |

Key spec language to anchor on:

- **PolyLine** (spec §9, line 5253): "draws lines between each pair of points
  (point[i], point[i+1]). The lines join correctly at all intermediate points."
  For wide lines, "intersecting pixels are drawn only once, as though the entire
  PolyLine were a single filled shape." Thin lines: intersecting pixels *can* be
  drawn multiple times.
- **PolyArc** (5369..): "positive [angle2] indicating counterclockwise motion."
  Angles are in 64ths of a degree, angle1 measured from three-o'clock.
- **FillPoly** (5489..): "fills the region closed by the specified path. The
  path is closed automatically if the last point in the list does not coincide
  with the first point." Shape hint (Complex/Nonconvex/Convex) is a performance
  optimization; using EvenOdd is always correct.
- **PolyFillRectangle** (5563..): "as if a four-point FillPoly were specified
  for each rectangle."
- **SetClipRectangles** (4963..): "rectangles should be nonintersecting, or
  graphics results will be undefined. … the list of rectangles can be empty,
  which effectively disables output."

X11 coordinate model: **pixel-center addressing**. A line from (0,0) to (2,0)
hits 3 pixels (both endpoints inclusive). Y-axis points down. Origin is top-left
of the drawable.

---

## X11R6 era-correct intent

`reference/X11R6/xc/programs/Xserver/`:

- `dix/dispatch.c:1624` `ProcPolyPoint` — validates coordMode, dispatches to
  `pGC->ops->PolyPoint`.
- `dix/dispatch.c:1648` `ProcPolyLine` — same pattern, dispatches to
  `pGC->ops->Polylines`.
- `dix/dispatch.c:1672` `ProcPolySegment` — checks length is multiple of 8
  (BadLength), dispatches.
- `dix/gc.c` (R6 era; same name, predecessor of the xorg file) — full
  `BadValue`-on-out-of-range checks for every enum-valued GC attribute.

The R6 mi (machine-independent) drawing primitives are clean reference
implementations:

- `mi/mipoly.c:68` `miFillPolygon` — the actual scanline-fill algorithm with
  fill-rule support.
- `mi/mipolypnt.c:56` `miPolyPoint` — really does iterate and plot points.
- `mi/mipolyseg.c:67` `miPolySegment` — segment dispatcher.
- `mi/miwideline.c:1523` `miWideLine` — wide-line rasterizer; spec-rigorous
  about join and cap geometry.
- `mi/mizerline.c:373` `miZeroLine` — Bresenham thin-line rasterizer.
- `mi/miarc.c:1034` `miPolyArc` — full ellipse arc rasterizer for wide lines;
  honors line-style/cap/join/dash.
- `mi/mizerarc.c:707` `miZeroPolyArc` — thin (zero-width) arc rasterizer.
- `mi/mifillarc.c:783` `miPolyFillArc` — arc-fill with chord/pie modes.
- `mi/midash.c:83` `miDashLine` — clips a polyline against the GC's dash
  pattern, returning segments to draw.
- `mi/mifillrct.c:68` `miPolyFillRect` — fill-rectangle, including handling
  Tiled/Stippled via fill-style.

The R6 dispatch model is one indirect-call per op via `pGC->ops`, so DDX
backends (cfb, mfb, xnest, ...) plug in faster pixel-bashing where they have it,
and fall back to mi for the slow path.

---

## xorg + XQuartz today

`reference/xquartz-xserver/`. xorg core drawing collapses into one column;
XQuartz overrides are very narrow.

**Dispatch + GC validation (shared with R6 lineage):**

- `dix/gc.c:75` `ValidateGC` — drives `pGC->funcs->ValidateGC`, which recomputes
  the composite clip / stipple / tile state when the GC has changed.
- `dix/gc.c:123` `ChangeGC` — exhaustive `BadValue` validation. Every
  enum-valued bit gets `if (new <= LastValue) ... else error = BadValue`. This
  is the file every X server should mimic.
- `dix/gc.c:526` `CreateGC` — calls `ChangeGC` for the initial mask, so same
  validation applies.

**Actual pixel ops (fb backend, where the bits move):**

- `fb/fbgc.c:65` `fbCreateGC` — installs `fb/fbgc.c:47-53` ops vector:
  `fbPolyPoint`, `fbPolyLine`, `fbPolySegment`, `fbPolyRectangle`, `fbPolyArc`,
  `fbPolyFillRect`, `fbPolyFillArc`, ...
- `fb/fbgc.c:113` `fbValidateGC` — fast-path selection based on line-style,
  fill-style, depth.
- `fb/fbline.c:91` `fbPolyLine` — branches: zero-width + solid + 1-rect-clip →
  custom `fbPolyline{8,16,32}` (depth-specialized); zero-width otherwise →
  `fbZeroLine`; wide solid → `miWideLine`; wide dashed → `miWideDash`.
- `fb/fbline.c:123` `fbPolySegment` — parallel structure to fbPolyLine.
- `fb/fbarc.c:37` `fbPolyArc` — wide arcs go to `miPolyArc`; thin arcs go to
  `miZeroPolyArc` (with depth-specialized fast paths).
- `fb/fbfillrect.c:30` `fbPolyFillRect` — span-fill loop honoring tile, stipple,
  opaque-stipple, plane-mask, all 16 raster ops.

**The fb framebuffer macros (`fb/fb.h`):** `fbCombineRRop`, `fbDoCopy`, `fbAnd`,
`fbOr`, `fbXor`. The X `function` (alu) attribute drives which combine macro is
used. Every pixel op goes through these. This is the contract for "GXxor really
is bitwise XOR" — CG cannot do this directly.

**XQuartz overrides:** vanishingly few in the drawing space. `hw/xquartz/` does
screen/event/keyboard work and stitches xorg's fb output into Cocoa NSWindows
via the `xpr` (X-pixmap-rootless) layer (`hw/xquartz/xpr/`).
`hw/xquartz/darwin.c:241` calls vanilla `fbScreenInit`. There's no `xprPolyLine`
or anything analogous — XQuartz inherits xorg's drawing primitives wholesale.

---

## swift-x

Read-only on source. Files involved: `Sources/SwiftXServerCore/GCState.swift`,
`ResourceTables.swift` (GCTable / GCEntry), `ServerSession.swift` (dispatch +
draw handlers), `CocoaWindowBridge.swift` (CG drawing), `FlippedXView.swift`
(CGBitmapContext backing + CTM).

**Dispatch.** `Sources/SwiftXServerCore/ServerSession.swift:3155-3290` is the
opcode dispatch switch. Drawing routes per request:

| Opcode | Handler (`ServerSession.swift`) | Bridge call (`CocoaWindowBridge.swift`) | Status |
|---|---|---|---|
| 64 PolyPoint | (none) | (none) | falls through to `unknown` → BadRequest @3918 |
| 65 PolyLine | `handlePolyLine:1931` | `drawPolyLine:493` | foreground+width+dashes only |
| 66 PolySegment | `handlePolySegment:1909` | `drawPolySegment:475` | foreground+width+dashes only |
| 67 PolyRectangle | `handlePolyRectangle:2015` | `drawPolyRectangle:690` | foreground+width+dashes only |
| 68 PolyArc | `handlePolyArc:2037` | `drawPolyArc:746` → `ellipseArcPath:1333` | foreground+width+dashes; sweep direction inverted |
| 69 FillPoly | `handleFillPoly:1964` | `drawFillPoly:581` | foreground + fill-rule only |
| 70 PolyFillRectangle | `handlePolyFillRectangle:1995` | `drawPolyFillRectangle:711` | foreground + GXxor as `.difference` |
| 71 PolyFillArc | `handlePolyFillArc:2060` | `drawPolyFillArc:768` | foreground only, hard-pieSlice |
| 74 PolyText8 | `handlePolyText8:2103` | `drawPolyText8:879` | foreground + font; CG actual-advance |
| 76 ImageText8 | `handleImageText8:2080` | `drawImageText8:785` | foreground + background + font; cell-snapped |
| `PolyText16`, `ImageText16` | (none) | (none) | not parsed, BadRequest |

**GC model.** `GCEntry` (`ResourceTables.swift:189-215`) holds `values: [UInt32:
UInt32]` keyed by bit, plus `clipRectangles` and `dashes` on the side.
`GCTable.applyValueList` (`ResourceTables.swift:265-286`) walks the bitmask in
order and stuffs each 4-byte CARD32 into the dict. No range validation, no enum
coercion — any 4 bytes pass.

**GCState materialise** (`GCState.swift:60-78`) pulls out *eight* attributes:
foreground, background, lineWidth, fillRuleEvenOdd, font, dashOffset, function,
plus clipRectangles. The other fifteen GC components from the spec table are
stored on the entry's `values` dict but never read by any draw path:

```
plane-mask, line-style, cap-style, join-style, fill-style,
tile, stipple, tile-stipple-x-origin, tile-stipple-y-origin,
subwindow-mode, graphics-exposures,
clip-x-origin, clip-y-origin, clip-mask, arc-mode
```

`clip-x-origin` and `clip-y-origin` are partially used — at materialise time
they offset the clipRectangles into top-level-local coords
(`GCState.swift:70-75`), but the bits themselves aren't kept in the materialised
state. Practical equivalent.

**CG bridge specifics:**

- `CocoaWindowBridge.swift:543-553` `withClip` — applies clip rectangles via
  `ctx.clip(to: [CGRect])`, honors the empty-list-disables-output rule, wraps in
  saveGState. Used by every draw method.
- `CocoaWindowBridge.swift:563-573` `applyDashes` — passes dash bytes through
  `setLineDash(phase:lengths:)`. Per spec a single dash byte means [N, N]; the
  code duplicates correctly.
- `CocoaWindowBridge.swift:575-579` `applyStrokePlane` — translateBy(0.5, 0.5)
  then setLineWidth(max(1, clientWidth)). Line-cap and line-join never set.
  Width 0 silently becomes 1.
- `CocoaWindowBridge.swift:715-735` GXxor for PolyFillRectangle: uses
  `setBlendMode(.difference)`. Source comment honestly notes this is
  "XOR-equivalent for binary colors" but not true bitwise XOR (which is `|D -
  S|` per channel, not `D ^ S`).
- `CocoaWindowBridge.swift:1333-1357` `ellipseArcPath` — parametric ellipse
  sampler, ~32 steps per π of extent. Cleaner pen-width behavior on non-circular
  arcs than `addArc` would give, but doesn't compensate for the flipped CTM.

**Validation entry points** (`ServerSession.swift`):

- `validateGC:1609` — bad GC ID → emit BadGC, return nil. No value-range check.
- `validateDrawTarget:1624` — unknown drawable → BadDrawable; valid pixmap or
  root → silent drop with log line. Comment at :1620 acknowledges the
  silent-drop is a documented ledger lie because dt-apps depend on it not
  erroring.

---

## Surprises and divergences

### The Y-flip × arc-angle bug

This is the meatiest issue I found. The backing CGBitmapContext has a y-down CTM
(`FlippedXView.swift:288-310`) so that X coordinate (x, y) can flow through into
CG draw calls unchanged. The arc-path builder
(`CocoaWindowBridge.swift:1333-1357`) computes points as `(cx + rx*cos(t), cy +
ry*sin(t))` using ordinary math-convention angles. Under the flipped CTM, +sin
lands visually downward. X11 spec says positive angle = counterclockwise
(visually CCW), so swift-x's arcs trace visually clockwise for positive
`angle2`. Anything direction-aware looks mirrored. xclock's hand-sweep is the
canonical victim.

### CG `.difference` is not GXxor

`CocoaWindowBridge.swift:716-727` substitutes `setBlendMode(.difference)` for
X11's GXxor (function = 6). Difference is `|D - S|` per channel, clipped to
[0,1]. On pure black/white that's accurate (white minus black = white, white
minus white = 0); on intermediate colors it's not — and it's not invertible per
pixel, so the Athena XOR-highlight idiom (XOR once to highlight, XOR again to
un-highlight) only works because the surface underneath is a known constant. The
honest fix needs raw pixel ops over a software framebuffer — exactly the path
the fb backend in xorg takes. This is a fundamental impedance mismatch between
Core Graphics' compositing model and X11's raster-op model. **Blog hook 1.**

### Pixel-center vs grid-line addressing, partially papered over

`CocoaWindowBridge.swift:513-538` documents this carefully: X11 means "pixel (x,
y)" by an integer coordinate; CG means "the grid line between pixels (x-1, y)
and (x, y)." The fix is `translateBy(0.5, 0.5)` before strokes, then any width-1
stroke at an integer coord lands inside a single pixel row. For fills, the
half-pixel translate isn't applied (because the +0.5 doesn't matter for fills at
integer coords — the rect aligns to the grid either way). This is right, but it
leaves a class of bugs latent: any stroke that uses `setLineCap(.square)` or any
path that bridges between stroke and fill (e.g. a closed-polyline outline + fill
via PolyFillPoly followed by PolyLine on the same vertex list) will see the
half-pixel shift on stroke and no shift on fill — they'll mis-register by half a
pixel. Not a real client problem until someone strokes a filled shape's outline
as a hairline.

### Antialiasing on by default everywhere

`setShouldAntialias` is set explicitly to `true` for text drawing (which is the
right call — fonts should be antialiased). Everywhere else, CG's default
antialiasing is in effect. That means PolyArc, PolyLine, FillPoly all get
smoothed edges. Visually this is goodness ("crisp" old X servers look jagged
compared to swift-x output on Retina). Spec-wise it's a real divergence: "no
pixel of the region is drawn more than once" implies 1-bit coverage, which AA
breaks. **Blog hook 2.** The interesting tension is that swift-x is *trying* to
look better than XQuartz, and AA is a big part of why it does. We don't want to
turn it off — but if we ever need predictable coverage (e.g. for
capturing-and-replaying CopyArea after a rubber band), we'll need a mode bit.

### Stroke vs fill of the same path produces different pixels

CG strokes paths along the path; CG fills paths inside the path. So
`PolyRectangle` of (0, 0, 10, 10) strokes a 1-pixel-wide outline going through
pixels y=0 and y=10 (after the +0.5 translate). `PolyFillRectangle` of the same
coords fills pixels (0..9, 0..9) — pixel y=10 is *not* in the fill. In X11 the
two ops also disagree but along a different axis (X11 fill is
right/bottom-exclusive; X11 stroke is endpoint-inclusive on both ends). swift-x
lines up with X11 on `PolyFillRectangle` (CG fill is right/bottom-exclusive too)
but the +0.5 stroke translate may put the right and bottom strokes one pixel
beyond where R6's miFillRect-then-stroke would. Worth a unit test if anyone
draws stroked-and-filled rectangles with pixel-exact expectations.

### `validateDrawTarget` silently swallows pixmap and root draws

`ServerSession.swift:1624-1634`. dt-apps build button chrome in offscreen
pixmaps and `CopyArea` them; with pixmap draws silently dropping, those buttons
render blank. This is a known SHORTCUTS ledger entry (per the project's working
conventions, though I haven't read SHORTCUTS), but through this audit's lens
it's a high-severity gap — see risk register 1.3.

### PolyPoint is a flat protocol gap

The Framer doesn't know about it, the server doesn't dispatch it, so it falls
through `case .unknown` and emits BadRequest. Real clients that hit this — and
there are some, particularly anything plotting per-pixel points — will see a
protocol error they didn't expect.

### GC value ranges are unvalidated

xorg's `dix/gc.c:139-405` is a long block of `if (new <= LastValue) ... else
error = BadValue` for every enum-valued attribute. swift-x has none. A client
sending `function = 99` succeeds. The server stores 99 in the values dict,
materialises it into `state.function`, and `drawPolyFillRectangle` treats
`function != 6` as GXcopy. Wrong, silently. The XError-honesty policy in
CLAUDE.md calls this out: "lying on the wire is a ledgered exception, not a
default."

### `XQuartz uses xorg's drawing wholesale`

This is worth saying out loud because it's the natural reference architecture.
XQuartz's `hw/xquartz/` is screen + event + window-system bridging. Drawing goes
through stock `fbScreenInit` and the unmodified xorg fb backend. There is no
`XQuartzPolyLine`. swift-x has made a different bet — bypass the fb backend
entirely and go straight to CG — and pays for it everywhere the fb model and the
CG model don't line up (GXxor, plane-mask, pixel-exact ops, raster ops in
general). **Blog hook 3.**

---

## Blog hooks

1. **"Why Core Graphics can't do GXxor"** — the impedance mismatch between X11's
   raster ops and CG's compositing operators. Walk through the Athena
   menu-highlight idiom, show how `.difference` blend almost works, show where
   it fails, motivate why a software-framebuffer backend is the only honest
   answer. Tie it to Apple's deliberate choice in XQuartz to keep the fb backend
   rather than rewriting to CG-native.
2. **"Antialiasing is a feature, until it's a bug"** — swift-x looks crisper
   than XQuartz on Retina because CG antialiases by default. That's the whole
   pitch. But "no pixel drawn more than once" is in the spec for a reason: it
   lets clients do compositing tricks (rubber bands, dirty-region tracking) that
   don't survive AA. How we'd give clients a per-GC AA hint without breaking the
   look on modern displays.
3. **"The half-pixel shift, the y-flip, and other CG-vs-X gotchas"** — a catalog
   of subtle coordinate-model mismatches between Core Graphics' geometric model
   and X11's pixel-addressing model. The `applyStrokePlane` +0.5 trick. The
   y-flip's effect on arc angles. Why CG's `fillRule` enum just happens to line
   up with X11's. What you'd need to do to be pixel-identical to a real Sun X
   server (and why you almost never want to be).
