# Rendering design

How the Swift X server uses the macOS graphics stack. The point of this file is consistency: every opcode implementation should make the same architectural choices about which Mac primitive to reach for, so we don't end up with PolyLine using one approach and PolySegment using another.

Two sections:

1. **Architectural commitments** — the load-bearing decisions all opcodes follow.
2. **Per-opcode Mac primitive mapping** — best-guess for each opcode, verify on implementation.

## Architectural commitments

These are the cross-cutting rules. Every drawing-related opcode follows them. Changes here are real architectural changes and should be flagged in `DECISIONS.md`.

### 1. Graphics framework: Core Graphics throughout

All rendering goes through `CGContext`. No direct Metal, no MetalKit, no SpriteKit. CG is sufficient for the X11 R5/R6 protocol, integrates cleanly with NSView, and keeps the rendering layer comprehensible. Metal is a v2+ optimization for performance-sensitive apps (xterm scrolling, video).

### 2. Pixmap backing: CGBitmapContext

X11 pixmaps are backed by `CGBitmapContext` over a manually-allocated bitmap buffer. Not `CGImage` (immutable), not `IOSurface` (overkill, GPU-shared, more machinery than we need).

Rationale: pixmaps need to be written *and* read (for `GetImage`, for `CopyArea` from pixmap to window). They support arbitrary depths (1-bit for icons and stipples, 8-bit for PseudoColor, 24-bit for TrueColor). `CGBitmapContext` gives all of that with a known memory layout we control.

The bitmap pixel format is always **32-bit ARGB on the Mac side**, regardless of what depth the X11 client thinks it's drawing into. We translate at the boundary: AllocColor pixels resolve to 32-bit ARGB at draw time. PutImage with depth=1 expands to 32-bit. GetImage compresses back to whatever depth the request asks for.

### 3. Window backing: CGBitmapContext + NSView blit

Each top-level X window has an associated CGBitmapContext (the "window backing store"). All drawing requests against any X window in that subtree write into the top-level's backing context, clipped against the X window's geometry.

The NSView's `draw(_:)` blits the dirty rect of the backing context to the screen via `CGContext.draw(image:in:)`. Mark dirty rects via `setNeedsDisplay(_:)` whenever a drawing request modifies pixels.

Not using `CALayer.contents` directly. Not using a per-X-window NSView. The "single NSView per top-level X window" decision (in `PRODUCT_2_SERVER.md`) means the X subtree is internal to the server.

### 4. GC state: Swift struct, applied fresh each draw

GCs are stored as a Swift struct (`GCState`) with fields for foreground, background, line_width, line_style, cap_style, join_style, fill_style, fill_rule, font, clip_rectangles, dashes, etc. Most modern apps only use a few attributes; we store all of them but only apply what the request needs.

At the start of each drawing request, apply the relevant GC attributes to the target `CGContext`: `setStrokeColor`, `setFillColor`, `setLineWidth`, `setLineDash`, `clip(to:)` if clip rects are set, etc. Do not try to maintain a "current GC" persisted on the CGContext between requests. Apply fresh each time. This is slightly more work per draw but eliminates a whole class of state-leak bugs.

### 5. Color: `[pixelValue: CGColor]` lookup table

PseudoColor depth-8 is exposed but not implemented as a real palette. AllocColor returns a synthesized monotonic uint32 pixel value; the server caches `[pixel: CGColor]` keyed on the colormap. At draw time, when a GC's foreground refers to a pixel, look it up to get the CGColor.

For TrueColor depth-24, the pixel value is `(R << 16) | (G << 8) | B`. No lookup needed; pack/unpack at draw time.

### 6. Drawing thread: main thread for v1

All rendering work runs on the main thread. CGContext is not thread-safe in general, and putting CG calls on the main thread keeps the model simple. The per-client connection thread parses and dispatches requests; drawing dispatches over to main via `DispatchQueue.main.async`.

Off-main rendering with blit-on-flush is a v2 optimization. Don't do it now.

### 7. Text rendering: Core Text with cell-snapping

Per `DECISIONS.md` 2026-05-07 and `SERVER_RESOLUTION_SCALING_AND_FONTS.md`: the server ships **no bitmap fonts**. Every X font request resolves to a scalable Mac font (Monaco / Helvetica Neue / Courier New / Andale Mono / Times New Roman / Symbol / Charter per the substitution table) rendered with Core Text. QueryFont reports integer logical cell metrics; rendering produces glyphs at exact device-pixel positions with subpixel positioning OFF (non-negotiable for cell-aligned rendering).

This isn't exercised by xclock (which doesn't render text); xterm is where it matters.

See `SERVER_RESOLUTION_SCALING_AND_FONTS.md` for the substitution table, cell-sizing math, italic policy, and xlsfonts synthesis plan. That doc is load-bearing — if you're touching anything text-related, read it first.

### 8. Coordinate system: NSView is flipped

X11 origin is top-left with y growing down. NSView's default origin is bottom-left with y growing up. Use a flipped NSView subclass (`isFlipped = true`) so X11 coordinates pass through with no transform. Apply the same transform to backing-store CGContexts via `CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -height)` so the bitmap's pixel order matches the visible top-left convention.

### 9. Clipping: CGContext.clip enforces X window subregion

When drawing into a top-level NSView's backing context against an X subwindow, set the CGContext's clip to the X subwindow's rect (in top-level coords) before drawing, and pop it after. This is how the "single NSView per top-level X window with internal X subtree" model works.

GC `SetClipRectangles` adds an additional clip from the GC; intersect with the X window clip.

### 10. Drawing is immediate-mode

Each drawing request directly writes pixels into the target's backing CGContext. No display lists, no retained scenes, no replay buffers. This matches X11's mental model: a drawing request is a state-changing side effect, not an entry in a scene graph.

The single deferred operation is `setNeedsDisplay(_:)` on the NSView, which coalesces many small draws into one screen flush per refresh cycle. Cocoa handles that for us.

### 11. Display scaling: logical vs device coordinates

Two coordinate systems: **logical** (what the X protocol sees) and **device** (what gets drawn). The boundary is the protocol/render layer — neither system leaks past there.

- Logical-root size and integer scale factor are computed at startup from `NSScreen.main` per the preset table in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Immutable for the session in Phase 1; user-overridable in Phase 2; runtime-adjustable in Phase 4 via XRandR.
- The rendering layer scales logical → device via a `CGAffineTransform` applied to the backing CGContext, so opcodes can pass logical coordinates straight through.
- Three independent scaling planes per the spec: **geometry** (free fractional, both for window edges and pixmap sizes), **stroke** (snapped to integer device pixels for crisp lines), **font** (snapped to integer point sizes for clean Core Text hinting). Plane 2 lands as `CocoaWindowBridge.applyStrokePlane(_:clientLineWidth:)`, called from `drawPolySegment` / `drawPolyLine`. The X11 protocol uses pixel-center addressing — `XDrawLines((x,y) → (x+w-1,y))` is expected to render w pixels with both endpoints inclusive — while CG uses grid-line addressing (integer paths land on pixel boundaries, strokes straddle two rows). The bridge translates the CTM by `+0.5 user-pixel` so X11 integer coordinates map to CG pixel centers; after that, a CG stroke at line-width 1 covers exactly the pixels X11 would have covered, regardless of integer scale factor. AA stays on. The doc's `+0.5 device-pixel for odd widths` recipe was a near-miss for this — it produces crisp strokes but lands them half a logical pixel off from where xterm expects, leaving cursor-fragment ghosts that `ImageText8` fills couldn't cover. The user-pixel shift puts every X11 pixel-address stroke entirely inside its nominal cell rect.
- Mouse events transform device → logical at the input dispatch boundary. The X client never sees device coordinates.
- Pixmaps (PutImage payloads) are stored at logical resolution. Upscale happens at composite time via `kCGInterpolationHigh` (Lanczos). Storing at device resolution would blow up memory and break GetImage round-trips.

This commitment is what makes the renderer "WAY better than XQuartz" possible. Anywhere we let device coordinates leak into the protocol layer, or vice versa, we've broken the architecture and the rendering quality bar gets compromised.

## Per-opcode Mac primitive mapping

Best guess. Verify on implementation. Each row says: which Mac primitive(s) this opcode resolves to, and any notes on subtleties. Update with what's actually used as we implement.

### Drawing requests

| Opcode | Name | Mac primitive | Notes |
| --- | --- | --- | --- |
| 61 | ClearArea | `CGContext.fill(rect)` with window's background color | Background color from window's BackPixel attribute |
| 62 | CopyArea | `CGContext.draw(CGImage, in:)` from src to dst | Source pixmap → CGImage; blit subrect |
| 63 | CopyPlane | Per-plane bitblt | Rare; defer until needed |
| 65 | PolySegment | `CGContext.strokeLineSegments(between:)` | Each segment is independent; CG primitive matches X11 semantics directly |
| 66 | PolyLine | `CGContext.beginPath()` + `move(to:)` + `addLine(to:)` × N + `strokePath()` | Connected line strip; `coordinate-mode` byte (0=origin, 1=previous) determines absolute vs delta |
| 67 | PolyRectangle | `CGContext.stroke(rects)` | Multiple rects in one call |
| 68 | PolyArc | `CGContext.addArc(center:radius:startAngle:endAngle:clockwise:)` + `strokePath()` | Angles in 64ths of a degree per X11 spec; convert to radians |
| 69 | FillPoly | `CGContext.beginPath()` + `move(to:)` + `addLine(to:)` × N + `closePath()` + `fillPath(using:)` | Winding rule from request: `Convex`/`NonConvex` use `.winding`, `Complex` uses `.evenOdd` per X11 fill_rule |
| 70 | PolyFillRectangle | `CGContext.fill(rects)` | Same primitive as PolyRectangle but filled |
| 71 | PolyFillArc | `CGContext.addArc(...)` + `fillPath()` | Pie-slice or chord depending on GC.arc_mode |
| 72 | PutImage | `CGImage` from request bytes + `CGContext.draw(image:in:)` | Format conversion: zPixmap → 32-bit ARGB; xyBitmap (depth 1) → 32-bit with foreground/background expansion; xyPixmap rare, defer |
| 73 | GetImage | `CGContext.makeImage()` (or read backing-store bytes directly) | Reverse of PutImage; serialize to requested format/depth |
| 74 | PolyText8 | Core Text `CTLine` + `CTLineDraw` | Multiple text items with embedded font/delta changes |
| 76 | ImageText8 | Fill background rect, then `CTLine` draw | ImageText draws bg + text in one logical op |

### Resource creation / state

| Opcode | Name | Mac primitive | Notes |
| --- | --- | --- | --- |
| 53 | CreatePixmap | `CGContext(data:width:height:bitsPerComponent:bytesPerRow:space:bitmapInfo:)` (CGBitmapContext) | Always 32-bit ARGB on the Mac side regardless of requested depth |
| 54 | FreePixmap | release the CGContext + its backing buffer | |
| 55 | CreateGC | allocate Swift GCState struct | No CG action |
| 56 | ChangeGC | mutate GCState | No CG action |
| 60 | FreeGC | release GCState | |
| 84 | AllocColor | allocate pixel, populate `[pixel: CGColor]` | CGColor in deviceRGB |
| 87 | StoreColors | mutate `[pixel: CGColor]` for existing entries | Rare; defer |

### Window operations (rendering-relevant)

| Opcode | Name | Mac primitive | Notes |
| --- | --- | --- | --- |
| 1 | CreateWindow | If parent=root, create NSWindow + NSView (flipped) + backing CGBitmapContext | Otherwise just internal X tree node |
| 8 | MapWindow | NSWindow.makeKeyAndOrderFront / setNeedsDisplay | Synthesize MapNotify, ConfigureNotify, Expose |
| 12 | ConfigureWindow | NSWindow.setFrame for top-level; resize backing CGBitmapContext if size changed | Synthesize ConfigureNotify and Expose for newly-revealed regions |
| 14 | UnmapWindow | NSWindow.orderOut | Synthesize UnmapNotify |

### Cursor (deferred)

| Opcode | Name | Mac primitive | Notes |
| --- | --- | --- | --- |
| 93 | CreateGlyphCursor | NSCursor substitution by X cursor name | Per `DECISIONS.md` deferred decision; map X cursor font index to nearest macOS cursor |
| 95 | FreeCursor | release cursor | |
| 96 | RecolorCursor | NSCursor doesn't support recoloring; ignore for v1 | |

(Add rows as opcodes get encountered.)
