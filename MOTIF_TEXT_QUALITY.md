# How swift-x renders Motif and Xt text

This is the resolved design for how the server handles text rendering in Motif widgets (XmText, XmLabel, XmCascadeButton, XmPushButton, XmList) and other Xt-based proportional-font text — basically every app from the era that isn't a character-grid terminal. The xterm/dtterm playbook is `XTERM_FONT_QUALITY.md`; this is its companion for everything else.

Anything visual that doesn't honor what's below is a bug.

## The problem in one sentence

Motif's XmText (and friends) position glyphs by summing per-character `characterWidth` values from QueryFont's CHARINFO array. A single `cellWidth` doesn't apply. The renderer MUST match the per-character advances we report — it cannot use Core Text's natural cumulative rhythm — or characters drift relative to where the client believes they're placed.

## Two playbooks, one server

| Playbook | Apps | Model | Doc |
|---|---|---|---|
| Cell-grid monospace | xterm, dtterm | Single `cellWidth × cellHeight`. Client is a character-grid widget; reported metrics === rendered metrics by construction. AA halo within the cell is the visual cost. | `XTERM_FONT_QUALITY.md` |
| Proportional per-character | Motif XmText / XmLabel / XmPushButton / XmCascadeButton / XmList, dtpad, dthelpview, xfontsel, Athena text widgets, anything Xt-shaped | Per-glyph `characterWidth` in CHARINFO. Client sums to compute positions; renderer must match. | this doc |

Apps don't tell us which playbook they want. The dispatch is implicit: any client reading per-char CHARINFO is on the second playbook even if the font they opened is monospace. Monaco-via-`"fixed"` rendered for dtpad's XmText goes through this playbook, not xterm's.

## The invariant

> For every glyph rendered, the `characterWidth` we report in QueryFont's CHARINFO equals the actual horizontal advance the renderer uses when drawing that glyph.

X11 `characterWidth` is INT16 — integer pixels, no sub-pixel. Both reported and rendered values must agree as integers.

## Implementation

Two-sided enforcement:

Both sides funnel through `FontResolver.integerAdvances(_:characters:)`, which dispatches on `resolved.isMonospace`:

- **Monospace** (Monaco, Courier, anything with spacing `m`/`c`): every glyph reports `resolved.cellWidth`. That's the round-of-natural-advance value the resolver computed when picking a Mac point size to fit the requested cell. drawImageText8 also positions on `cellWidth`, so the xterm cell-grid playbook stays self-consistent and Motif/Xt clients that read CHARINFO for the same font still see one constant width per glyph.
- **Proportional** (Helvetica, Times, Charter): per-glyph `Int(ceil(CTFontGetAdvancesForGlyphs(...)))`. Ceil is the side of the integer that can't go wrong — under-reporting causes visible overlap, over-reporting leaves sub-pixel gaps no client breaks on.

### Reporting side — `FontResolver.measureGlyphMetrics`

For each glyph in the requested character range:
1. Use `integerAdvances` for `characterWidth`. Missing glyphs (CT glyph index 0) report 0.
2. lsb / rsb / ascent / descent come from `CTFontGetBoundingRectsForGlyphs` — these are ink-box metrics unrelated to the advance invariant.
3. QueryFont's `min_bounds` / `max_bounds.characterWidth` derive from the population: `min` and `max` of the per-glyph values.

### Rendering side — `CocoaWindowBridge.drawPolyText8`

For each glyph in a draw call:
1. Compute positions as the cumulative sum of `integerAdvances` values — the same call the reporter makes. Do NOT call `CTFontGetAdvancesForGlyphs` directly or sum floats locally; that re-introduces the drift we're preventing.
2. Draw using `CTFontDrawGlyphs(_:_:positions:_:)` with those positions. Do NOT use `CGContextShowText` / `CTLineDraw` / any API that lets Core Text walk advances on its own.

The client positions character N at `Σ(reported_advances[0..N-1])` and we draw character N at the same coordinate.

### Rendering side — `CocoaWindowBridge.drawImageText8` (xterm playbook)

drawImageText8 is the cell-grid path. It positions glyphs at `i * cellWidth` and fills a bg rect of `n * cellWidth × cellHeight`. Because `integerAdvances` returns `cellWidth` for monospace, CHARINFO and drawImageText8 agree numerically by construction.

## What this costs

Slightly different visual rhythm from native macOS text. A 5.4-pixel glyph rounding up to 6 means a one-pixel gap on its right edge versus what Core Text would naturally produce. Across long runs the cumulative effect is small because typical English text averages out near the natural advance.

What we lose: italic ligatures, kerning pairs, and other fine typography that depends on sub-pixel positioning. We don't have those today and won't get them with this playbook. Acceptable — we're a vintage X server, not a desktop publishing renderer.

What we gain: the X protocol contract is honest end-to-end. Any client that uses CHARINFO to position text — which is every Motif widget by design — gets exactly what it expects. The dtpad over-typing symptom resolves by construction.

## The control surface: RESOURCE_MANAGER

The playbook above answers "given font X at pointSize Y, how do we render and measure?" It doesn't answer "which font does dtpad use for its XmText widget?" That's the resource layer.

X11 apps from the era assume an Xresources database is loaded via xrdb onto the X server's root window as the `RESOURCE_MANAGER` property. Motif's resource cascade resolves widget defaults from there — `*XmText.fontList`, `*XmLabel.fontList`, `Dtpad*XmText.fontList` overrides, etc. Apps then call `OpenFont` with those XLFDs.

We control what those apps request by curating what we put in `RESOURCE_MANAGER`. The XLFDs we publish get parsed by `FontResolver.resolve(xlfd:)`, mapped through the substitution table to a Mac font family, then resolved to integer cell metrics via the playbook above.

Strategy is widget-class defaults, not per-app overrides. Motif's cascade handles inheritance; we mostly tune the class defaults and accept per-app overrides only when a specific app genuinely needs a different look (dtpad's editing pane wanting monospace, dtterm's VT100 widget wanting fixed-width).

A minimal curated set:

```
*XmText.fontList:           -adobe-helvetica-medium-r-normal--14-*-*-*-p-*-iso8859-1
*XmTextField.fontList:      -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
*XmLabel.fontList:          -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
*XmList.fontList:           -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1
*XmCascadeButton.fontList:  -adobe-helvetica-bold-r-normal--12-*-*-*-p-*-iso8859-1
*XmPushButton.fontList:     -adobe-helvetica-medium-r-normal--12-*-*-*-p-*-iso8859-1

! Per-app overrides only when needed
Dtpad*XmText.fontList:      -adobe-courier-medium-r-normal--14-*-*-*-m-*-iso8859-1
```

The exact XLFDs are tuning material — they're picked for "this looks tasteful on retina" rather than fidelity to any particular Solaris CDE skin. Helvetica → Helvetica Neue, Courier → Courier New, Times → Times New Roman via the existing substitution table.

## Substitution table (Layer 1)

Family-name substitution lives in `FontResolver.resolveFamily`. Today's mapping:

| XLFD family | Mac font | Spacing |
|---|---|---|
| `helvetica`, `adobe-helvetica` | Helvetica Neue | proportional |
| `times`, `adobe-times` | Times New Roman | proportional |
| `new century schoolbook` | Charter | proportional |
| `courier`, `adobe-courier` | Courier New | monospace |
| `lucidatypewriter` | Andale Mono | monospace |
| `fixed`, `misc-fixed` | Monaco | monospace |
| `terminal`, `vt100`, `screen` | Monaco | monospace |
| `clean`, `schumacher-clean` | Monaco | monospace |
| `symbol`, `adobe-symbol` | Symbol | proportional |

This table is largely aesthetic. Adding rows or tweaking choices (e.g., `SF Mono` instead of `Monaco` for `terminal`) doesn't break any contract — every Mac font flows through the same playbook for measurement and rendering. Polish it over time; don't worry about exhaustive coverage.

## Staged delivery of the resource layer

- **Tier 1** — curated `RESOURCE_MANAGER` content baked into Swift source (`Sources/SwiftXServerCore/DefaultMotifResources.swift` or similar). Published at session startup, identical for every session. Replaces the 2026-05-18-retired `CDEResourceManagerFixture`. Hand-tuned XLFDs for Motif widget classes. ~50 lines.
- **Tier 2** — move the resource content out of source into a config file (e.g., `~/Library/Application Support/swiftx/resources.txt`, Xresources format) that the user can edit. Server reads on startup, regenerates the bytes for `RESOURCE_MANAGER` publish. ~100 lines plus a parser.
- **Tier 3** — macOS-native settings panel. NSPanel UI in the Mac app with editable fields per widget class. Live reload signal so new sessions pick up changes. A few hundred lines of AppKit.

Each tier compounds on the previous. We don't need Tier 3 to ship something useful; Tier 1 alone fixes the "dtpad uses `fixed`" problem.

## Files

- `Sources/SwiftXServerCore/FontResolver.swift` — alias and XLFD resolution; integer-pointSize snap; Core Text metric probe; `measureGlyphMetrics` (the reporting side of the invariant).
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` — `drawPolyText8`, `drawImageText8` (the rendering side of the invariant). Smoothing/AA settings.
- `Sources/SwiftXServerCore/DefaultMotifResources.swift` — (Tier 1, not yet shipped) curated `RESOURCE_MANAGER` content for the Motif widget classes we care about.
- `Sources/SwiftXServerCore/ServerSession.swift` — `RESOURCE_MANAGER` publish at session startup (currently no-op after the 2026-05-18 CDE retirement; restored when Tier 1 lands).
- `XTERM_FONT_QUALITY.md` — the cell-grid playbook for terminal-text apps.
- `SERVER_RESOLUTION_SCALING_AND_FONTS.md` — the load-bearing visual spec (substitution table, scaling planes, quality bar).
