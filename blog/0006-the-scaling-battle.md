# Post 6: The scaling battle (xterm pixel-perfect)

**Date range**: May 7 - May 9, 2026 (the design pass + two implementation iterations) **One-line elevator**: I
really wanted X windows to appear the PROPER SIZE on a modern Mac. Not 2 inches wide on a Studio Display the
way XQuartz renders them. Not blurry pixel-doubled the way naive scaling produces. Pixel-perfect at the scale
a 1996 user would have seen, on a 2026 Retina display. The whole project pivots on getting this right, and
xterm is the acid test.

## What this post covers

The first foundational design driver of the project. Why screen scaling and font policy is the largest single
piece of design work in swift-x, why xterm specifically is the test case that has to pass before anything else
matters, and the iteration arc from "pick a scale factor at startup" through "cell-fits-font" that took two
passes to get right.

## Setting

xclock works (M3 shipped same week). Five drawing primitives are wired through the bridge. The next client is
xterm, which is mostly text rendering and not much else. The architectural question that's been sitting in the
back of my head since day one is now the front-and-center blocker: how does this thing render at modern
resolution.

The XQuartz failure mode I've been pointing at since Post 1 is concrete here. Run an X client through XQuartz
on a 5K Studio Display, the window comes up at roughly two inches wide. xterm assumes pixel coordinates the
way a 1280x1024 cgsix-equipped SPARCstation had them. Modern displays are 200+ pixels per inch. Same
coordinates, much smaller window. XQuartz doesn't do anything about this. swift-x has to.

## This is design driver number one

Post 1 introduced the two foundational design drivers: xterm pixel-perfect on modern hardware, and Motif
clients fully functional. This post is the first of those. The scaling work shaped the whole rendering layer
(three planes, integer scale, cell-snapping, no bitmap fonts). The Motif story is Posts 9 and 10.

The visible bar for "did you actually beat XQuartz" is exactly this comparison, on this client, at this scale.
If xterm doesn't look right, nothing else about the project matters.

## The 2x / 3x / infinite scale debate

The first question with modern displays is: what scale factor.

The options I considered:

- **1x native.** Rejected. xterm is 2 inches wide on a Studio Display, unreadable. Same problem XQuartz has.
- **Fixed 2x.** OK for older Retina MacBooks (about 220 DPI), too small for Studio Display, way too small for
  4K displays.
- **Fixed 3x.** Right for Studio Display, too large for 1080p, mediocre for 4K.
- **Infinite (fractional) scale.** Like macOS does for arbitrary windowed apps. 1.5x for some displays, 2.7x
  for others. Rejected after thinking through what fractional scale does to cell-snapping math (see below).
- **Integer scale, picked per display from a preset table.** Chosen. 1080p picks 2x, Retina MacBook picks 2x,
  4K picks 3x, 5K Studio Display picks 3x at 1280x900 logical. All scale factors are integers; the logical
  resolution is whatever fits the device size at that integer scale.

The decisive argument for integer-only: cell-snapping. If the substitute font's natural cell size is 7x14
logical pixels at 3x scale, that's 21x42 device pixels. Glyphs land exactly on integer pixel boundaries.
Anti-aliasing has the headroom Core Text wants. The output looks like a proper terminal.

Fractional scale breaks this. At 2.7x scale, 7 logical pixels become 18.9 device pixels. Glyphs no longer land
on integer boundaries. Core Text's hinted advances disagree with the cell math. Cells get fudged. The "feels
bold" residue at 3x that we saw in the first pass (more on that below) is exactly this problem in a milder
form.

## The "no pixel fonts, scalable only" rule

X11 traditionally ships dozens of bitmap fonts at various sizes (8x13, 9x15, 10x20). Vintage Sun clients
reference these by XLFD pattern: `-misc-fixed-medium-r-normal--13-100-75-75-c-70-iso8859-1`. The natural
temptation when implementing a new X server is to ship the same bitmap fonts and serve them faithfully.

I rejected this. The whole point of the rendering doc is to take advantage of modern Mac rendering. Bitmap
fonts forfeit that. Scalable substitutes (Menlo, Monaco, SF Mono) hinted via Core Text at integer pointSize
are the path to a result that looks like a modern Mac app, not 1996.

The trade: clients ask for a specific XLFD pattern with a specific cell size. We respond with a scalable
substitute. The XLFD's named cell size becomes a hint, not a contract. The substitute's natural metrics drive
the actual cell.

That trade is non-trivial. Some clients (xfontsel, Motif text widgets) lay out widgets assuming the cell size
in the XLFD is the cell size they'll get back from QueryFont. Disagreement between requested-cell and
returned-cell can break widget geometry. We accept that risk for the rendering quality.

## The three-plane decomposition

`SERVER_RESOLUTION_SCALING_AND_FONTS.md` defines three independent scaling planes. This is the load-bearing
architectural piece.

1. **Geometry plane.** Coordinates from the X protocol are logical. CGContext gets a transform that maps
   logical to device pixels at the integer scale factor. Drawing math (clip rectangles, polygon vertices, line
   endpoints) happens in logical coords. Pixel-snapping happens at the device-coord boundary.
2. **Stroke plane.** 1-pixel-wide lines need to land on integer device-pixel rows for crisp rendering. This is
   the half-pixel-shift problem: a stroke from (0, 5) to (10, 5) at 3x scale will smear across two
   device-pixel rows under antialiasing unless we shift by +0.5 user-pixel in the stroke plane only. Geometry
   plane stays unshifted; stroke plane gets the shift. The cursor-outline bug fix (commit `c0a9ecb`) was
   discovering this hard way.
3. **Font plane.** CTFont at the natural pointSize for the substitute family at this scale. Glyph advances
   come from Core Text's hinted metrics, not from the X protocol's requested cell. The font plane drives the
   cell, not the other way around.

Three planes, three coordinate systems, three different rules for how they interact with the device-pixel
grid. Sounds complex; in practice the abstraction is the thing that keeps rendering quality coherent across
opcodes.

## Cell-snapping pass 1 (the "feels bold" residue)

The first version of Phase 1 (commits `11ccde3` 2026-05-07, `c127e67` 2026-05-07) drove Monaco at fractional
pointSize to force-fit a cell width derived from the XLFD's hint. xterm at 3x rendered correctly geometrically
but had a substancial "feels bold" residue.  Perfect but weirdly bold.

The cause: forcing Monaco to a non-natural pointSize gave it hinted advances that didn't quite match our
forced cell width. Anti-aliasing fringe smeared asymmetrically across the gap, producing the bold-feeling
effect. The eye registered it as "something's off" before the conscious mind could articulate what.

I tried `setShouldSmoothFonts(false)` and various metrics-tightening fixes. Each one helped slightly. None
eliminated the residue.

## Cell-snapping pass 2 (cell-fits-font)

Commit `3244998` 2026-05-09 with the design fix in `DECISIONS.md` 2026-05-09 entry "Cell-fits-font final
rule":

- Use integer pointSize, not fractional.
- Derive cell width from CTFont's natural horizontal advance.
- Derive cell height from CTFont's ascent + descent.
- The XLFD's requested cell becomes a hint we use to PICK pointSize, but once chosen, the font's natural
  metrics drive the cell.

Net result: xterm at 3x looks like a proper terminal. No bold residue, glyphs land on integer pixel grid, the
eye doesn't fight what it's seeing. The previous "force the cell" rule is gone.

`XTERM_FONT_QUALITY.md` is the empirical alias map that came out of this pass. Which Mac font substitutes for
which XLFD pattern, at which pointSize. Documents the actual decisions Core Text and I converged on after the
second pass.

## The cursor-outline ghost (a bug in the rendering doc)

A small thing that consumed real time and ended up being a story about the design doc as a living artifact
rather than a frozen spec.

xterm draws its cursor as a filled rectangle in the bg color (over the glyph in fg color) when focused, and as
an outlined rectangle when unfocused. The outlined version was rendering with cursor-fragment ghosts: faint
horizontal lines at top and bottom of the cursor that shouldn't be there.

Root cause is in commit `c0a9ecb` 2026-05-08's message, which is more concrete than the previous draft of
this section: **X11 uses pixel-center addressing**. `XDrawLines` from `(x, y)` to `(x+w-1, y)` hits exactly
`w` pixels, both endpoints inclusive. **Core Graphics uses grid-line addressing**. Integer paths sit on
pixel BOUNDARIES, and a 1-pixel stroke straddles two rows. The two conventions are off by half a pixel from
each other. Result: every stroked rect left an antialiased ghost row half a logical pixel outside its top
and bottom edges, smeared across the next cell. xterm's hollow-cursor outline bled past the cell boundary,
and the ImageText8 bg-fill on the next focus change couldn't cover the ghost (it was outside the cell the
fill knew about).

The fix is one line: `CTM translateBy(0.5, 0.5)` in user space before stroking, inside `drawPolySegment` and
`drawPolyLine`. After that, X11 integer pixel coordinates map to CG pixel centers, and a 1-pixel stroke
covers exactly the pixels X11 would have at any integer scale factor. AA stays on so xclock's hands keep
their diagonal smoothing.

Important nuance: the shift goes on stroke, NOT on fill. `FillRectangle` and `FillPoly` already work because
filled regions cover full pixels by their nature. Strokes are the path-vs-pixel-center mismatch. So the
original Xlib intuition that "DrawRectangle and FillRectangle have different rules" is right about there
BEING different rules, but not quite about what they are: it's not really a fill-vs-outline issue, it's a
pixel-addressing-convention issue that only stroke triggers.

The rendering doc had specified the three planes but didn't specify the half-pixel shift on stroke. The bug
was in the doc, not just the code. The fix updated both (`RENDERING_DESIGN.md` records the deviation from the
original recipe and why). This is a small case of why the doc has to be a living artifact, not a frozen
spec.

## Pivotal moment

Side-by-side: XQuartz xterm and swift-x xterm on the same Studio Display, both at default settings. XQuartz:
tiny, bitmap-fonts, the cursor jumpy. swift-x: properly-sized, anti-aliased scalable font, crisp lines. The
single visual comparison that justifies the project.

## What Todd should add

- The "I wanted X windows to appear the proper size on new hardware" framing in voice. This is YOUR specific
  bar; not a generic technical claim.

TODD: xterm is the number 1 used app it has to be perfect

- The XQuartz comparison in personal terms. What does it feel like to use XQuartz daily? What's the specific
  moment that made you give up on it?

TODD; the scaling is deal killer for me.  It looks fine at 1x scaling but everything is postage stamp.

- The 2x/3x/infinite debate in conversation form. The going-back-and-forth, the moment "integer only" became
  obviously right.

TODD: i recall a second opion i got from ChatGPT.  Im not sure how that played into the final design but it
caused a lot of discussion. We should include that in this section one way or another.

- The "no pixel fonts" rule in voice. This is a strong opinion and deserves the personal angle: why
  scalable-only matters to you specifically.

TODD: shipping pixel fonts was a deal killer.  i got back to iterm2.  They kill it on readability an great
looking terminal.  But its kind of an easier problem.  They aren't trying to make old rendering calls look
good they have complete control over rendering.  pixel fonts a just giving up in my mind.

- The xterm-as-acid-test argument. Why xterm. The "simplest app protocol-wise but the one everyone looks at"
  framing is yours and should be in the post.

TODD: said before, most poeple that use classic unix workstation spend most of their time in xterm.  everything
else is candy.  xterm makes or breaks the project for me.  I can ship an xterm render  with short cuts 
thats pretty cool, or go the extra mile and make a modern xserver that uses the latest graphics packages
from apple.

- The cursor-outline bug as a "bug in the rendering doc" story. The doc-as-living-artifact framing.

TODD: as a guy that did a lot of xlib programming a long time ago it was kind of obvious that rect fills and
rect draws had different rules.  rect fills, filled a rectagle, rect draw draw the outline of the rectangle and
that appeared to me to be the problem.

[CLAUDE fact-check: your intuition pointed at the right area (fill and stroke ARE governed by different
rules in any pixel-accurate 2D system), but the specific X11 vs CG difference is more pinpoint than the
fill-vs-outline framing suggests. X11 addresses pixel CENTERS (a 1-pixel stroke from (0,0) to (10,0) hits
the row of pixels at y=0). CG addresses grid LINES between pixels (the same path at user-space y=0 sits ON
the boundary between two pixel rows and the antialiased stroke smears across both). The fix is a half-pixel
CTM translate that goes ONLY on stroke paths, not on fills. Fills don't need it because filled regions
cover full pixels by their nature. So the "rect fills and rect draws have different rules" line is true,
but the rule itself is "stroke needs a half-pixel shift, fill doesn't" rather than "they're conceptually
different operations." Updated the main body of this section above to reflect the actual mechanism. You may
want to incorporate the pixel-center-vs-grid-line framing in your final voice — it's the kind of detail
that lands for retro-Unix readers who remember Xlib's pixel-counting quirks.]

## Thread anchor: protocol vs implementation

This post is where "implement the protocol with 2026 technology" becomes most visible. The xterm binary on the
Sun is sending `ImageText8` requests with XLFD font names and 8-bit string payloads. That's the protocol
surface, unchanged since 1989. Our job is to render those bytes with Core Text, with cell-snapping, with
display-adaptive scaling, with Retina-quality anti-aliasing. The protocol stayed the same; the rendering
became a Mac app instead of a 1996 cgsix framebuffer driver. The whole rendering-and-fonts doc is what happens
when you take the protocol's commands and ask "what would a Mac do."

TODD: this post is the foundational scaling unlock in the series and its hard to explain, we might need more
basic detail to make it land.

## Anchors for fact-check pass

- Files: `SERVER_RESOLUTION_SCALING_AND_FONTS.md` (the design doc), `XTERM_FONT_QUALITY.md` (empirical alias
  map), `RENDERING_DESIGN.md` (per-opcode mapping), `DECISIONS.md` 2026-05-09 entry "Cell-fits-font final
  rule", `Sources/SwiftXServerCore/CocoaWindowBridge.swift`
- Commits in order: `3efabad` 2026-05-07 "Adopt SERVER_RESOLUTION_SCALING_AND_FONTS as the rendering spec",
  `11ccde3` 2026-05-07 Phase 1.A-C display-adaptive integer scaling, `c127e67` 2026-05-07 Phase 1.D-F XLFD
  parser + font resolver + ImageText8, `b28eaef` 2026-05-07 Phase 1.G ListFonts + Xlib startup replies,
  `7bdb74c` 2026-05-07 Phase 1 wrap text orientation fix, `c0a9ecb` 2026-05-08 stroke +0.5 CTM shift,
  `606f889` 2026-05-08 cell-alias fit-to-cell, `3244998` 2026-05-09 cell-fits-font integer pointSize
- The preset table: per-display logical resolution and scale factor in ServerConfig
- The empirical XLFD alias map: which X font patterns map to which Mac fonts at which pointSize

## Evidence assets to gather (post-week)

- Side-by-side screenshot: XQuartz xterm and swift-x xterm at default settings on the same Studio Display. The
  cornerstone visual for the entire series.
- Closeup of one xterm cell on each: shows the antialiasing difference and the cell-snap precision.
- Same xterm with xclock visible behind it: shows the antialiased curves on the analog clock face on swift-x
  vs the jagged XQuartz version.

## Working title alternatives

- "Pixel-perfect xterm on a Retina Mac"
- "Why xterm has to be right first"
- "The scaling battle"
- "What it actually takes to render an X client at modern resolution"
