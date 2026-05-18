# Status 2026-05-18 — End of day

Long day chasing one symptom — text damage near the cursor in
dtpad's editor — through four layers of bugs, each unmasking the
next as it was fixed. Final state: Motif's XmText caret renders as
a crisp I-beam, doesn't damage characters it passes over, and the
text widget is fully usable. dtpad is now a real editor.

## Headline

**Motif XmText caret renders correctly in dtpad** — the four bugs
were 15-field XLFDs (parser rejected → Monaco fallback), DtEditor's
`textFontList` resource (not `fontList`), missing GC `fillStyle` /
`stipple` / origin support (caret rendered as solid block, not
I-beam), and pixmaps stored at logical scale on a 3× backing
(CopyArea save-under eroded glyph AA edges every blink). See
SHORTCUTS.md Closed list 2026-05-18 entry for the full breakdown.

## What landed

### Font path (dtpad opens Courier 14 for its editor)

- `MOTIF_TEXT_QUALITY.md` and `DefaultMotifResources.swift` Tier 1
  XLFDs corrected to 14 fields (one stray wildcard between
  RESOLUTION_Y and SPACING removed in each XLFD). `XLFD.parse`
  rejects 15-field strings; the fixture was failing to parse so
  every Motif `OpenFont` fell through to Monaco.
- `DefaultMotifResources.swift` now also publishes
  `*DtEditor.textFontList` and `Dtpad*textFontList`, the resource
  CDE's `DtEditor` widget actually reads. With those set, dtpad's
  editor opens `-adobe-courier-medium-r-normal--14-*-*-*-m-*-iso8859-1`
  → resolves to Courier New 12pt cell=7×14 monospace.

### Caret rendering (FillStippled + device-scale pixmaps)

- `GCState` carries `fillStyle`, `stipple`, `tile`, `tileStippleXOrigin/YOrigin`
  now (bits were defined in `GCBits` but never materialised).
  `GCState.materialise` reads them; `WindowBridge.drawPolyFillRectangle`
  signature carries them through to the bridge.
- `CocoaWindowBridge.fillStippled` implements per-pixel rasterisation
  for FillStippled (2) and FillOpaqueStippled (3) — runs of set
  stipple bits paint `foreground`, runs of clear bits leave the
  destination unchanged (FillStippled) or paint `background`
  (FillOpaqueStippled). FillTiled (1) falls through to solid for now.
- `withDrawContext` disables AA when drawing into depth-1 pixmaps
  so Motif's `PolySegment` carve of the I-beam into its stipple
  pixmap produces crisp 0-or-fg bits, not AA-soft edges that the
  bit reader rejects.
- `handlePolyFillRectangle` translates the stipple origin by the
  same window offset it applies to the rectangle. Motif sets the
  origin per-paint to the cursor's window-local top-left; without
  translating both together, the toroidal-tile math anchors to the
  wrong dest pixel and the I-beam pattern fragments.
- `PixelBuffer` allocates at device scale (`width*scale × height*scale`
  pixels) with a CTM matching `FlippedXView.resizeBacking`. Pixmaps
  are now lossless round-trip partners for the window backing — the
  Motif caret save-under no longer erodes glyph AA edges on each
  blink. `PixmapTable` carries the scale; `WindowBridge` protocol
  adds `scaleFactor`; `StippleBitGrid` samples the centre device
  pixel per logical bit.
- `CocoaWindowBridge.copyArea` window-source branch uses `dispatch_sync`
  rather than `dispatch_async`. The cursor save-under happens on
  the protocol queue but reads the window backing on main; without
  the sync, the protocol queue would proceed to a subsequent
  pixmap read while main was still writing the pixmap. XQuartz
  uses `xp_lock_window` (kernel-private, see hw/xquartz/xpr/xprFrame.c)
  for the same race; dispatch_sync is our equivalent.

### Tests

533 tests pass, 4 skipped, 0 failures.
`Tests/SwiftXServerCoreTests/FontDispatchTests.swift` updated to
match the new `drawPolyFillRectangle` signature (background, fillStyle,
stipple, tile, stippleOrigin args).

## What didn't land today

- **dt-Motif widget chrome (button shadows + labels)** still not
  rendering. Four hypotheses closed in code (region steps E0–E2 +
  the visibility-state-from-clipList fix) but unverified against
  u5. With caret now working, the next session can revisit dtpad's
  text widget visually then move on to button chrome.
- **Smoke against other dt-apps**: dtcalc, quickplot, xfontsel all
  use FillStippled for various widgets (button greying, scroll
  thumb hatching, focus rings). The stipple support landing today
  should make those look right; not yet verified.

## Working tree at end of day

All implementation changes committed. Stray untracked artifacts:

- `captures/dtcalc-u5-on-swiftx-v3.xtap` + `.json` — yesterday's
  pre-CDE-retirement capture. Can delete; superseded by the
  baseline that landed in `262c105`.
- `blog/*scratch*` — zero-byte file from May 11, not ours.
- `connection.json` working-tree mod — leftover from earlier
  capture-proxy work; revert when convenient.

## Tomorrow's recommended starting points

1. **Smoke other dt-apps with stipple support landed.** dtcalc
   button greying, quickplot menu separators, xfontsel scrollbar
   thumb should all look better. Capture before/after if anything
   regresses.
2. **dt-Motif button chrome (shadows + labels).** Last visible gap
   in the dt-app suite. Hypothesis pool was at four-closed, pending
   u5 verification. With caret done, this is the next thing to
   trace.
3. **Framer-shared bug investigation** (deferred from 2026-05-18).
   dtpad / dtmail / dticon misbehave the same way through proxy and
   server but work direct u5→ss2. Whatever the Framer is corrupting
   is shared between the two paths; capture + diff is the next move.

## Reflection

The most valuable lesson today: when Todd reports a visual artifact
and the gold reference (real Sun) doesn't show the same artifact,
the answer is "we're doing something wrong on the wire," not
"that's just how the protocol works." I tried twice to write off
residual artifacts as inherent behavior; both times Todd's pushback
was right and the further investigation found a real bug. Memory
entry [Visual artifacts vs gold = real bug] now captures that.

Second lesson: the X11 cursor model has multiple layers
(pointer-cursor via `XCreatePixmapCursor` with source+mask+save-under,
vs. text-widget caret via `FillStippled` + `CopyArea` save/restore).
Conflating them led to a wrong-shaped fix attempt; reading the
LessTif `TextOut.c` source got us aligned. Memory entry
[X11 cursor model] captures both.
