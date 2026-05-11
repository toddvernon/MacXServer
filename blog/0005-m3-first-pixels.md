# Post 5: First pixels (M3)

**Date range**: May 7, 2026
**One-line elevator**: The clock face renders. PolySegment for the minute ticks, FillPoly for the hands, PolyLine for outlines, all going through Core Graphics into a flipped CGBitmapContext. xclock from u5 displaying correctly on the Mac with native chrome.

## What this post covers

Product 2 milestone M3 (and M3-part-b: live resize). The shift from "window opens but stays blank" to "X drawing primitives produce pixels on the screen." Coordinate translation through a descendant subtree. The single-NSView-per-top-level decision. Live verification against u5.

## Setting

M1 (protocol path) and M2 (NSWindow per top-level) shipped earlier the same day. The clock window is up on the Mac but blank. The X client has sent its drawing requests, which the server has parsed and dropped. M3 turns those drops into actual rendering.

## The drawing primitives xclock uses

Smallest set that gets a working clock:

- `PolySegment`. the 60 minute ticks
- `FillPoly`. the hour and minute hand bodies (convex polygons)
- `PolyLine`. hand outlines, dial details
- `ClearArea`. erase-before-redraw on resize

Plus `ConfigureWindow` on the non-top-level inner window (the child resize that happens when the outer resizes).

Five drawing opcodes total. Everything bigger comes later (PolyText8, ImageText8, PolyFillRectangle, PolyArc, CopyArea, PutImage).

## Single NSView per top-level

`DECISIONS.md` 2026-05-05. The X subtree is internal to the server. Drawing requests against any X window in that subtree render into one NSView (the top-level NSWindow's content view), clipped against subwindow geometry.

Why not one NSView per X window: child X windows are abstract (just regions with separate event masks and properties). Translating to NSView per X window means complex view hierarchies, conflicting layout systems, and AppKit thinking it should manage layout for us. Keep it flat: one NSView, the server clips internally.

`CocoaWindowBridge` runs all CGContext drawing on the main thread, into a `FlippedXView` whose backing CGBitmapContext uses top-left origin (per `RENDERING_DESIGN.md`). X coordinates are top-left origin; AppKit is bottom-left; the flipped view bridges them.

## Coordinate translation

`ServerSession.topLevelAndOffset(for: drawable)` resolves a drawable (window or pixmap ID) to its top-level ancestor and the (dx, dy) offset within. Walks the parent chain in `WindowTable`, sums offsets, stops at root. Iteration cap of 32 to defend against malformed parent chains.

Every drawing handler does:
1. Look up the drawable's top-level and offset
2. Translate request-supplied coordinates by (dx, dy)
3. Resolve the GC's foreground pixel value to RGB16 via `ColorTable`
4. Call the bridge's draw method with the resolved values

The bridge doesn't know anything about X windows or pixel values. It just receives "draw at coords X with RGB16 color."

## GC state

`GCState.materialise(from: GCEntry)` reads the raw mask+valueList stored on the GC and produces typed state: foreground / background / line-width / fill-rule. Only the GC bits the drawing primitive needs are materialised; the rest are dropped.

The mask+valueList wire format is decoded by the framer once per request. The materialiser runs on every draw to pull current values. ChangeGC updates the entry's stored state, so subsequent draws see the new values.

## M3 part-b: live resize

Adding the resize path was its own substantial piece of work, in the same day. When the user resizes the macOS window:

1. `NSWindowDelegate.windowDidResize` fires
2. We resize the FlippedXView's backing CGBitmapContext (preserving old pixels at top-left)
3. Update the top-level's geometry in `WindowTable`
4. Emit `ConfigureNotify` on the top-level with the new dimensions
5. The client responds by `ConfigureWindow`-ing its inner drawing window
6. The server emits `Expose` on descendants with ExposureMask, with the right region
7. The client redraws

Without step 4, xclock just sits at the original size while AppKit resizes its window. Without step 6, xclock's inner window doesn't know to redraw. The live-resize path needed all six steps in correct order.

`ResizeHandlingTests` covers the protocol-side path. Live verification against u5 caught a Y-flip bug at the boundary that the test missed (the test compared bytes, not pixels).

## Pivotal moment

xclock running on u5, pointed at the Mac, the clock face rendering correctly on a native macOS window. The second hand ticking. Resize the window with the macOS title-bar drag, the clock face resizing live with it.

That's the moment Product 2 went from "exists" to "real." Everything since has been "more X clients."

## What Todd should add

- The "first pixels" moment.
- The Y-flip bug discovery story (RENDERING_DESIGN.md mentions a flipped view; the bug was somewhere in the X/AppKit coordinate handoff).
- Why xclock specifically as the M3 target. The clock face is geometrically distinctive (ticks, hands at angles, circular outline) so wrong code paths produce visibly-wrong rendering, not "vaguely wrong."
- The live-resize work specifically. It feels nearly free now but was a real concentration of small bugs.
- The "I have a working X server" feeling vs "I have a working DEMO."

## Anchors for fact-check pass

- Files: `PRODUCT_2_SERVER.md` (M3 section), `RENDERING_DESIGN.md`, `Sources/SwiftXServerCore/CocoaWindowBridge.swift` (FlippedXView, draw methods), `Sources/SwiftXServerCore/GCState.swift`, `Tests/SwiftXServerCoreTests/DrawingDispatchTests.swift`, `Tests/SwiftXServerCoreTests/ResizeHandlingTests.swift`
- Commits: `4a0dd24` 2026-05-07 M1-M3 ship, `d55a5bd` 2026-05-07 M3 part-b close-out (live NSWindow resize)
- topLevelAndOffset: `Sources/SwiftXServerCore/ServerSession.swift:1498`
- xclock transcript: `captures/xclock_transcript.md`
- The captured xclock corpus: 2 windows, 2 colors, 4 GCs (+ initial + 2 transient), 2 pixmaps, 1 font, 4+ atoms beyond the 68 predefined

## Working title alternatives

- "M3: the clock face renders"
- "First pixels"
- "Five drawing opcodes and a working clock"
