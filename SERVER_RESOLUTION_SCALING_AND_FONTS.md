# XServer for Mac: Display Scaling and Font Handling

**Status:** Design decisions, ready to implement after xclock works and before xterm.

**Context:** macOS XServer targeting old X11R5/R6 clients on Sun workstations. Renders to Retina displays of varying sizes (Studio Display, 4K external, Pro Display XDR, MacBook Pro Retina built-in). Goal: scalable, antialiased rendering — no bitmap fonts, no blurry upscaling, no display sub-optimal.

---

## Quality bar

Rendering must clearly beat XQuartz and approach iTerm2 for terminal text. The project's central premise is that XQuartz is mediocre — windows wrong size, jinky chrome, blurry text — and we don't ship code that perpetuates that. If a corner-cutting choice would make the result feel like XQuartz, we don't take the corner. iTerm2 is the reference for terminal rendering quality on macOS; for non-terminal X apps, we aim for "looks like a real Mac app rendering X content," not "looks like an X app trapped in a Mac window."

Every trade-off in this doc gets evaluated against that bar.

---

## Headline decisions

1. **Selectable scale factor**, with integer-first rollout and fractional support added in a later phase.
2. **Default configuration is display-adaptive at startup.** The server inspects the connected display and picks the highest integer scale and matching logical-root size that fits cleanly. Studio Display defaults to 1280×900 @ 3x; 4K external to 1280×720 @ 3x; MacBook Pro 14" to 1008×648 @ 3x; etc. Reported physical mm and DPI are derived from the chosen combination to keep ~90 DPI for Sun-era Xt/Motif font auto-sizing.
3. **All fonts are scalable substitutes** — no bitmap fonts shipped or rendered.
4. **Default monospace: Monaco. Default proportional: Helvetica Neue.** Both overridable via configuration once the substitution table is wired up.
5. **Cell-snapping strategy:** font cells report integer logical metrics, glyphs render at exact device-pixel positions, no subpixel positioning.

---

## Why these choices

### Logical root and scale: display-adaptive

The server picks logical-root size and integer scale from the connected display at startup. Goal: highest integer scale that fits, with a logical root in the 960–1280 range so you can host a couple of 80-column terminals side by side. No fractional scales in Phase 1 — fractional is Phase 3.

| Display | Native pixels | Logical | Scale | Device | Notes |
|---|---|---|---|---|---|
| Pro Display XDR 6K | 6016×3384 | 1280×900 | 4x | 5120×3600 | room to spare |
| Studio Display 27" 5K | 5120×2880 | 1280×900 | 3x | 3840×2700 | comfortable |
| iMac 5K 27" | 5120×2880 | 1280×900 | 3x | 3840×2700 | comfortable |
| 4K external (typical) | 3840×2160 | 1280×720 | 3x | 3840×2160 | fills exactly |
| MacBook Pro 16" Retina | 3456×2234 | 1152×720 | 3x | 3456×2160 | comfortable |
| MacBook Pro 14" Retina | 3024×1964 | 1008×648 | 3x | 3024×1944 | tight, fits |
| 1080p external | 1920×1080 | 960×540 | 2x | 1920×1080 | fills exactly |

**Picking algorithm:** try scales 4, 3, 2 in order. For each scale, try logical widths 1280, 1152, 1008, 960. First combination whose device dimensions don't exceed the display's native pixel dimensions wins. Logical heights derived from the same width-to-height ratio used in the table (roughly 16:11 for the larger logical sizes, 16:9 for the smaller ones to fit 4K and 1080p exactly).

Why integer-only in Phase 1: every logical pixel maps to a clean N×N device pixel block. No fractional alignment weirdness, no glyph drift across cells, no antialiasing on hairline borders. Phase 3 adds fractional scales for displays that don't fit a clean integer (rare among Retina-class displays but possible on unusual external monitors).

Why ~90 DPI reported regardless of physical scale: Sun-era Xt and Motif clients use the screen's reported DPI to auto-size fonts. Reporting the actual macOS display DPI (218 for Studio, 264 for MacBook Retina, etc.) would make every Sun-era app pick gigantic fonts. Reported physical mm and DPI are computed as `(deviceWidth / scale) × (25.4 / 72)` so the *logical* dimensions look like a 90 DPI display to the X client even though the underlying pixels are Retina-dense.

Sun-authentic vertical (avoiding 1024 which doesn't fit at 3x on most displays) is preserved by the picking algorithm — it picks 720 or 648 instead of trying to land on 1024.

### No bitmap fonts

- Bitmap fonts at scale look terrible (blocky upscale) or require shipping multiple sizes.
- Modern Mac scalable fonts (Monaco, Menlo, Helvetica Neue) hint beautifully at any size via Core Text.
- The "old X look" people remember is mostly cell-based layout, not specifically bitmap rendering. We preserve cell layout; we modernize rendering.

### Monaco as monospace default

- Culturally appropriate (on every Mac since 1984).
- Tighter line height than Menlo, closer to Sun bitmap font feel.
- User-validated: Monaco 14 in iTerm2 is a familiar reference point.

---

## Architecture: three independent scaling planes

The naive approach — one `scaleFactor` multiplier applied uniformly — looks fuzzy at fractional scales. The correct approach decomposes into three planes, each with its own snapping rules:

### Plane 1: Geometry (free fractional)

Window sizes, drawable bounds, mouse hit-tests. This plane can be any real number. Edges may land on fractional device pixels — that's fine because users perceive *what's drawn*, not *where edges sit*.

```
deviceX = logicalX * scaleFactor      // fractional OK
logicalX = deviceX / scaleFactor      // for mouse events
```

### Plane 2: Stroke (snap to integer device pixels)

Lines, borders, hairlines. Snap stroke widths to integers so they render as crisp device-pixel-aligned strokes:

```c
// Use ceil so user "make it bigger" intent is honored even at 1.3x
int strokeMultiplier = (int)ceil(scaleFactor);
CGFloat deviceLineWidth = clientLineWidth * strokeMultiplier;

// For odd widths, offset by 0.5 device px to avoid edge antialiasing
if ((int)deviceLineWidth % 2 == 1) {
    deviceX += 0.5;
    deviceY += 0.5;
}
```

X clients commonly request `lineWidth = 0` ("thinnest possible"). Treat as `lineWidth = 1`.

### Plane 3: Font (snap to integer point sizes)

Core Text hints best at integer point sizes. Snap render size, then derive cell metrics from the snapped size:

```c
CGFloat naturalRenderSize = basePoint * scaleFactor;       // e.g., 14 * 2.3 = 32.2
CGFloat snappedSize = round(naturalRenderSize);            // 32
CGFloat effectiveFontScale = snappedSize / basePoint;      // 2.286

int cellWidthDevice = (int)round(basePoint * 0.6 * effectiveFontScale);
int cellHeightDevice = (int)round(basePoint * 1.07 * effectiveFontScale);
```

Slight scale drift (≤0.5 device px per cell) but every glyph hints crisply and every cell is identical width.

---

## Font substitution table

For XLFD requests, parse family/weight/slant/spacing/pixelSize and substitute:

| XLFD family | Substitute | Notes |
|---|---|---|
| `fixed`, `misc-fixed` | Monaco | |
| `courier`, `adobe-courier` | Courier New | Metric-compat with PostScript Courier |
| `lucidatypewriter`, `b&h-lucidatypewriter` | Andale Mono | |
| `terminal`, `vt100`, `screen` | Monaco | |
| `clean`, `schumacher-clean` | Monaco | |
| `helvetica`, `adobe-helvetica` | Helvetica Neue | |
| `times`, `adobe-times` | Times New Roman | Metric-compat with PostScript Times |
| `new century schoolbook` | Charter | |
| `symbol` | Symbol | |
| `*` with spacing `c` or `m` | Monaco | Monospace fallback |
| `*` with spacing `p` | Helvetica Neue | Proportional fallback |

This table is the **seed** for a user-editable file at `~/.swiftx-fonts` (as of 2026-05-23). `FontResolver.installMappings` writes the seed on first run and loads the user's edits thereafter. The Mac chrome's "Edit Font Mappings…" menu opens a SwiftUI editor for it. Revert to Defaults overwrites the file with the seed. The bundled seed lives in `Sources/SwiftXServerCore/DefaultFontMappings.swift`; this table is the canonical spec for what that seed contains.

### Bold and italic

- `weight=bold` → real bold face of the substitute family (Monaco Bold, Courier New Bold, Andale Mono Bold, Helvetica Neue Bold, Times New Roman Bold). All exist on macOS.
- `slant=i` or `slant=o`: prefer the real italic face when one exists in the substitute family — Courier New Italic, Andale Mono Italic, Times New Roman Italic, Helvetica Neue Italic, Charter Italic. Apple ships these. Monaco and Symbol have no italic face; for those only, synthesize italic via `CGAffineTransformMake(1, 0, tan(12° in radians), 1, 0, 0)` skew.
- Skew is a fallback, not a default. Real italic faces hint correctly; skewed glyphs at terminal sizes show distortion that the quality bar above does not tolerate.

---

## Cell sizing for common XLFD aliases

For named cell aliases (`7x14`, `9x15`, etc.), use this table directly. Width-derived rule: `pointSize = W / 0.6`.

| XLFD alias | Logical cell | Monaco pt | Device cell @ 3x |
|---|---|---|---|
| `5x7` | 5×7 | 8.33 | 15×21 |
| `5x8` | 5×8 | 8.33 | 15×24 |
| `6x10` | 6×10 | 10.0 | 18×30 |
| `6x12` | 6×12 | 10.0 | 18×36 |
| `6x13` | 6×13 | 10.0 | 18×39 |
| `7x13` | 7×13 | 11.67 | 21×39 |
| **`7x14`** | **7×14** | **11.67** | **21×42** |
| `7x15` | 7×15 | 11.67 | 21×45 |
| `8x13` | 8×13 | 13.33 | 24×39 |
| `8x16` | 8×16 | 13.33 | 24×48 |
| `9x15` | 9×15 | 15.0 | 27×45 |
| `10x20` | 10×20 | 16.67 | 30×60 |
| `12x24` | 12×24 | 20.0 | 36×72 |

For named aliases like `7x14`, **report Monaco's natural cell at the closest integer pointSize**, not the cell the alias names. iTerm2's lesson: fit the cell to the font, not the font to the cell. The alias becomes a hint of intended size; the renderer reports what Monaco actually produces.

```swift
// 7x14 alias on macOS Monaco (advance ratio ~0.6, lineHeight ratio ~1.34)
let pointFromW = 7.0 / 0.6   = 11.67
let pointFromH = 14.0 / 1.34 = 10.45
let pointSize  = round(min(pointFromW, pointFromH))   // 10
let cellWidth  = round(10 × 0.6)  = 6
let cellHeight = round(10 × 1.34) = 13
```

Result: `7x14` reports as 6×13. Empirical alias map (real macOS Monaco):

| Alias | Reported cell | pointSize |
|---|---|---|
| `5x7` | 3×7 | 5 |
| `6x10` | 4x9 | 7 |
| `6x13` / `7x13` / `7x14` / `8x13` / `fixed` | 6×13 | 10 |
| `7x15` / `9x15` | 7×15 | 11 |
| `8x16` | 7×16 | 12 |
| `10x20` | 9×20 | 15 |
| `12x24` | 11×24 | 18 |

**Why this matters:** xterm sizes its window from QueryFont's metrics. Reporting Monaco's truth means glyphs fit cells exactly, no asymmetric AA fringe (the "feels bold" residue), no descender bleed. Integer pointSize hits Core Text's hinter sweet spot. Trade: the user's named-cell dimensions become approximate. `xterm -fn 7x14` produces a slightly smaller window than the named dimensions suggest, but renders Monaco crisply.

### For arbitrary XLFDs

```swift
let pixelHeight = xlfd.pixelSize > 0 ? xlfd.pixelSize : 14
let pointSize  = round(Double(pixelHeight) / probe.lineHeightRatio)  // integer
let cellWidth  = round(pointSize × probe.advanceRatio)               // from CTFont
let cellHeight = round(pointSize × probe.lineHeightRatio)            // from CTFont
```

`pixelHeight` becomes a hint to pick the integer pointSize; reported cellHeight is what Monaco actually produces (so `pixelSize=14` reports `cellHeight=13`).

---

## QueryFont response

Report integer logical metrics derived from the cell:

```c
// All glyphs report identical width (monospace)
font.min_bounds.character_width = cellWidth;
font.max_bounds.character_width = cellWidth;
font.font_ascent  = (int)ceil(pointSize * 0.85);    // Monaco ascent ratio
font.font_descent = cellHeight - font.font_ascent;
font.all_chars_exist = true;  // within the encoding
```

**Critical invariant:** the metrics you report must match what you actually render. xterm computes window dimensions as `cellWidth × cols` and lays out cursor positions assuming consistent metrics. Any drift shows up as cursor misalignment.

---

## Rendering pipeline

```c
// For each glyph at logical cell (col, row):
int logicalX = col * cellWidth;
int logicalBaselineY = row * cellHeight + fontAscent;

// Convert to device coords (geometry plane):
CGFloat deviceX = logicalX * scaleFactor;
CGFloat deviceBaseline = logicalBaselineY * scaleFactor;

// Snap cell origin to integer device pixels (avoid subpixel drift across cells):
deviceX = round(deviceX);
deviceBaseline = round(deviceBaseline);

// Render Monaco at snapped size:
CTFontRef font = CTFontCreateWithName(CFSTR("Monaco"), snappedRenderSize, NULL);
CGContextSetFont(ctx, font);
CGContextSetFontSize(ctx, snappedRenderSize);

// Critical settings for cell-snapped rendering:
CGContextSetShouldAntialias(ctx, true);
CGContextSetShouldSmoothFonts(ctx, true);
CGContextSetAllowsFontSubpixelPositioning(ctx, false);  // CRITICAL
CGContextSetShouldSubpixelPositionFonts(ctx, false);    // CRITICAL

CGGlyph glyph;
UniChar ch = character;
CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
CGContextShowGlyphsAtPositions(ctx, &glyph,
    &(CGPoint){deviceX, deviceBaseline}, 1);
```

**Subpixel positioning OFF is non-negotiable** for cell-snapped rendering. With it on, Core Text will shift glyphs by fractional device pixels, breaking the cell grid.

---

## xlsfonts synthesis

When clients enumerate fonts (`ListFonts` / `ListFontsWithInfo`), the server returns a synthesized list. Foundry: `apple` (conventional for Apple-supplied fonts).

### Phase 1 set (~30-40 entries)

Just enough to satisfy real apps without spending time generating XLFDs nobody asks for:

- All named cell aliases (`fixed`, `5x7`, `6x10`, `6x13`, `7x13`, `7x14`, `7x15`, `8x13`, `8x16`, `9x15`, `10x20`, `12x24`, `cursor`) — one entry each.
- Each substitute family at 8/10/12/14/16 pt, medium and bold weights, roman slant only — for `iso10646-1` encoding only.

Real apps mostly probe specific patterns (`fixed`, `9x15`, the configured screen font); the named-alias set covers most of that. Synthesizing more is cheap-but-noisy and makes `xlsfonts` output less useful for debugging.

### Phase 4 expansion (~100 entries)

Full matrix: 5 families × medium/bold × roman/italic × ~10 sizes (8, 10, 11, 12, 13, 14, 16, 18, 20, 24) × 2 encodings (`iso8859-1` and `iso10646-1`). Add as a polish item once we hit a client that probes for something Phase 1 doesn't synthesize.

Example synthesized XLFD:
```
-apple-monaco-medium-r-normal--14-140-90-90-m-84-iso10646-1
```

---

## Pixmaps, stipples, cursors

These are the residual disappointment areas. Strategies:

### Client-uploaded pixmaps (PutImage)

- Store at logical resolution.
- Upscale at composite time using `CGContextDrawImage` with `kCGInterpolationHigh` (Lanczos).
- For pixmaps with sharp edges (icons), nearest-neighbor sometimes looks better — consider a per-window heuristic or flag.
- GetImage requires downscaling device→logical with `kCGInterpolationHigh`. Round-tripping causes some softness; rare in practice.

### Stipples and tiles

- Hash the stipple bits and recognize common patterns (50% gray, 25% gray, crosshatch, vertical lines, horizontal lines).
- Substitute with `CGPattern` rendered at device resolution for recognized patterns.
- Nearest-neighbor scale for unrecognized patterns (avoids "fuzzy bug" appearance).

### Cursors

- Detect standard X cursor font shapes (`XC_left_ptr`, `XC_xterm`, `XC_watch`, `XC_crosshair`, etc.).
- Substitute with `NSCursor` system cursors. Looks dramatically more native.
- Fallback: upscale the client's cursor pixmap.

---

## Implementation phases

### Phase 1: Display-adaptive integer scale + Monaco substitution (do this first)

Detect the main display on startup; pick logical root + integer scale from the preset table above. Hardcode that combination for the rest of the session — `scaleFactor` and logical-root size are constants once chosen, no live changes. Single integer scale used throughout the codebase.

Get xterm working against the chosen configuration and confirm:

- xterm opens, displays prompt, accepts input
- Cursor positions correctly across the full 80×24 grid
- Window resize works (xterm sends correct ConfigureRequest)
- Bold/italic ANSI escape sequences render distinctly
- Selection highlighting aligns to cell boundaries
- Mouse coordinates round-trip correctly (verify with `xev`)
- Same xterm session looks crisp on at least two of: Studio Display, 4K external, MacBook Pro Retina built-in. Different scales / logical roots picked automatically; rendering quality consistent across all three.

Don't build any abstraction for variable-scale-at-runtime yet. The scale is computed once at startup, then immutable for the session. Phase 2 makes it user-overridable.

### Phase 2: Selectable integer scale (2x, 3x; later 4x for Pro Display XDR)

Refactor `scaleFactor` from constant to runtime variable. Add UI for selection (NSMenu item, defaults key, whatever fits the app shell).

At this phase, scale changes require re-issuing screen dimensions to clients. Two approaches:
- **Restart the X server connection** when scale changes. Simple, drops running clients.
- **Send fake `RRScreenChangeNotify`** via XRandR extension if implemented. Lets running clients adapt. More work.

For v2, restart-on-change is acceptable. Add XRandR support in Phase 4.

Verify all integer scales (2x, 3x) produce crisp output. Confirm no metric drift. Test with xterm, xclock, xeyes, twm.

### Phase 3: Three-plane fractional scaling (1.5x — 4.0x continuous)

Implement the geometry/stroke/font decomposition described above. Slider UI from 1.0× to 4.0× with snap points at common values (1.5, 2.0, 2.5, 3.0).

Validation criteria:
- Lines stay crisp at every scale (no antialiasing fuzz on horizontal/vertical 1px lines)
- Text stays sharp at every scale (no glyph blur, consistent cell width)
- xterm cursor stays aligned to character grid at every scale
- Mouse coordinates round-trip cleanly at every scale

Honest expectation: pixmaps will be softer at fractional scales than integer. This is acceptable.

### Phase 4: Polish

- Per-display scale (multi-monitor support; different scale per X screen `:0.0`, `:0.1`)
- Per-window scale overrides (Cmd-+/Cmd-- on focused window)
- XRandR extension for live scale changes without client disconnect
- Custom cursor substitution table (NSCursor for common X cursors)
- Stipple pattern recognition library
- Italic synthesis tuning, optional Courier New Italic substitution

---

## Critical invariants (don't break these)

1. **Reported metrics === rendered metrics.** Whatever cell width you report in QueryFont must be exactly what you render. No drift.
2. **Subpixel positioning OFF for core-protocol fonts.** Always.
3. **Logical/device coordinate boundary is at the protocol/render layer, nowhere else.** Don't let device coords leak into the protocol layer or vice versa.
4. **Mouse events transform device→logical.** Verify with `xev` early. Forgetting this means clicks land in the wrong place.
5. **Damage rects expand outward to integer device pixel bounds before redraw.** Prevents 1-pixel seams at fractional scales.
6. **Pixmap data lives at logical resolution.** Upscale at composite time, never store at device resolution (memory blowup, GetImage breaks).

---

## External reviews

- `CHATGPT_REVIEW.md` (2026-05-07) — independent review affirming the design direction. Key affirmation: the "logical root independent from Retina device pixels" decision and the three-plane scaling model are the right abstraction boundary. The review's framing of the contract — "old UNIX/X11 clients believe they are rendering to a classic ~90 DPI workstation display while the Mac secretly renders everything sharply" — is the load-bearing illusion this whole spec exists to deliver.

## Open questions for later

- RENDER extension support? (Modern clients send pre-rasterized alpha masks; bypasses XLFD entirely. Not needed for R5/R6 target but easy to add later.)
- Xft/fontconfig protocol path? (Same story — modern clients only.)
- CJK encoding support? (Bundle Unicode-capable fallback for `jisx0208`, `ksc5601`, `gb2312` requests, or stub them out and refuse the font open.)
- Per-X-screen vs single-virtual-root for multi-monitor? (Sun-authentic = per-screen. Modern UX = single root spanning displays.)

---

## Reference: cell-snapping math summary

Per the 2026-05-09 cell-fits-font decision (`DECISIONS.md`):

```swift
// Probe Monaco once via Core Text:
let probe = ctMetrics(fontName: "Monaco")  // advanceRatio, lineHeightRatio

// Pick integer pointSize that fits the request in both dims:
let pointFromW = Double(requestedW) / probe.advanceRatio
let pointFromH = Double(requestedH) / probe.lineHeightRatio
let pointSize  = round(min(pointFromW, pointFromH))

// Cell is what Monaco actually produces at that integer pointSize:
let cellWidth  = round(pointSize * probe.advanceRatio)
let cellHeight = round(pointSize * probe.lineHeightRatio)

// Render with the SAME CTFont:
let font = CTFontCreateWithName("Monaco", pointSize, nil)
```

Reported metrics === rendered metrics by construction (both come from the same `font`). Integer pointSize is non-negotiable for Core Text hint quality. The XLFD's named cell becomes a hint of intended size, not a contract — see `XTERM_FONT_QUALITY.md` for the empirical alias map.
