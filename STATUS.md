# Status 2026-05-17 — End of day

Big day. Nine commits: pixmap-render arc landed, capture re-baseline,
font-charset work, plus a late-day docs hygiene pass that absorbed the
2026-05-14/15 audit + comparison research into the live ledger and set
up a rolling-STATUS convention. dt-Motif chrome now renders 3D with
correct CDE-grey colors against our server. Visible-text gap remains
the headline open issue for tomorrow.

## Commits today (in landing order)

| # | sha | what landed |
|---|---|---|
| 1 | `aa5a674` | RESOURCE_MANAGER fixture — bake u5's 3910-byte CDE resource database into root window properties. Was a 23-byte placeholder; now Xt-based clients see real font lists and Motif feature flags. |
| 2 | `91761a6` | Pixmap-render foundation — `PixelBuffer` (CGBitmapContext per pixmap), `PixmapTable.allocate(...)`, `DrawTarget` enum, `validateDrawTarget` returns `DrawTarget?`. No behavior change yet; type plumbing only. |
| 3 | `4af04de` | Pixmap Stage 1b — bridge `withDrawContext(target, clipRectangles, body)` helper, 9 `drawXxx` methods refactored to take `target: DrawTarget`, all 10 handler call sites updated. Pixmap-targeted draws actually write pixels into the PixelBuffer.context. |
| 4 | `262c105` | Capture re-baseline on SS2 — moved 16 legacy `*-sun.xtap` files to `captures/archive/`, recaptured all dt-apps from u5 and classic X apps from SS2, both displaying on SS2's X Consortium R6 sample server (the cleanest spec-compliant baseline available). 8 replay tests rebaselined; broader badId tolerance in replay-test harness. `captures/README.md` documents the scheme. |
| 5 | `cef3912` | Pixmap Stage 2 — `bridge.copyArea(src: DrawTarget, dst: DrawTarget, ...)`. Same-NSWindow path keeps the bitmap memmove fast path (xterm scroll). All other 4 cases (cross-NSWindow, pixmap→window, window→pixmap, pixmap→pixmap) snapshot src as CGImage cropped to source rect, draw via CGContext.draw(image:in:) through withDrawContext. Honors GC clip on every path except memmove. |
| 6 | `268d612` | QueryFont charset awareness — `ResolvedFont` gains `charsetRegistry`/`charsetEncoding` fields populated from XLFD's last two fields. `makeQueryFontReply` returns `chars=224` (range 32...255) for iso8859 fonts, `chars=95` (32...126) for others. Added `CHARSET_REGISTRY` + `CHARSET_ENCODING` atom-valued FONTPROPS. Required because Motif's `XCreateFontSet` reads these atoms to match per-charset font variants. |
| 7 | `c204536` | ListFonts override + echo fallback — three-layer `SynthesizedFonts.match()`: (1) curated overrides (starts empty, policy comment), (2) synth list (existing), (3) echo: if no synth match AND pattern has concrete CHARSET_REGISTRY-CHARSET_ENCODING suffix, return the pattern itself as a single match. Motif's `XCreateFontSet` does suffix-compare on the returned name (`omGeneric.c:91-114` check_charset) so echo unblocks the per-charset probe. Bounded to concrete-charset patterns so wildcard enumerators (xfontsel) still get the honest synth list. |
| 8 | `350cdf9` | Docs cleanup — 8 superseded docs + `audit/` + `comparison/` research forks moved to `archive/` (39 renames preserving git history). 14 actionable findings promoted into SHORTCUTS (CWBackPixmap/Border, CWBorderWidth, ReparentWindow Unmap/Map pair, SetSelectionOwner time gate, GetProperty type filter, GetPointerMapping [1..5], substructure-redirect events, RotateProperties, the remaining kbd/pointer BadRequest opcodes, no-auth on TCP listener, motionBufferSize lie, CDE atom pre-intern, SolarisIA, Expose-vs-ConfigureNotify cascade) each citing its archive path. `captures/README.md` absorbed the ToolTalk-proxy detail from the archived FOLLOWUPS doc. CLAUDE.md routes XTERM_FONT_QUALITY for terminal-text and notes the archive convention. |
| 9 | `0388406` | Rolling STATUS.md convention — `STATUS_2026-05-17.md` → `STATUS.md`, overwritten end-of-day rather than accumulating dated snapshots. Rule documented in CLAUDE.md Working Conventions. |

**526 tests pass, 4 documented skips, 0 failures.** Working tree:
one uncommitted diag log line in `drawPolyText8` (added late-day for
debugging the invisible-text mystery; decide tomorrow whether to keep).
The two pre-existing working-tree changes from earlier today
(`CocoaWindowBridge.swift` and `connection.json`) are still uncommitted.

## What's working visually on u5 + dt-Motif now

End of day, running `dtcalc` from u5 with DISPLAY → swiftx:0:

- Boots end-to-end (no abort, clean disconnect on quit)
- 3D button chrome renders with correct CDE shadow lines
- Panel background is CDE-grey (`#C800C800C800`) — RESOURCE_MANAGER fixture
- LCD area is white with black border — matches u5 behavior
- Quit button label renders correctly
- Console clean — no Motif font warnings (was a flood pre-c204536)

## What's broken / open puzzles

### 1. Most digit/operator button labels are invisible

The Quit button label renders. The 0-9 digits, +, =, sqrt etc. don't.
Todd confirmed Quit is just another Motif PushButton, NOT a title-bar
widget — same widget class, different result.

Hypotheses to test tomorrow, ranked:

- **GC foreground color resolves to invisible.** Different buttons may
  use different GCs (the wire trace shows GCs 0x4400010, 0x440009C,
  0x44000A5, 0x440003F all used for PolyText8). If digit buttons'
  GC has foreground pixel pointing at a colormap index we resolve to
  grey-on-grey, text is rendered but invisible. The diag log added
  to `drawPolyText8` today (uncommitted in working tree) will report
  the fg RGB for each call.
- **GC clip rect excludes the text region.** Less likely (would
  affect chrome too) but possible if clip is being set per-text-call.
- **Font reference (state.font) on those GCs resolves to a font that
  has no usable glyphs for the digit characters.** Even less likely
  (Quit's "Quit" string uses the same ASCII chars).

### 2. LCD digits now render as .notdef boxes (REGRESSION)

The LCD numeric display USED to render digits correctly pre-today.
After today's changes, the LCD shows weird square boxes — the classic
.notdef glyph signal.

This is a real regression caused by today's work. Most likely culprit:
`268d612` (chars=224 range for iso8859 fonts) OR `c204536` (echo
fallback may resolve LCD's font to a wildcard XLFD that picks up
different metrics than before).

Possible mechanism:
- LCD widget queries a specific bitmap-ish font
- Pre-today: that font resolved to Monaco 7x14 (or similar), all
  ASCII glyphs present, digits render fine
- Post-today: maybe the font now resolves via the echo path with
  different size/family wildcards expanded → Monaco at a different
  pointsize → CTFontGetGlyphsForCharacters returns 0 for digit
  codepoints? Or the chars=224 reply changes how the widget builds
  its glyph cache, hitting a path that doesn't work?

To investigate:
- Capture dtcalc post-today, diff OpenFont names against
  `captures/dtcalc-u5-on-ss2.xtap` gold. Look at what font the LCD
  opens.
- Compare QueryFont reply for the LCD's font on swiftx vs SS2.

### 3. Motif text-entry fields got WORSE today (REGRESSION)

Todd's observation. Probably same root cause as the LCD regression —
both involve text rendering through some shared Motif path that broke
between yesterday and today.

### 4. ToolTalk-through-proxy bug (unchanged from prior days)

`dticon`, `dtmail`, `dtpad` work direct u5→ss2 but timeout after ~5min
through `swiftx-capture` proxy. Detail now lives in
`captures/README.md` (absorbed from the archived FOLLOWUPS doc during
today's docs hygiene pass). Proxy bug, not server bug. Not blocking —
those apps' captures from earlier today are partial but usable.

### 5. SelectionMediator daemon impersonation may be over-engineered

Earlier diagnostic (working with the dtcalc-u5-on-ss2 capture)
established that dt-apps issue `ConvertSelection(Customize Data:0)`
on any server but tolerate `SelectionNotify(property=None)` gracefully.
Our `SelectionMediator.installCDECustomizationDaemonImpersonation`
might be a workaround for a bug in our own ConvertSelection handler,
not a structural dt-app requirement. Worth investigating after the
visible-text problems are resolved.

## Tomorrow's recommended starting point

**One run, two answers:** rebuild swiftx with today's working tree
(includes the uncommitted `drawPolyText8` diag log), launch dtcalc on
u5, click a digit or two, look at the server log.

The diag log entries will show foreground RGB for each PolyText8 call.
If digit-button calls come back with `fg=(200,200,200)` (or close), it's
a color/colormap issue → next step is tracing GC foreground pixel
resolution. If they come back with `fg=(0,0,0)` (proper black), the
issue is downstream — clip or glyph lookup. Either answer narrows
sharply.

Same run's log + a fresh capture (`dtcalc-u5-on-swiftx-v4.xtap`)
gives us:
- LCD font name + QueryFont reply structure (to chase the regression)
- Text-entry widget's font + render path (the second regression)
- Wire diff against `dtcalc-u5-on-ss2.xtap` gold to spot any other
  drift introduced by today's changes

After that, plan emerges naturally:
- If color: probably 1 commit to fix GC pixel resolution or seed a
  better palette entry.
- If LCD regression: revert the regression-causing line (probably
  in 268d612 or c204536), iterate.
- If text-entry: likely same root as LCD; one fix addresses both.

## Files that may need attention tomorrow

- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` — `drawPolyText8`
  (diag log line in working tree; decide keep vs revert based on
  whether color is the issue)
- `Sources/SwiftXServerCore/ServerSession.swift` — `makeQueryFontReply`
  (charset-aware range; check if LCD regression traces here)
- `Sources/SwiftXServerCore/SynthesizedFonts.swift` — echo fallback
  (check if LCD's font resolution path is going through echo
  incorrectly)
- `Sources/SwiftXServerCore/FontResolver.swift` — `resolve(xlfd:)` and
  `defaultMonacoFont` (the wildcards-to-Monaco path)
- `Sources/SwiftXServerCore/ColorTable.swift` — CDE pixel palette
  (if foreground color resolves to grey, this is where to fix)

## How far we've come today

Pre-today: dtcalc died on the LCD-digit-swap CopyArea burst, never
got to draw chrome.

End of today: dtcalc fully boots, renders Motif chrome with correct
CDE shadows + colors, only the LAST domino (text legibility) remains.

The hard parts of the pixmap-render arc (Stages 1b + 2 + the capture
re-baseline that made debugging tractable) are all shipped and locked
in by tests. Tomorrow is a focused chase on one specific symptom.

Also: the docs tree is back in shape. SHORTCUTS is now the single
ledger again — the audit + comparison research lives in `archive/`
with their actionable findings promoted to SHORTCUTS entries that
cite back. CLAUDE.md routes correctly for terminal-text work. After
the text-legibility chase tomorrow, the SHORTCUTS open list has a
much richer set of "next things to pick" than it did this morning.
