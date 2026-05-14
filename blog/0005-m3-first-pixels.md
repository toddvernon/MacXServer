# Post 5: First pixels

**Date range**: May 7, 2026 **One-line elevator**: The clock face renders. PolySegment for the minute ticks,
FillPoly for the hands, PolyLine for outlines, all going through Core Graphics into a flipped CGBitmapContext.
xclock from u5 displaying correctly on the Mac with native chrome.

## What this post covers

Product 2 milestone M3 (and M3-part-b: live resize). The shift from "window opens but stays blank" to "X
drawing primitives produce pixels on the screen." Coordinate translation through a descendant subtree. The
single-NSView-per-top-level decision. Live verification against u5.

## Setting

M1 (protocol path) and M2 (NSWindow per top-level) shipped earlier the same day. The clock window is up on the
Mac but blank. The X client has sent its drawing requests, which the server has parsed and dropped. M3 turns
those drops into actual rendering.

## The drawing primitives xclock uses

Smallest set that gets a working clock:

- `PolySegment`. the 60 minute ticks
- `FillPoly`. the hour and minute hand bodies (convex polygons)
- `PolyLine`. hand outlines, dial details
- `ClearArea`. erase-before-redraw on resize

Plus `ConfigureWindow` on the non-top-level inner window (the child resize that happens when the outer
resizes).

Five drawing opcodes total. Everything bigger comes later (PolyText8, ImageText8, PolyFillRectangle, PolyArc,
CopyArea, PutImage).

## Sub-toplevel compositing: one NSView, many X windows

Post 1 laid the groundwork for this section: in X11, every button, scrollbar, label, and form is its own
window. xclock is one of the simplest X clients in existence and it still has TWO X windows. xcalc has
roughly thirty. quickplot has hundreds. The X server is expected to track all of them as first-class
objects with parents, children, event masks, geometry, properties, the works.

If you take that literally on macOS, every X button becomes an NSView. xcalc's keypad becomes a 30-NSView
hierarchy. quickplot becomes an NSView forest. AppKit's view layout system tries to "help" by managing
positions and sizes. Drag a button to a slightly-wrong place and AppKit thinks it's responsible for moving
it. Worse, every NSView has its own backing store at retina depth on a Studio Display, multiplied by the
number of X children. The memory math gets bad quickly and the performance is worse.

We don't do that. `DECISIONS.md` 2026-05-05: **one NSView per top-level X window.** All the child X windows
are tracked as abstract regions inside the server's `WindowTable`, with parent/child relationships and
geometry, but they don't have AppKit counterparts. Drawing requests against any X window in the subtree
translate to a coordinate-shifted draw against the top-level NSView's backing `CGBitmapContext`. The server
does its own clipping based on the subwindow's geometry. AppKit sees one window and one view per X
top-level, doesn't know children exist.

The implementation is straightforward. `ServerSession.topLevelAndOffset(for: drawable)` walks the parent
chain in `WindowTable`, sums offsets, returns the top-level and (dx, dy). Every drawing handler translates
the request coords by (dx, dy) before drawing. Coordinate translation is cheap; the parent chain is short;
it works.

What this costs us, honestly: we don't get free per-window visibility tracking. On a real Sun X server, when
one X window is obscured by another, the server tracks the obscured regions and the client gets accurate
Expose events for what needs redrawing and only that. Our flat-NSView model means we either Expose
everything (wasteful but always correct) or we synthesize visibility math ourselves (real engineering work,
not done yet). It also means certain Motif-internal optimizations that lean on per-subwindow visibility
don't work the way Motif expects. The Motif button-widget chrome rendering issue parked in Post 10 is
related: Motif's PushButton class assumes its subwindow chrome will get Expose events filtered through the
real X server's visibility tracking, and our flat model emits more Exposes than that. Motif's PushButton
takes the flood as "all of these need redrawing equally" and ends up not redrawing any of them.

That's a real cost, and we're carrying it as tech debt until we either implement visibility tracking
properly or convince ourselves it doesn't matter for the apps we care about. For xclock, xterm, xcalc, and
quickplot's graphing windows, the flat model is fine. For dt-button-widget chrome and a couple of corners
of Motif, it's not. The right answer is probably "implement visibility tracking later," not "give every X
child window its own NSView."

`CocoaWindowBridge` runs all CGContext drawing on the main thread, into a `FlippedXView` whose backing
`CGBitmapContext` uses top-left origin (per `RENDERING_DESIGN.md`). X coordinates are top-left origin;
AppKit is bottom-left; the flipped view bridges them.

TODD: it tool a while to get the coordinate system correct.  I recalled from 30 years earlier that the xwindow
coordinate system is a bit odd compared to other systems.  the few is [CLAUDE: add comparision to
modern coordinate systems, i feel like xwindows is a bit unsual and if so insert something about that]


## Coordinate translation

`ServerSession.topLevelAndOffset(for: drawable)` resolves a drawable (window or pixmap ID) to its top-level
ancestor and the (dx, dy) offset within. Walks the parent chain in `WindowTable`, sums offsets, stops at root.
Iteration cap of 32 to defend against malformed parent chains.

Every drawing handler does:
1. Look up the drawable's top-level and offset
2. Translate request-supplied coordinates by (dx, dy)
3. Resolve the GC's foreground pixel value to RGB16 via `ColorTable`
4. Call the bridge's draw method with the resolved values

The bridge doesn't know anything about X windows or pixel values. It just receives "draw at coords X with
RGB16 color."

## GC state

`GCState.materialise(from: GCEntry)` reads the raw mask+valueList stored on the GC and produces typed state:
foreground / background / line-width / fill-rule. Only the GC bits the drawing primitive needs are
materialised; the rest are dropped.

The mask+valueList wire format is decoded by the framer once per request. The materialiser runs on every draw
to pull current values. ChangeGC updates the entry's stored state, so subsequent draws see the new values.

## M3 part-b: live resize

Adding the resize path was its own substantial piece of work, in the same day. When the user resizes the macOS
window:

1. `NSWindowDelegate.windowDidResize` fires
2. We resize the FlippedXView's backing CGBitmapContext (preserving old pixels at top-left)
3. Update the top-level's geometry in `WindowTable`
4. Emit `ConfigureNotify` on the top-level with the new dimensions
5. The client responds by `ConfigureWindow`-ing its inner drawing window
6. The server emits `Expose` on descendants with ExposureMask, with the right region
7. The client redraws

Without step 4, xclock just sits at the original size while AppKit resizes its window. Without step 6,
xclock's inner window doesn't know to redraw. The live-resize path needed all six steps in correct order.

TODD: as i recall the first version of xclock we had working resized the image larger, the mac doing that
which made the resolution look bad.  I knew that wasn't xwindows doing it but the mac. That turned out
to be native nswindow behavior as i recall so we had to emit the correct feedback to the app so it would redraw]

`ResizeHandlingTests` covers the protocol-side path. Live verification against u5 caught a Y-flip bug at the
boundary that the test missed (the test compared bytes, not pixels).

## Pivotal moment

xclock running on u5, pointed at the Mac, the clock face rendering correctly on a native macOS window. Hour
hand, minute hand, 60 tick marks, no second hand. Resize the window with the macOS title-bar drag, the clock
face resizing live with it.

(Fact-check on the missing second hand: xclock by default has no second hand. The transcript at
`captures/xclock_transcript.md:153` confirms this and notes that `xclock -update 1` would enable one. The
captured Sun session didn't pass `-update 1`, so neither does the Mac side. Not a bug, a deliberate xclock
default.)

This is also the post where the "looks amazing at the right scale" feeling lands. Phase 1 of
`SERVER_RESOLUTION_SCALING_AND_FONTS.md` shipped the same day as M3 (display-adaptive integer scaling at
startup), so the very first time xclock rendered, it rendered at a sensible logical resolution for the
Studio Display, not at 1x native pixels. The clock face was the right size next to a Safari window. Not
postage-stamp. The full scaling and font story is Post 6, but the basics were in place day one for visible
output.

TODD: [first-pixels emotional beat goes here. The "looked amazing and at the proper scale, coexisted with
Mac windows" sentiment that was in the Post 3 draft is the right beat for THIS post, not Post 3. Pull it
into your own voice.]

Product 2 now had a working clock face on the Mac. Everything from this point forward is more X clients on top
of the same foundation: the protocol path, the bridge, the drawing primitives, the resize handling.

## What Todd should add

- The "first pixels" moment.
- The Y-flip bug discovery story (RENDERING_DESIGN.md mentions a flipped view; the bug was somewhere in the
  X/AppKit coordinate handoff).

TODD: i commented on this above

- Why xclock specifically as the M3 target. The clock face is geometrically distinctive (ticks, hands at
  angles, circular outline) so wrong code paths produce visibly-wrong rendering, not "vaguely wrong."

TODD: commented in earlier article(s)

- The live-resize work specifically. It feels nearly free now but was a real concentration of small bugs.

TODD: mentioned above a bit.

- The "I have a working X server" feeling vs "I have a working DEMO."

[CLAUDE addressed Todd's "rationalize with earlier article" note: the split between Posts 3, 4, 5 has been
clarified. Post 3 (M1) is "the protocol stayed connected" with no visible UI. Post 4 (M2) is "a real
NSWindow appears, even blank." Post 5 (M3, this post) is "pixels render and resize works, and Phase 1
scaling makes it look right at modern resolution." Three distinct beats now, instead of an over-shared
"first window" framing. Todd to add the working-X-server-vs-demo voice here in this post; that judgment
call lands at M3, not earlier.]


## Anchors for fact-check pass

- Files: `PRODUCT_2_SERVER.md` (M3 section), `RENDERING_DESIGN.md`,
  `Sources/SwiftXServerCore/CocoaWindowBridge.swift` (FlippedXView, draw methods),
  `Sources/SwiftXServerCore/GCState.swift`, `Tests/SwiftXServerCoreTests/DrawingDispatchTests.swift`,
  `Tests/SwiftXServerCoreTests/ResizeHandlingTests.swift`
- Commits: `4a0dd24` 2026-05-07 M1-M3 ship, `d55a5bd` 2026-05-07 M3 part-b close-out (live NSWindow resize)
- topLevelAndOffset: `Sources/SwiftXServerCore/ServerSession.swift:1498`
- xclock transcript: `captures/xclock_transcript.md`
- The captured xclock corpus: 2 windows, 2 colors, 4 GCs (+ initial + 2 transient), 2 pixmaps, 1 font, 4+
  atoms beyond the 68 predefined

## Working title alternatives

- "M3: the clock face renders"
- "First pixels"
- "Five drawing opcodes and a working clock"
