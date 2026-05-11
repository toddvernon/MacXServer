# Post 6: Live xterm, fonts, scaling

**Date range**: May 7 - May 8, 2026
**One-line elevator**: xclock proved the X protocol path works. xterm proved we can render TEXT, which means the rendering doc has to actually mean something. Phase 1 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md` ships: display-adaptive integer scaling, Core Text scalable substitutes for X core fonts, ImageText8 + PolyFillRectangle rendering. Plus the cell-snapping math that took two passes to get right.

## What this post covers

The shift from "xclock renders five drawing primitives" to "xterm from a real Sun runs as a daily-usable terminal." Phase 1 of the rendering doc. Cell-snapping. Cursor outlines. Live verification, font tuning, the iteration loop with u5 as ground truth.

## Setting

xclock works. The five drawing primitives are wired through the bridge. Text isn't drawn yet because xclock doesn't use text. The next client is xterm, which is mostly text and not much else.

## Thread anchor: protocol vs implementation

This post is where "implement the protocol with 2026 technology" becomes visceral. The xterm binary on the Sun is sending `ImageText8` requests with XLFD font names and 8-bit string payloads. That's the protocol surface, unchanged since 1989. Our job is to render those bytes with Core Text, with cell-snapping, with display-adaptive scaling, with Retina-quality anti-aliasing. The protocol stayed the same; the rendering became a Mac app instead of a 1996 cgsix framebuffer driver. Side-by-side with XQuartz is the visible payoff of the framing.

## What xterm needs that xclock doesn't

- `OpenFont` + `QueryFont` with actual metrics, not stubs
- `ImageText8` (text with bg fill) for terminal glyphs
- `PolyFillRectangle` for cell backgrounds
- `CopyArea` (same-window) for scroll
- Font resolution: XLFD parsing + substitution
- Keyboard input: NSEvent → X event with keysym mapping
- Color: ANSI escape sequences want pixels for the 16 ANSI colors; xterm allocates them via AllocColor

## The rendering doc adopted

`SERVER_RESOLUTION_SCALING_AND_FONTS.md` was sketched earlier but not load-bearing until xterm needed it. The doc defines:

- Display-adaptive integer scaling: Studio Display picks 1280×900 logical at 3x device pixels. 4K, MacBook Retina, 1080p each get appropriate presets.
- Three independent scaling planes: geometry / stroke / font. Lines stay crisp because the stroke plane is integer-aligned. Glyphs stay hinted because the font plane uses a CTFont with the natural pointSize.
- Core Text scalable substitutes for X core fonts. No bitmap fonts. XLFD's named cell becomes a hint, not a contract.
- Cell-snapping: the substitute font's metrics drive the cell, not the other way around.

Commit `3efabad` 2026-05-07: "Adopt SERVER_RESOLUTION_SCALING_AND_FONTS as the rendering spec." From this point forward, anything that touches font/scaling/cell math has to honor the doc or it's a bug.

## The cell-fits-font fix

The first version (Phase 1.A-C, 2026-05-07) drove Monaco at fractional pointSize to fit a forced cell size. That looked "almost right" but with a faint "feels bold" residue at 3x: asymmetric anti-aliasing fringe from the mismatch between Core Text's hinted advances and our forced cell width.

The second version (2026-05-09, `DECISIONS.md` entry): use integer pointSize, derive cell metrics from CTFont's natural advance + ascent + descent. The XLFD-requested cell becomes a hint. Drop the "force the cell" rule.

`XTERM_FONT_QUALITY.md` is the empirical alias map that came out of the second pass. Which Mac font substitutes for which XLFD pattern, at which pointSize, for which cell width.

Net result: xterm at 3x looks like a proper terminal. No bold residue, glyphs land on integer pixel grid, the eye doesn't fight what it's seeing.

## The cursor outline arc

A small thing that consumed real time. xterm draws its cursor as a filled rectangle in the bg color (over the glyph in fg color) when focused, and as an outlined rectangle when unfocused. The outlined version was rendering with cursor-fragment ghosts: faint horizontal lines at top/bottom of the cursor that shouldn't be there.

Root cause: the stroke plane needed a +0.5 user-pixel CTM shift to align strokes with the integer pixel grid. Without it, a 1-pixel-wide stroke smeared across two device-pixel rows under antialiasing. Commit `c0a9ecb` 2026-05-08: "Stroke plane: +0.5 user-pixel CTM shift kills cursor-fragment ghosts."

This was a "find the bug in the rendering doc, fix the bug in the rendering doc" episode. The doc had specified the three planes but didn't specify the half-pixel shift on stroke. Now it does.

## FocusIn / FocusOut and the cursor

xterm renders a filled cursor when focused, an outlined cursor when unfocused. That means the server has to emit FocusIn / FocusOut at the right moments. when the NSWindow becomes/loses key.

`FocusIn` arrived at `b238e11` 2026-05-07. With it, xterm's cursor properly switches between filled and outlined as the user clicks between windows.

## Color xterm

`b60ae9b` 2026-05-08: "Color xterm: ANSI colors render via parsed-per-bit GC state, plus Cmd-V paste." xterm sets up 16 ANSI colors at startup via AllocColor, then uses them as GC foreground/background. Each color escape switches the GC's foreground pixel value. The render path resolves the pixel back to RGB16 every draw.

Caveat from `b60ae9b`: ChangeGC was previously concatenating raw bytes onto the existing valueList; the materialiser kept reading the original CreateGC foreground; xterm's per-glyph color switches never landed. Fix: re-parse the partial valueList using the change's own mask and merge into the entry's per-bit dict, overwriting prior values.

## Live xterm

`65801b5` 2026-05-07: "Live xterm: keyboard, scrolling, resize all working." A real xterm session from u5 on the Mac, with input, output, scrollback (via CopyArea + NoExpose), and resize.

Live-resize stops white-flashing: `d50ec81` 2026-05-08: "defer bitmap realloc, layer-back the view, draw at native size." When the user grabs the title bar to resize, AppKit was reallocating the backing bitmap on every frame, briefly showing white. Defer realloc until live-resize ends; layer-back the view so AppKit composites at native resolution.

## Pivotal moment

The first usable xterm session: connect from u5, type, see output, scroll, resize, copy to Mac clipboard with Cmd-C. A real terminal from a real Sun, on a real Mac, looking better than XQuartz could manage.

## What Todd should add

- The visual quality comparison. XQuartz xterm side-by-side with swift-x xterm. The "this looks like a Mac app" reaction.
- The cell-snapping iteration. The first version that "almost worked" and what told you it was wrong (the bold residue).
- The cursor outline bug as a story. Why the half-pixel shift matters in graphics rendering. The CTM shift fix.
- Live verification flow. What does "test against u5" actually look like as a daily workflow?
- The XTERM_FONT_QUALITY.md backstory.

## Anchors for fact-check pass

- Files: `SERVER_RESOLUTION_SCALING_AND_FONTS.md`, `XTERM_FONT_QUALITY.md`, `RENDERING_DESIGN.md`, `Sources/SwiftXServerCore/CocoaWindowBridge.swift`, `Sources/SwiftXServerCore/USKeymap.swift`
- Commits in order: `11ccde3` Phase 1.A-C scaling, `c127e67` Phase 1.D-F XLFD parser + ImageText8 + PolyFillRect, `b28eaef` Phase 1.G ListFonts + Xlib startup, `3efabad` adopt rendering doc, `7bdb74c` Phase 1 wrap (text orientation fix), `b238e11` FocusIn / FocusOut, `f730de0` CHATGPT_REVIEW cursor diagnosis correction, `65801b5` live xterm working, `3f9526c` direct resize, `60cb353` xterm3 capture, `b60ae9b` color xterm + Cmd-V, `2dec89f` xterm color + GC bg fix, `c0a9ecb` stroke +0.5 CTM shift, `d50ec81` live-resize no flashing, `606f889` cell-alias fit-to-cell, `3244998` cell-fits-font integer pointSize
- ANSI color allocation: AllocColor with 16 RGB tuples at xterm startup
- Cell-fits-font decision: `DECISIONS.md` 2026-05-09 entry "Cell-fits-font final rule"

## Working title alternatives

- "xterm on Retina"
- "The rendering doc bites back"
- "Five days from xclock to a working terminal"
