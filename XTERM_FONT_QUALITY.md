# How swift-x renders xterm

This is the resolved design for how the server fits scalable Mac fonts into the cells xterm asks for. Originally a brainstorming brief; now a reference. The journey is in `DECISIONS.md` (entries dated 2026-05-07 through 2026-05-09) and `git log` if you want it.

## The problem in one sentence

xterm names a cell size in its XLFD (`7x14`, `9x15`, `fixed`) and expects every glyph to fit cleanly in that cell, with cell metrics that match exactly what we render. Monaco at fractional pointSize doesn't fit those cells naturally, and trying to force it produces stem asymmetry that reads as "too bold."

## The resolution: cell follows font, not font follows cell

iTerm2's playbook. When xterm asks for `7x14`:

1. Pick the integer pointSize closest to what fits — `round(min(cellW/advance_ratio, cellH/lineHeight_ratio))`.
2. Instantiate Monaco at that integer pointSize. Ask Core Text for its actual `advance`, `ascent`, `descent`, `lineHeight`.
3. Report **Monaco's actual cell** in QueryFont, not the requested 7×14. The XLFD's named cell becomes a hint, not a contract.
4. Render with the same CTFont. Reported metrics === rendered metrics by construction.

Integer pointSize is the key. Core Text's hinter does its best work there; fractional sizes lose stem crispness in ways that read as weight noise. Smoothing OFF + AA ON + subpixel positioning OFF are still load-bearing — same settings, just at the right pointSize.

## What this means in practice

| Alias | Reports as | Monaco at |
|---|---|---|
| `5x7` | 3×7 | 5pt |
| `6x10` | 4×9 | 7pt |
| `fixed` / `6x13` / `7x13` / `7x14` / `8x13` | 6×13 | 10pt |
| `7x15` / `9x15` | 7×15 | 11pt |
| `8x16` | 7×16 | 12pt |
| `10x20` | 9×20 | 15pt |
| `12x24` | 11×24 | 18pt |

Several aliases collapse onto the same cell because Monaco's natural aspect ratio at any integer pointSize is fixed at ~1:2.2 — the cells xterm names with different aspect ratios all map to the closest Monaco-natural cell.

The user's `xterm -fn 7x14` produces a slightly smaller window than the named dimensions suggest (480×312 logical for 80×24 instead of 560×336). They get Monaco rendered crisply, which is what they actually wanted.

## The cell-rectangle contract (still load-bearing)

When the renderer puts a glyph in a cell of `cellWidth × cellHeight` logical pixels:

- Glyph bbox stays inside the cell vertically (no descender bleed into next row).
- Cell `bg` fill aligns with cell boundaries so xterm's reverse-video and underlines hit the edges.
- Strokes (the unfocused-cursor outline, underlines) land cleanly on rows the cell encompasses, no half-pixel bleed.

These were violated by the old "force the cell" rule and the +0.5 device-pixel stroke recipe. The current rule (cell follows font + +0.5 user-pixel CTM shift in `applyStrokePlane`) honors all three.

## Stroke alignment between X11 and CG

Orthogonal to the font work but in the same path. X11 uses pixel-center addressing (a path from `(x,y)` to `(x+w-1,y)` covers exactly `w` pixels with both endpoints inclusive); CG uses grid-line addressing (integer paths sit between pixels). Without translation, X11 strokes land half a pixel outside their nominal cell, leaving cursor-outline ghosts.

Fix: `CocoaWindowBridge.applyStrokePlane` translates the CTM by `+0.5 user-pixel` before stroking. After that, X11 integer coordinates land at CG pixel centers and a 1-px stroke hits the pixels X11 expects.

## Stroke weight at 3× scale

A 1-logical-px Monaco stroke becomes 3 device pixels wide at our default scale. iTerm2 at backing scale 2 gets 2 device pixels per stroke. That's why swift-x's xterm reads slightly bolder than iTerm2 at the same physical screen size — it's the chosen scale, not a font-rendering bug. Phase 3 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md` allows fractional scales for users who want lighter stroke; current default is 3× because integer scales preserve clean N×N device-pixel blocks.

## Files

- `Sources/SwiftXServerCore/FontResolver.swift` — alias and XLFD resolution; integer-pointSize snap; Core Text metric probe.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` — `drawImageText8`, `drawPolyText8`, `applyStrokePlane`. Smoothing/AA settings.
- `Sources/SwiftXServerCore/SynthesizedFonts.swift` — `xlsfonts` catalog.
- `SERVER_RESOLUTION_SCALING_AND_FONTS.md` — the visual spec (three-plane scaling, etc.). Anything visual that doesn't honor it is a bug.
- `DECISIONS.md` 2026-05-09 — the cell-fits-font decision and what it rejected.
