# Review and Architectural Feedback: macOS XServer Scaling + Font Strategy

Author: ChatGPT  
Audience: Claude Code + Todd  
Context: Modern Swift-based X11 server for macOS targeting classic X11R5/R6 clients, Retina displays, and workstation-authentic behavior.

---

# Executive Summary

This is fundamentally the correct architectural direction.

The design understands something XQuartz never fully solved:

> X11 protocol space and modern Retina rendering space are not the same thing.

The proposal correctly separates:
- protocol geometry
- device rendering
- font metrics
- stroke behavior
- compositing behavior

into independent scaling domains.

That separation is the key insight.

The overall product thesis is excellent:

> Old UNIX/X11 clients believe they are rendering to a classic ~90 DPI workstation display while the Mac secretly renders everything sharply using modern scalable typography and Retina rendering.

That is exactly the right illusion.

---

# The Strongest Decisions

## 1. Logical root independent from Retina device pixels

This is absolutely correct.

The X server should expose a stable logical coordinate system:
- 1280×900
- ~90 DPI
- integer protocol coordinates
- classic X11 expectations

while macOS rendering happens independently at device resolution.

This preserves:
- Xt assumptions
- Motif layout behavior
- xterm geometry logic
- old toolkit font heuristics

without exposing Retina complexity to the client.

This is the correct abstraction boundary.

---

## 2. Three-plane scaling model

This is the most sophisticated part of the design.

Separating:
- geometry
- stroke
- font

is exactly how modern rendering engines avoid blur.

The critical insight is:

```text
Geometry can tolerate fractional values.
Text and strokes cannot.
```

(The original ChatGPT export was truncated here. What's above is what we have on hand.)

---

# Claude's commentary: should we believe Mac font metrics?

Added 2026-05-07 at Todd's request, after live xterm started showing cursor outline boxes around characters.

## TL;DR

Yes, believe Core Text's metrics. Don't believe our cell-sizing heuristic. The two have to come from the same source or they'll drift, and that drift is what produces the cosmetic artifacts we're seeing now.

## What we do today

In `SynthesizedFonts.makeXLFD` we compute pixel height and average width from point size with constants:

```swift
let pixelHeight = Int(round(pointSize * 1.07))
let avgWidth = Int(round(pointSize * 0.6 * 10))
```

That `1.07` and `0.6` are guesses — close enough to look right for Monaco at common sizes, but they aren't anchored to any specific Mac font's actual metrics. When the client (xterm) reads our `QueryFont` reply, it gets these heuristic numbers. When we then ask Core Text to render glyphs into a cell of `(avgWidth, pixelHeight)` pixels, Core Text positions the glyphs using its OWN advance and ascent — not our heuristic ones. So the rendered glyph and the X-protocol cell drift apart at the sub-pixel level.

## Why the drift produces the cursor outline boxes

xterm draws the cursor as a 1px-stroke `PolyLine` rectangle at the cell boundary it computed from `QueryFont`. Then it does an `ImageText8` to overprint with the actual character. `ImageText8` paints a background fill of size `(width × FontHeight)` where `width` is the sum of glyph advances FROM ITS POV — which ultimately comes from the same `QueryFont` reply, so xterm's two operations (cursor outline and character paint) agree with each other.

But OUR rendering of `ImageText8` uses Core Text's actual advance for glyph placement and Core Text's actual ascent for baseline. If those don't exactly match the `(avgWidth, pixelHeight)` we reported, the bg fill rectangle and the cursor outline rectangle don't line up to the pixel. The outline pokes out past the bg fill on one side. That's the box artifact.

## What "believe Mac font metrics" means concretely

Three things change:

1. **Derive the cell from Core Text, not from a constant.** At the moment we resolve a substitute font (the `FontResolver.resolve` step), instantiate a `CTFont` at the chosen point size and ask it for `ascent`, `descent`, and the advance of a representative glyph (e.g. `'M'` for monospace). Round each up to an integer. THAT is the cell we report in `QueryFont`.

2. **Round point size to an integer before resolving.** Core Text gives consistent integer-pixel metrics if you ask at integer point sizes. Fractional point sizes produce sub-pixel metrics that we'd have to round anyway, so just round once at the input.

3. **Use the same `CTFont` instance for the rendering side.** Right now the bridge re-resolves the font at draw time. If we cache the resolved `CTFont` on the `FontEntry` (alongside the cell it produced), we guarantee the render side uses the exact font instance that produced the metrics in the `QueryFont` reply. No room for drift.

The protocol is fine with what we report — X clients want integer cells, and that's what we'd give them. We just want the integers to be derived from the actual font we're going to render, not from constants that happen to be approximately right.

## Why I'd defer this slightly

Todd flagged this earlier as something to NOT chase right now ("we don't want to endlessly chase artifacts"). I agree with the deferral for two reasons:

- The artifact is cosmetic. xterm is fully usable. Cursor outline boxes are ugly but don't block work.
- The fix touches `OpenFont`, `QueryFont`, and the bridge's text-render path. Worth doing as a small focused pass rather than mixed into other work.

So: capture the analysis here, leave a Phase-1.5 task to come back to it. The trigger for actually doing the work is "cosmetic artifacts in xterm get annoying enough that I want them gone" or "we move to a second app and the metrics drift produces a worse symptom."

## The principled reading

The deeper point of the three-plane model in the doc above is that geometry, stroke, and font live in different scaling regimes. The font plane's job is to NEVER lie — to expose to the client metrics that exactly describe what the renderer is going to put on screen. Anything else creates reconciliation bugs at integration boundaries. Core Text's metrics for our chosen substitute ARE the ground truth; our heuristic is a polite fiction that the renderer politely ignores. Polite fictions accumulate.
