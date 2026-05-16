# Drawing-opcode GC-component audit

Per-opcode findings. The pattern is uniform: GCState only materializes
foreground, background, lineWidth, fillRuleEvenOdd, font, dashOffset, function,
clipRectangles, dashes. Everything else the X spec names as a GC component of
a drawing request is either never stored from the value-list at materialise
time or never threaded into the bridge call. The bridge signatures themselves
encode the shortcut: there is no `lineStyle`, `capStyle`, `joinStyle`,
`fillStyle`, `tile`, `stipple`, `tsXOrigin`, `tsYOrigin`, `subwindowMode`,
`planeMask`, `graphicsExposures`, `clipMask`, or `arcMode` parameter on any
draw method in `WindowBridge.swift:226-291`.

CocoaWindowBridge consults exactly: foreground (via `applyForeground`/`applyFill`,
`CocoaWindowBridge.swift:1189`), background (only in ImageText8/clearArea),
lineWidth (`applyStrokePlane:609`), evenOdd (FillPoly only), function=6 (only
PolyFillRectangle, mapped to `.difference` blend), clipRectangles
(`withClip:577`), dashes + dashOffset (stroke methods only, `applyDashes:597`).

Findings table below. PolyPoint (64) and CopyPlane (63) are not in the
Framer parser at all — they're entirely undispatched (verified by grep on
`Sources/Framer/`); they fall through to the unhandled-opcode path. PutImage
is dispatched but silent-dropped at `ServerSession.swift:3874` (already
ledgered as the "no pixmap pixel store" SHORTCUT, but each missing GC
component is its own breakage when that lands).

| Opcode | GC component | Shortcut found | What real would look like | Severity | Fix-shape |
|---|---|---|---|---|---|
| PolyLine (65) | line-style | `GCState.swift:32-52` never stores line-style; `WindowBridge.swift:227` has no parameter; `CocoaWindowBridge.swift:527 drawPolyLine` never calls `setLineDash` for OnOffDash/DoubleDash semantics (only the SetDashes `dashes` array reaches it, never the line-style enum that switches between Solid / OnOffDash / DoubleDash) | OnOffDash + DoubleDash differ in how the "off" cells render (transparent vs background-pixel-filled). DoubleDash needs the background pixel painted in off cells. | latent — triggered by any client using XSetLineAttributes with `LineOnOffDash`/`LineDoubleDash`. xfig, xmgrace dashed plots, xeyes' bordered sclera if `-outline`. | Add `lineStyle: UInt8` to GCState + bridge call. In bridge: for DoubleDash, draw twice (background then foreground with offset dashes); for solid, skip setLineDash. |
| PolyLine (65) | cap-style | `GCState.swift` no storage; `WindowBridge.swift:227` no parameter; `CocoaWindowBridge.swift:527 drawPolyLine` never calls `ctx.setLineCap`, so CG default (butt) is used regardless of CapNotLast / CapButt / CapRound / CapProjecting. | CapNotLast is the X11 default for thin lines; CapProjecting extends ends past the endpoint by line-width/2. CG default butt is closest to CapButt. | latent — any client setting line cap. Athena Toggle widget's marker, xfig wide strokes. | Thread cap-style through; map to CGLineCap. CapNotLast needs path-shortening for the last segment. |
| PolyLine (65) | join-style | Same: not stored, not passed, `ctx.setLineJoin` never called. JoinMiter/JoinRound/JoinBevel ignored; CG default miter is used. | At joins between segments, X11 default is JoinMiter; thick polylines look different per join style. | cosmetic for thin-line plots; latent for thick polylines. | Thread join-style through; map to CGLineJoin. |
| PolyLine (65) | function | Stored on GCState (`GCState.swift:44, 68`) but `handlePolyLine:2042` does NOT pass it to the bridge; `drawPolyLine` always uses CG default copy blend. | GXxor / GXinvert needed for rubber-band selection lines (the classic "drag-a-box" XOR rectangle on every X drawing app). | load-bearing — xfig rubber-band selection, xmag drag-box, every Athena drag selector, GIMP's selection marquee. The function IS stored, just not piped. | Add `function` to bridge call (already done for PolyFillRectangle); apply `.difference` blend like the fill path. |
| PolyLine (65) | plane-mask | Not stored in GCState; bridge can't filter writes by plane. | Plane-mask all-ones is the default — so for the 24/32-bit windows we serve, almost no client cares. But Athena draws cursor outlines with plane-mask=1 to write only the low plane. | latent — only multi-plane-aware clients (rare). | Stored-but-inert isn't the right framing here: not even stored. Add to GCState; document as no-op for TrueColor windows. |
| PolyLine (65) | subwindow-mode | Not stored; not passed. ClipByChildren (default) vs IncludeInferiors changes whether a draw on the parent shows through subwindow regions. | ClipByChildren is default, so this matches our current "don't clip out child regions" no-op for the common case. IncludeInferiors clients (xterm scrollbar) would see overdraw on children we don't replicate. | latent — IncludeInferiors-using clients. | Add to GCState; route through bridge; on IncludeInferiors, skip child-region clipping. |
| PolyLine (65) | clip-mask | Only `clipRectangles` is honored (from SetClipRectangles). A pixmap clip-mask set via ChangeGC CWClipMask is silently dropped. | Athena uses pixmap clip-masks for icon shape; Motif uses them for shaped widgets. | latent — Motif shaped buttons, Athena icons. | Hard fix — needs pixmap pixel store first, then translate to CGContext clip with CGImage mask. |
| PolySegment (66) | line-style, cap-style, join-style, function, plane-mask, subwindow-mode, clip-mask | Identical chain-of-shortcuts as PolyLine. `handlePolySegment:2020` reads only foreground/lineWidth/clipRectangles/dashes/dashOffset; `CocoaWindowBridge.swift:509 drawPolySegment` never calls setLineCap/setLineJoin/setBlendMode. Function stored but dropped at handler. | See PolyLine row. | load-bearing for function (XOR rubber-band); rest latent. | Same generalized fix as PolyLine. |
| PolyArc (68) | line-style, cap-style, join-style | `GCState` no storage; `WindowBridge.swift:241` no parameters; `CocoaWindowBridge.swift:780 drawPolyArc` builds a polyline of N segments and strokes via `ctx.strokePath()` with no cap/join configured. xclock's clock hands and xeyes' eye outlines are arcs. | xclock spec face draws hour-tick arcs with cap-style projecting; xeyes uses CapRound. CG default butt gives a flat tip. | cosmetic — visually mild on the clients we host (clock face ticks look fine). | Same shape as PolyLine fixes. |
| PolyArc (68) | function | GCState has it; `handlePolyArc:2148` does NOT pass it. `drawPolyArc` uses default blend. | xclock erases the previous hands by re-drawing them in XOR. We get away with it because xclock instead clears+redraws on every tick — but other clock-style apps use XOR. | latent — xclock-variants that XOR-erase, gauge-style applets. | Plumb function through. |
| PolyFillRectangle (70) | fill-style | `GCState.swift:32-52` does not store fill-style; `WindowBridge.swift:232` has no parameter; `CocoaWindowBridge.swift:745 drawPolyFillRectangle` always paints `applyFill(ctx, foreground)`. Solid is default, but FillTiled / FillStippled / FillOpaqueStippled change the fill source to a tile pixmap or stipple bitmap. | The CDE/Motif chrome 50%-grey shading is FillStippled with a checker stipple. dt-apps' button bevels rely on it. (`INVESTIGATION_MOTIF_INPUT.md` already mentions Motif chrome unrendered.) | load-bearing — Motif/CDE button chrome, Athena Command widget pressed state, twm titlebar texture, xfig pattern fills. | Needs (a) tile/stipple pixmap storage, (b) a tile/stipple parameter on the bridge call, (c) CGContext.drawTiledImage with the resolved bitmap; opaque vs transparent stipple selects whether background pixel is painted in 0-bits. |
| PolyFillRectangle (70) | tile, stipple, ts-x-origin, ts-y-origin | Not stored on GCState; never passed. | Same: Motif chrome stipples appear as solid color. | load-bearing — see fill-style row, same class of client. | Same as fill-style — these are mode-dependent components for the tile/stipple fill modes. |
| PolyFillRectangle (70) | plane-mask | Not stored. | Same as PolyLine — TrueColor windows don't notice. | latent. | Add to GCState. |
| PolyFillRectangle (70) | function | Honored, but only by hand-matching `function == 6` and mapping to `.difference` blend (`CocoaWindowBridge.swift:759`). GXcopy(3) and GXxor(6) are the only two cases handled; GXand(1), GXor(7), GXequiv(9), GXinvert(10), GXcopyInverted(12) etc. all silently fall through to default CG copy blend. | GXinvert is used by xterm's reverse-video selection on some terminals; GXand is used by Athena 2D shadow effects. | latent — clients using non-copy non-xor functions. xterm reverse-video selection in some Sun configs. | Full switch over the 16 X function codes with CG blend-mode equivalents (most need stencil tricks, not native CG blends). |
| PolyFillRectangle (70) | clip-mask, subwindow-mode | Not stored/passed. | Same as PolyLine. | latent. | Same as PolyLine. |
| PolyFillArc (71) | arc-mode | `GCState.swift:44-52` no storage; `WindowBridge.swift:246` no parameter; `CocoaWindowBridge.swift:802 drawPolyFillArc` always passes `includePieCenter: true`, i.e. PieSlice mode hardcoded. ArcChord mode is silently treated as PieSlice. | Athena Toggle widget's diamond marker uses ArcChord. | cosmetic to latent. | Add `arcMode: UInt8` to bridge call; pass `includePieCenter: arcMode == 0` (PieSlice = 0, Chord = 1). |
| PolyFillArc (71) | fill-style, tile, stipple, ts-origins | Same as PolyFillRectangle — solid hardcoded, stipple/tile dropped. | xclock face shading is sometimes stippled. | latent. | Same as PolyFillRectangle. |
| PolyFillArc (71) | function | Not passed (`handlePolyFillArc:2171`). | XOR-fill-arc used for hand erasure in some clock variants. | latent. | Same as PolyLine function. |
| PolyFillArc (71) | plane-mask, subwindow-mode, clip-mask | Not stored/passed. | Same. | latent. | Same. |
| FillPoly (69) | fill-style, tile, stipple, ts-origins | Not stored/passed; `CocoaWindowBridge.swift:615 drawFillPoly` calls `applyFill(ctx, foreground)` only. | xfig polygon pattern fills, GIMP brush stamp polygons. | load-bearing — xfig and any drawing program with pattern fills. | Same as PolyFillRectangle fill-style. |
| FillPoly (69) | function, plane-mask, subwindow-mode, clip-mask | Not passed; default GXcopy used always. | XOR polygon rubber-band is a common drawing-app idiom. | load-bearing for function (rubber-band); rest latent. | Same shape as PolyLine. |
| FillPoly (69) | fill-rule | Honored (`GCState.swift:36, 65`; `handleFillPoly:2079`; `drawFillPoly:615` calls `.evenOdd` / `.winding`). Correct. | n/a | n/a | none. |
| PolyText8 (74) | fill-style, function, plane-mask, tile, stipple, ts-origins, subwindow-mode, clip-mask | `handlePolyText8:2214` reads only foreground/font/clipRectangles. `CocoaWindowBridge.swift:913 drawPolyText8` only calls `applyFill(ctx, foreground)` then draws glyphs via `CTFontDrawGlyphs`. No function, no fill-style. | Motif rendered text on a stipple-fill background uses FillStippled for glyph fg; xfig italic-text XOR for cursor preview. | latent — Motif chrome text fg is solid in practice; XOR text preview is rare. | Plumb function and fill-style through; on FillStippled, paint glyphs via CGContext.clip(toMask:) of a glyph image with the stipple pattern as source. |
| ImageText8 (76) | plane-mask, subwindow-mode, clip-mask | Same: not stored/passed. | Plane-mask on text is exceedingly rare. | cosmetic. | Add for completeness if/when plane-mask gets generalized. |
| ImageText8 (76) | font fallback hardcoded "fixed" | `handleImageText8:2201` — if `state.font == 0` we resolve to "fixed". X11 spec says using a GC with no font set causes a Match error on text requests. | A real server emits BadMatch; xterm sets a font in CreateGC so the path isn't usually hit, but a buggy client that forgets gets a silent draw with our defaults. | cosmetic — every well-behaved client sets a GC font. | Emit Match (XError code 8) instead of resolving "fixed". |
| CopyArea (62) | function, plane-mask, subwindow-mode, clip-mask | `handleCopyArea:2235` reads only clipRectangles; `CocoaWindowBridge.swift:646 copyArea` ignores clip too (logged at 660, then bitmap-memmove path proceeds). Function, plane-mask, subwindow-mode never plumbed. | CopyArea with GXxor used for XOR rubber-band drag; with subwindow-mode=IncludeInferiors copying from a parent grabs children's pixels too — xterm scrollbar relies on this; with clip, only part of the area gets copied. | load-bearing for clip — clip-via-CopyArea-into-stencil is a real pattern; load-bearing for IncludeInferiors — xterm scrollbar; latent for function. | Hardest fix: clip needs us to either route through CGContext (and lose memmove overlap correctness) or maintain a region-aware blit. Already partially called out at `CocoaWindowBridge.swift:653-661`. |
| CopyArea (62) | graphics-exposures | `handleCopyArea:2277` emits `NoExposure` unconditionally regardless of the GC's graphics-exposures bit. Per spec (5148-5149): if graphics-exposures=False, emit NEITHER GraphicsExpose nor NoExpose. | A client with graphics-exposures=False that polls the event queue thinking it's empty finds a NoExpose it didn't expect. xterm's CopyWait uses graphics-exposures=True so we get away with it. | cosmetic — most clients leave graphics-exposures at the default True. | Read the bit in GCState; gate the NoExpose emit on `graphicsExposures == 1` (the default). |
| ClearArea (61) | (none — ClearArea does not use a GC) | n/a; uses window's background-pixel. Our `handleClearArea:2286` reads `windowBackground` which only handles `CWBackPixel`, not `CWBackPixmap`. | A window created with a background pixmap (e.g., Motif's textured root, twm icon background) should have its background-pixmap tiled into the cleared area. We paint solid white when the pixmap isn't stored. | latent — twm-style desktop, any Motif app setting CWBackPixmap. | Store the pixmap reference at window-create time; tile into ClearArea via CGContext.drawTiledImage. |
| PolyRectangle (67) | line-style, cap-style, join-style, function, plane-mask, fill-style, subwindow-mode, clip-mask | Identical chain to PolyLine. `handlePolyRectangle:2126` reads foreground/lineWidth/clipRectangles/dashes/dashOffset; bridge `CocoaWindowBridge.swift:724 drawPolyRectangle` calls `ctx.stroke(rect)` with no cap/join/function. | XOR perimeter stroke is the classic rubber-band rectangle. The very thing xfig/GIMP/most-drawing-apps do. Also Athena Command's pressed-state border. | load-bearing for function (rubber-band rect — every drawing client); rest latent. | Same as PolyLine. |
| PolyPoint (64) | ALL | Not parsed in `Sources/Framer/` (grep returns only the opcode-name string at `OpcodeNames.swift:66`). Not dispatched in `ServerSession.swift`. Falls through to unhandled-opcode logging path. | Any client drawing single-pixel dots. xfig point markers, xeyes pupil center pixel in some configs, scatter-plot points. | load-bearing — xfig, xmgrace, any plotting client. Per the feature_test_apps memory, x11perf and any plotter trips this. | Add Framer parser for opcode 64; handler that calls a `drawPolyPoint` bridge method using CGContext.fill of 1×1 rects. |
| CopyPlane (63) | ALL | Not parsed in Framer; not dispatched. | Used to copy a single bit-plane from a depth-N source to a depth-M destination, painting foreground where the plane has 1-bits and background where 0. The standard way to render cursor masks, icon masks, and stipple-based glyph fonts from bitmap pixmaps. | load-bearing — every client using bitmap pixmaps for icons (twm, xclock-with-bitmap-face, Motif icon buttons). | Needs pixmap pixel store first (same prerequisite as PutImage). Then add Framer parser + handler + bridge method. |
| PutImage (72) | function, plane-mask, fg, bg, subwindow-mode, graphics-exposures, clip-mask | `ServerSession.swift:3859 putImage` silent-drops after argument validation. The GC components are unread because we never decode the pixel data. | Any client uploading bitmap data — xterm's bell-flash uses XYBitmap PutImage; Athena's pixmap widgets, Motif's icon buttons all use it. | load-bearing — already ledgered as the pixmap-store SHORTCUT, but each missing GC component is its own bug when that lands. | Implement pixmap pixel store; PutImage decodes per format (Bitmap = XYBitmap with depth=1 → fg/bg fill; XYPixmap = N planes assembled; ZPixmap = raw bytes). Plumb all GC components through. |

## Cross-cutting findings

- **GCState is the choke point**: `GCState.swift:32-52` declares only 9 fields
  (foreground, background, lineWidth, fillRuleEvenOdd, font, function,
  clipRectangles, dashes, dashOffset). The 14+ GC components named by the X
  spec for various drawing opcodes simply don't have a field. The
  value-list parser stores them in `GCEntry.values` (so they survive
  GetGCValues round-trip — stored-but-inert) but `materialise` never reads
  them.
- **WindowBridge signatures are the second choke point**:
  `WindowBridge.swift:226-291` has no parameter for line-style, cap-style,
  join-style, fill-style, tile, stipple, ts-origins, subwindow-mode,
  plane-mask, graphics-exposures, clip-mask, or arc-mode. Even if GCState
  grew the fields, the protocol between session and bridge would need a
  matching extension. Adding parameters to every draw method is painful;
  a `GCRenderState` struct passed by reference would be the right shape.
- **The corpus we host doesn't exercise these gaps**: xterm uses solid
  foreground, default cap/join/line-style, no tile/stipple, GXcopy
  (occasional GXxor for selection — and yes, we miss that). xcalc/xclock
  are similar. dt-apps DO use FillStippled for the button chrome (already
  parked in `INVESTIGATION_MOTIF_INPUT.md` as the "Motif PushButton chrome
  doesn't render" issue — this audit is identifying the actual mechanism:
  no stipple plumbing).

## The pattern

The shortcuts are uniform across the category, not per-opcode: every drawing
handler reads the same ~9 GCState fields and passes a fixed subset to the
bridge. Every other GC component the spec names is either stored-but-inert
(planeMask, lineStyle, capStyle, joinStyle, fillStyle, tile, stipple,
ts-origins, subwindowMode, graphicsExposures, clipMask, arcMode, dashList
via SetDashes is the only "extended" storage) or never stored at all. The
fix-shape is therefore architectural: a unified `GCRenderState` materialised
once per draw and threaded through every bridge method, with bridge-side
honoring driven by capability dispatch (CG blend modes for `function`,
CGPattern for tile/stipple, CGContext.clip for clip-mask after pixmap pixel
store lands). The one load-bearing miss for our actual target clients is
`function` being stored but dropped at every handler except
PolyFillRectangle — XOR rubber-banding is universal in classic X drawing
apps and we have it sitting on GCState ready to plumb.
