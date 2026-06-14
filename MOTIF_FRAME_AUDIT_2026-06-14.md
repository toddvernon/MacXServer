# Motif window-frame audit against mwm source (2026-06-14)

Audit of `Sources/SwiftXServerCore/MotifFrame/` against
`reference/motif/clients/mwm/` (Open Group Motif 1.2.1). Read-only —
nothing in the tree was modified.

Reference geometry primitives all live in `WmCDecor.c` /
`WmCDInfo.c` / `WmGraphics.c`, with default values driven by resource
defaults in `WmResource.c` and shadow-color math in
`reference/motif/lib/Xm/Color.c`.

The mwm code path I audited is the WmRECESSED default frame style
with `clientDecoration = WM_DECOR_DEFAULT = MWM_DECOR_ALL`,
`matteWidth = 0`, screen DPI defaults yielding
`resizeBorderWidth ≈ 5–7px` and `frameBorderWidth ≈ 4–5px`,
`externalBevel = FRAME_EXTERNAL_SHADOW_WIDTH = 2`, and
`joinBevel = FRAME_INTERNAL_SHADOW_WIDTH = 1`.

Findings ordered by severity descending. Each cites both mwm source
line numbers and `MotifFrameView.swift` / `MotifTheme.swift` line
numbers so the user can verify directly. Where I'm guessing I say
so.

## Top-line summary (read this first)

15 findings total, broken down as:

- **3 MAJOR** (visible difference on a common case, or a wire
  behavior we get wrong) — F1 (focused-vs-unfocused), F2 (system
  menu button single-click closes instead of posting menu),
  F3 (maximize-button doesn't invert when window is maximized).
- **6 MINOR** (edge cases or small visible difference) — F4
  (decoration-bit ALL semantics), F5 (icon bevel width 2x mwm's
  1px), F6 (corner-groove geometry mismatches mwm's resize-handle
  layout), F7 (title bar drawn as standalone raised tile vs
  blended into chrome), F8 (LowerBorderWidth > UpperBorderWidth
  not modelled), F9 (depressed-gadget bevel is a hard color swap
  vs mwm's outer-rim-plus-inverted-inner-edge).
- **6 COSMETIC** (looks slightly off, mostly subjective) — F10
  (system-menu icon is a horizontal drawer-handle bar, not a
  centered square dash), F11 (title text padding/inset constant
  differs), F12 (no matte support), F13 (no MWM_DECOR_BORDER
  vs MWM_DECOR_RESIZEH distinction in our chrome), F14 (shaped-
  client title-bar geometry small offset mismatch), F15 (button
  hit-test corners use full bs span, mwm uses cornerWidth which
  also scales with frame height).

Things we're doing **better** than mwm: the `floor()` integer-pixel
snapping in `raisedTileCentered`
(`MotifFrameView.swift:362–378`) avoids half-pixel blur AppKit
would otherwise rasterise; mwm doesn't need this because X11 GC
fills are inherently integer. The `clientIsShaped` simplification
(`MotifFrameView.swift:217–221`) is more honest than mwm's "punt
on resize handle" (mwm leaves the visible-but-unresizable resize
handle bevels around the title for shaped clients —
`WmCDecor.c:2854` comment "currently punt on resize handle around
the frame").

---

## Major

### F1 — Focused vs unfocused window has no visual difference

**Severity:** MAJOR

**What mwm does:** A separate set of GCs and a separate background
color for the active (keyboard-focused) frame. `FrameExposureProc`
(`WmCDecor.c:202–267`) selects `activeTopShadowGC` /
`activeBottomShadowGC` from `CLIENT_APPEARANCE(pcd)` when
`pcd == wmGD.keyboardFocus`. `ShowActiveClientFrame` / 
`ShowInactiveClientFrame` (`WmCDecor.c:2080–2247`) also swap the
window background to `activeBackground` (default `CadetBlue`,
`#5F929E`) or `background` (default `LightGrey`, `#A8A8A8`) via
`XChangeWindowAttributes` then `XClearWindow`. The default
inactive vs active colors are set in `WmResource.c:4276–4277`
(active = `_defaultColor2` = `CadetBlue`, inactive =
`_defaultColor1` = `LightGrey`).

**What we do:** `MotifFrameView.swift:617–626` registers for
`didBecomeKeyNotification` / `didResignKeyNotification` and calls
`needsDisplay = true` on either — but `draw(_:)` never reads
`window?.isKeyWindow` and the theme has only ONE `fill` /
`highlight` / `shadow` / `titleColor` set (`MotifTheme.swift:10–18`,
`45–54`). The keyChanged hook redraws with the same colors.

**Difference:** Two stacked Motif frames are visually
indistinguishable. Real Sun mwm always shows which window has the
focus through a noticeable blue-grey title bar.

**Suggested fix shape:** Add an `activeFill` / `activeHighlight` /
`activeShadow` / `activeTitleColor` (or just `activeBackground`)
to `MotifTheme`, read `window?.isKeyWindow` in `draw(_:)`, and
branch the chrome+title-bar `fill`/`highlight`/`shadow` based on
it. Reasonable defaults: `activeFill = #5F929E` (CadetBlue), then
derive the other three via the same Xm color formula
(`reference/motif/lib/Xm/Color.c:854` — `CalculateColorsForMediumBackground`,
factors `XmCOLOR_HI_TS_FACTOR=60` toward white and
`XmCOLOR_LO_BS_FACTOR=60` toward black). Pre-bake the two color
sets at install time so `draw` stays cheap.

### F2 — System (menu) button single-click closes window; mwm posts the system menu

**Severity:** MAJOR (wire-behavior divergence on a UX-load-bearing
gesture)

**What mwm does:** `WmFunction.c:3053` `F_Post_SMenu` is bound by
default to single click on the FRAME_SYSTEM button. The system menu
(File / Move / Size / Minimize / Maximize / Lower / Close) pops up
below the menu button. CLOSE on the window is a DOUBLE-click of
the menu button (`WmEvent.c:792–805`), or the menu's own Close
entry. The press also shows the menu button as depressed via
`PushGadgetIn (pCD, FRAME_SYSTEM)` (`WmEvent.c:789`).

**What we do:** `MotifFrameView.swift:543–552` — `mouseUp` on the
menu button calls `windowShouldClose` (which fires the
`WM_DELETE_WINDOW` polite-close flow) and then closes the
`NSWindow`. No system menu is ever shown.

**Difference:** A user familiar with Sun/Motif will single-click
the menu button expecting a menu, and instead the window closes.
This is the inverse of the canonical Motif gesture; potentially
destructive (closes unsaved work).

**Suggested fix shape:** Wire the menu button to an `NSMenu`
showing the standard mwm system menu entries (Restore / Move /
Size / Minimize / Maximize / Lower / Close). Close on
`clickCount == 2`. Keep the single-click-closes path behind a
preference (some Mac users may prefer that), OR drop the
close-on-click behavior entirely. If we keep close-on-single-click
deliberately, log it in SHORTCUTS.md as a known mwm divergence
("Mac-native UX preferred over mwm UX") so this audit doesn't
re-surface it.

### F3 — Maximize button icon doesn't invert when the window is currently maximized

**Severity:** MAJOR (state-indicator bug)

**What mwm does:** `WmCDecor.c:937–946`:

```c
if (pcd->maxConfig) {
    BevelMaximizeButton(prlBot, prlTop, x-xAdj, y-yAdj, height);  /* inverted */
}
else {
    BevelMaximizeButton(prlTop, prlBot, x-xAdj, y-yAdj, height);  /* normal */
}
```

The maximize icon's bevel is swapped (top/bot lists reversed) when
`pcd->maxConfig` is set, making it look "pressed in" as a state
indicator (NOT a press indicator). This is how a Motif user sees
at a glance that the window is currently maximized.

**What we do:** `MotifFrameView.swift:260` — `raisedTileCentered`
always draws a raised tile regardless of `window.isZoomed`. The
button only depresses on transient press
(`raisedTile(ctx, maxR, pressed: pressedButton == 2)` at line
254).

**Difference:** A maximized window's maximize button looks
identical to a normal-state window's maximize button. Visual state
information is lost.

**Suggested fix shape:** In `drawTitleBar`, read
`window?.isZoomed ?? false` and pass `pressed: window.isZoomed` to
the maximize button's `raisedTileCentered` call (or `raisedTile`
for the outer tile). Wire `windowDidResize` / `windowDidExitFullScreen`
through `MotifWindow` to call `needsDisplay = true` on
the frame view so the icon updates when the user un-zooms via
the green-traffic-light path.

---

## Minor

### F4 — `MWM_DECOR_ALL` semantics: we treat it as "use defaults" but mwm treats it as "remove the listed bits"

**Severity:** MINOR (rarely-used flag, but a real spec divergence)

**What mwm does:** `WmWinInfo.c:4068–4079`:

```c
if (pHints->flags & MWM_HINTS_DECORATIONS) {
    if (pHints->decorations & MWM_DECOR_ALL) {
        /* client indicating decorations to be removed */
        pCD->clientDecoration &= ~(pHints->decorations);
    }
    else {
        pCD->clientDecoration &= pHints->decorations;
    }
}
```

When `MWM_DECOR_ALL` is set, mwm REMOVES the other bits in the
field from the default. E.g. `decorations = ALL | TITLE | MAXIMIZE`
means "start with all, then remove TITLE and MAXIMIZE."

**What we do:** `MotifFrameView.swift:47` —
`hasExplicitDecorations` returns `false` when `ALL` is in
`decorations`, so we ignore the rest of the field entirely and fall
back to the static `[motif-frame]` config (all decorations shown).

**Difference:** A client that sends `ALL | TITLE` to mean "no
title bar" gets a title bar from us. This is an obscure encoding
(most clients don't set ALL), but quickplot Build Plot / About
panels and old Athena dialogs sometimes do.

**Suggested fix shape:** When `flags & DECORATIONS` is set AND
`decorations` contains `.all`, compute
`effective = .all-set-minus-decorations` (the listed bits are
removed). When `flags & DECORATIONS` is set AND `decorations`
does NOT contain `.all`, the listed bits are the only ones shown
(current additive behavior is correct). Then drop
`hasExplicitDecorations` in favor of letting `decorationShown(_:)`
ask the effective set.

### F5 — All icon bevels are `bevelWidth` (default 2px); mwm uses 1px for icon shapes regardless of frame bevel size

**Severity:** MINOR (icons look chunkier than mwm)

**What mwm does:** `WmCDecor.c:2461–2467` (system),
`WmCDecor.c:2527–2533` (minimize), `WmCDecor.c:2597–2603`
(maximize) all hardcode `BevelRectangle(prTop, prBot, x, y, w, h,
1, 1, 1, 1)` — the four `1`s mean 1-pixel bevel widths on all
four sides for the icon shape. This is INDEPENDENT of
`externalBevel` / `joinBevel`. So even with chunky frames, the
small icon shapes always have a 1-pixel bevel.

**What we do:** `MotifFrameView.swift:362–378` —
`raisedTileCentered` calls `raisedTile`, which calls `bevel(...)`
using `bv = MotifTheme.current.bevelWidth` (default 2). So the
inner icon (menu dash, restore/minimize square, maximize square)
gets a 2-pixel bevel — twice mwm's.

**Difference:** Our title-bar icons look thicker / more "raised"
than mwm's. At titleBarHeight=24, mwm's 4×4 minimize icon has 4px
of fill / 1px raised bevel on each side; ours has roughly 1px of
fill and a 2-pixel raised bevel taking up most of the icon.

**Suggested fix shape:** Add a `iconBevel: CGFloat = 1` field to
`MotifTheme`, and have `raisedTileCentered` pass that through to
a dedicated `iconRaisedTile` that uses the per-call width instead
of the global `bv`. Or: have `raisedTileCentered` always use 1px
for the inner bevel and leave the outer button-tile at
`bevelWidth`.

### F6 — Corner grooves are short fixed-length L's; mwm draws a full corner-piece resize handle that's titleBarHeight-sized

**Severity:** MINOR (visible at large title-bar sizes)

**What mwm does:** `WmCDInfo.c:313–333` —
`cornerWidth = TitleTextHeight(pcd) + UpperBorderWidth(pcd)`
(roughly `titleBarHeight + resizeBorderWidth`). At 24-pt title
bar and 5-pt resize border, that's a `29×29` corner piece per
corner. `GenerateFrameDisplayLists` (`WmCDecor.c:600–696`) then
draws StretcherCorner shapes plus BevelRectangle calls along the
N/S/E/W strips between corners. The visible result: a clearly-
defined resize-handle frame with notched corners that any old-
Motif user instantly recognizes.

**What we do:** `MotifFrameView.swift:335–351` —
`drawCornerGrooves` draws 8 short grooves of length `band` (6px
default) at the corners. They visually suggest a resize handle,
but they're tiny — only as long as the band thickness.

**Difference:** Real mwm has chunky L-shaped corner pieces ~30px
on a side. Ours are barely-visible 6px stubs.

**Suggested fix shape:** Make groove length follow
`cornerWidth = bs + band` (matching the existing hit-test span at
`MotifFrameView.swift:569`) so the visual matches where you can
actually grab to resize. Alternatively, port mwm's
`StretcherCorner` shape (`WmGraphics.c:499–833`) directly — it's
a self-contained algorithm and the "lift, don't intellectualize"
memory note applies. The longer grooves DO need to reckon with
the title-bar buttons claiming horizontal space at the top; mwm's
title bar starts BELOW the top corner-pieces because cornerWidth
fits underneath the title bar.

### F7 — Title bar drawn as a free-floating raised tile; mwm draws the title bar integrated with the chrome border

**Severity:** MINOR (small visual difference)

**What mwm does:** `WmCDecor.c:843–860` — the title rectangle
`(x, y, width, height)` lives at
`(upperBorderWidth + (decor&MWM_DECOR_MENU ? boxdim : 0),
upperBorderWidth, ...)`. The bevel widths are
`nTitleBevel = sTitleBevel = eTitleBevel = wTitleBevel = JOIN_BEVEL = 1`
when the window has a resize handle or border (the normal case).
The bevel rectangles are added to the SAME pclient[Top|Bottom]Shadows
display list as the surrounding chrome, so the title bar's edges
join cleanly with the chrome's inner sunken bevel.

**What we do:** `MotifFrameView.swift:268–269` — `raisedTile(ctx,
titleR)` draws a standalone raised tile with a 2-pixel bevel on
all four sides. The top 2-pixel bevel of this tile sits on top of
the inner sunken bevel of the chrome (drawn at line 232), so the
top edge gets a stacked "sunken-then-raised" effect.

**Difference:** Mwm's title bar visually blends into the chrome
border. Ours reads as a distinct raised slab "floating" on the
chrome. Look at any mwm screenshot — the title bar's top edge
shares a line with the chrome's inner edge rather than sitting
above it.

**Suggested fix shape:** Position the title bar at `y = bevelWidth`
(directly inside the OUTER chrome bevel) rather than `y = band + bi`,
and draw only the BOTTOM + side bevels of the title tile (skip
the top bevel since the chrome's outer raised bevel already covers
it). Or, more invasively: refactor chrome+title as a single
slot-based draw that decides per-pixel-row which bevels apply.
This one requires more visual iteration; defer until F1 (active/
inactive colors) is fixed, since both interact.

### F8 — LowerBorderWidth > UpperBorderWidth in the WmRECESSED + no-matte + has-title case isn't modelled

**Severity:** MINOR (matters at large internalBevel; defaults
hide it)

**What mwm does:** `WmCDInfo.c:233–257` — when the frame style is
RECESSED, the matte width is 0, AND the title bar is present, mwm
expands `LowerBorderWidth` by `(internalBevel - joinBevel)` so the
side and bottom borders are thicker than the top (which is taken
up by the title bar). At default `internalBevel=2` and
`joinBevel=1`, this adds 1 pixel to the lower border. So the
left/right/bottom chrome is 1 pixel thicker than the top.

**What we do:** `MotifTheme.swift:34–39` — symmetric insets:
`clientLeftInset == clientRightInset == clientBottomInset == band + bevelWidth`,
and `clientTopInset == band + buttonInset + buttonSize + bevelWidth`.

**Difference:** Mwm has visibly asymmetric border thickness at
the title-bar attachment vs the other three sides. Subtle at 1
pixel default. Would become very visible if a user cranks
`internalBevel` up.

**Suggested fix shape:** Add a `internalBevel` to theme (default
2) and a derived `lowerBandExtra = max(0, internalBevel - 1)`,
expand `clientLeftInset` / `clientRightInset` / `clientBottomInset`
by that amount. Only meaningfully changes geometry if the user
overrides `internalBevel`. Low-priority unless someone files a
bug.

### F9 — Depressed gadget swaps full-bevel colors; mwm keeps outer rim raised and inverts only an inner band

**Severity:** MINOR (press feedback subtly off)

**What mwm does:** `WmGraphics.c:266–461`
`BevelDepressedRectangle` and `WmCDInfo.c:1250`
`*pInvertWidth = 1 + (JOIN_BEVEL(pcd) / 2)` (default = 1). The
outer (`exBevel - in_wid`) rows are drawn as normal raised bevel
and the innermost `in_wid` rows are drawn as INVERTED bevel. The
result: a raised outer rim with a sunken inner edge — the look of
a button pressed in along just its edges. Also the rect gets
shrunk slightly: `*pHeight -= (sBevel - *pInvertWidth)` etc., so
the depressed icon visually settles down + in.

**What we do:** `MotifFrameView.swift:355–360` — `raisedTile(ctx,
r, pressed: true)` swaps the bevel colors WHOLESALE. The entire
2-pixel bevel goes inverted; no outer raised rim.

**Difference:** Our pressed button reads as fully sunken (looks
like the button "fell into a hole"). Mwm's pressed button looks
like the button got pushed in along its edges — a subtler
depressing effect.

**Suggested fix shape:** Implement a `pressed: true` codepath in
`bevel(_:_:topLeft:bottomRight:)` (or a sibling
`bevelDepressed`): for `i in 0..<Int(bv - 1)` draw the OUTER
rows raised (highlight TL / shadow BR), then for the LAST row
draw inverted (shadow TL / highlight BR). That's a 2-pixel-bevel
approximation of mwm's outer-raised-plus-inverted-inner-edge.
Optionally shrink the rect by 1 pixel on the inverted side to
match mwm's settle.

---

## Cosmetic

### F10 — System-menu icon is a centered square dash; mwm draws a horizontal "drawer handle" bar

**Severity:** COSMETIC

**What mwm does:** `WmCDecor.c:2409–2467` `BevelSystemButton`.
For `height >= 14` (default case at any normal title-bar size):

```c
default:
    offset1 = 4;
    offset2 = (height - 4)/2;
    dim1 = width - 8;
    dim2 = 4;
    break;
```

At `titleBarHeight = 24`, this is `offset1=4, offset2=10, dim1=16,
dim2=4` — a 16×4 horizontal bar centered vertically, spanning
~67% of the button width.

**What we do:** `MotifTheme.swift:25–26`:

```swift
public var menuDashW: CGFloat  { round(titleBarHeight * 0.64) }
public var menuDashH: CGFloat  { round(titleBarHeight * 0.18) }
```

At titleBarHeight=24: `menuDashW = 15, menuDashH = 4`. So very
close to mwm's dimensions, but `MotifFrameView.swift:259` draws
it via `raisedTileCentered`, which centers the 15×4 dash
horizontally INSIDE the 24×24 button, giving a centered dash that
doesn't extend to the button's inner edges.

**Difference:** Mwm's "dash" looks like a drawer-handle: a bar
stretching nearly all the way across the button, edge to edge
(with `offset1 = 4` pixels of inset). Ours is a small centered
hyphen.

**Suggested fix shape:** Either compute `menuDashW` from
`(buttonSize - 2*4)` to match mwm's edge-inset model, or override
the X-center math in `raisedTileCentered` for the menu button so
it spans `buttonSize - 8` instead of `menuDashW`. Closely related
to F5 (icon bevel width); both should land together.

### F11 — Title-text padding/inset constants differ slightly from mwm's

**Severity:** COSMETIC

**What mwm does:** `WmCDecor.c:1127–1134` — title text inset from
the FRAME_TITLE rect is `WM_TOP_TITLE_SHADOW + WM_TOP_TITLE_PADDING
= 1 + 1 = 2` on top and left, with the box dimensions reduced by
`(top+bot)*2 = 4` on each axis. (`WmGlobal.h:287, 292–295`.)
Text drawn via `WmDrawXmString` (CDE dtwm) or `DrawStringInBox`
(plain mwm).

**What we do:** `MotifFrameView.swift:303–331` `drawTitleText` —
when title fits, center via `(rect.midX - sz.width/2, rect.midY -
sz.height/2)`. When it doesn't fit, left-align at
`rect.minX + bv` (where `bv = bevelWidth = 2`).

**Difference:** Mwm's text effective bounding box is `rect.inset(by: 2)`
(roughly); ours is `rect` (clipped to it). Mwm also positions text
at `pbox->y + pfs->ascent` (top + ascent); we use `rect.midY - sz.height/2`
(vertical center on text bounding box). For most fonts the latter
is correct, but for fonts with unusual ascent/descent the visual
baseline may shift by 1-2 px.

**Suggested fix shape:** Apply a 2-pixel inset to the text-clip
rect to match mwm's padding. The baseline positioning is probably
fine for our system font; investigate only if specific apps
report misalignment.

### F12 — No matte (`pcd->matteWidth`) support

**Severity:** COSMETIC

**What mwm does:** `WmCDecor.c:950–993` and `WmGlobal.h:289`
(`FRAME_MATTE_SHADOW_WIDTH = 1`). The matte is an
optional inner bevel between the chrome border and the client
area, drawn on the base window. Configurable via per-window
`matteWidth` resource (default 0). Common in some Sun-distributed
mwm setups but rare in modern Motif apps.

**What we do:** Nothing. `MotifTheme` has no matte field;
`MotifFrameView` draws no matte.

**Difference:** A user who sets `Mwm*ClientName*matteWidth: 4` in
their resource file won't get the matte. They will get the same
chrome regardless.

**Suggested fix shape:** Skip until requested by a user. Low
value; almost no real-world apps depend on the matte. Note in
SHORTCUTS.md if needed.

### F13 — `MWM_DECOR_BORDER`-only is not distinguished from `MWM_DECOR_RESIZEH` in our chrome

**Severity:** COSMETIC

**What mwm does:** `WmCDecor.c:697–774` `GenerateFrameDisplayLists`
has a distinct path for `MWM_DECOR_BORDER` (without RESIZEH): it
draws a single outside BevelRectangle of width `2,2,2,2` (or
`FRAME_EXTERNAL_SHADOW_WIDTH` under WSM) and then an inside
BevelRectangle of width `insideBevel`. No StretcherCorner pieces,
no resize-handle visuals.

**What we do:** `MotifFrameView.swift:223–235` draws the same
chrome (outer raised bevel + inner sunken bevel + 4 corner grooves)
regardless of whether RESIZEH is set or only BORDER is set. The
chrome-resize-grooves give the "resize handle" look even when the
client requested non-resizable.

**Difference:** A client requesting `BORDER | TITLE` (without
RESIZEH) will still see our resize-handle-style corner grooves,
incorrectly suggesting it can be resized. (We DO drop the
`.resizable` styleMask elsewhere — the grooves are just visual
lying.)

**Suggested fix shape:** Skip `drawCornerGrooves` when the
effective decorations contain BORDER but not RESIZEH. Trivial
guard at `MotifFrameView.swift:234`.

### F14 — Shaped-client title-bar geometry has small offset mismatch from mwm

**Severity:** COSMETIC

**What mwm does:** `WmCDecor.c:2895–2902` `SetFrameShape` — for
shaped clients with a title, the title window's shape (which is
`(width - 2*upperBorderWidth) × titleBarHeight` at offset
`(upperBorderWidth, upperBorderWidth)`) is OR'ed into the frame's
bounding shape. The title widget is a CONTIGUOUS rectangle that
includes the menu/min/max button areas.

**What we do:** `MotifFrameView.swift:217–221` clears the bounds
then calls `drawTitleBar`, which draws the buttons at `(band+bi,
titleRowY) = (8, 8)` and the title rect between them. The areas
above the title (y < titleRowY) and outside the title's left/right
extents at the top of the frame are left transparent.

**Difference:** Our shaped-client title starts at `y = titleRowY
≈ 8` while mwm's title-window rectangle starts at
`y = upperBorderWidth ≈ 5` (varying by DPI). Small (3-pixel)
visual offset compared to a Sun-mwm screenshot. Also: real mwm's
title-window is a single solid rectangle (drawn before per-button
bevels), so the inter-button gaps are FILLED with the title bg.
In our code the inter-button gaps DO get the
`raisedTile(ctx, titleR)` fill, so this is fine for the cases I
checked — the offset is the only visible drift.

**Suggested fix shape:** Optionally inset the title bar more
tightly when `clientIsShaped`, or position it at `y = bevelWidth`
to match mwm's `upperBorderWidth` more closely. Defer unless an
oclock/xeyes screenshot shows a clear delta vs Sun gold.

### F15 — Button-hit-test corner span uses `bs`; mwm uses `cornerWidth` which scales with frame as well

**Severity:** COSMETIC

**What mwm does:** `WmCDInfo.c:780–800` `GetFramePartInfo` for
FRAME_RESIZE_NW returns
`cornerWidth × cornerHeight` (with a fallback to "grow the corner
piece" when the side runs would be tiny). `cornerWidth =
TitleTextHeight + UpperBorderWidth`. Roughly `24+5 = 29` at
default scale.

**What we do:** `MotifFrameView.swift:569` —
`let cs = band + bi + bs = 6 + 2 + 24 = 32`. So we use the FULL
button size for the corner-resize zone.

**Difference:** Close in absolute terms (29 vs 32), but our value
DOESN'T shrink for small windows the way mwm's does. Mwm caps
`cornerWidth = frameWidth / 3` (`WmCDInfo.c:325`) for tiny
windows, so a 60-pixel-wide frame still has resize edges. We'd
have `cs = 32` always, so on a 60×60 window the entire frame is
corner-resize area, no edge-resize areas at all (which actually
isn't terrible since corner is more useful at that size, but it's
a divergence from mwm).

**Suggested fix shape:** Compute `cs = min(band + bi + bs,
bounds.width / 3, bounds.height / 3)` to mirror mwm's downscale.
Won't be visible at common sizes; only matters for tiny windows.

---

## Things we do better than mwm

- **Half-pixel-blur prevention**: `MotifFrameView.swift:362–378`
  uses `floor()` to snap centered-icon offsets to integer pixels.
  Mwm doesn't need this because X11 fills are inherently integer
  (no subpixel coords), but AppKit's coordinate space is
  floating-point and will rasterise blurry without this snap. The
  comment at lines 364–371 captures exactly why this matters.
- **Honest shaped-client handling**: `MotifFrameView.swift:217–221`
  cleanly omits the chrome rather than mwm's "draw the chrome but
  silently make the resize handle non-functional" punt
  (`WmCDecor.c:2854`). Ours is more visually honest about what
  the user can interact with.
- **Decoration-bit gating with title-bar extension**: the
  `titleBarRect()` logic at `MotifFrameView.swift:171–188`
  (added 2026-06-13) extends the title strip into the freed-up
  corner when a button is hidden via `_MOTIF_WM_HINTS` — mwm
  leaves those areas BLANK (FRAME_TITLE width is computed as
  `frameInfo.width - 2*upperBorderWidth -
  (decor&MENU?boxdim:0) - (decor&MIN?boxdim:0) - (decor&MAX?boxdim:0)`
  at `WmCDInfo.c:722–726`, so it shrinks the title rather than
  expanding it). Our behavior is arguably tidier, and the test
  case in `MotifFrameViewGeometryTests.swift:78–101` documents
  it. Worth keeping if it matches the user's intent — but note
  this is a deliberate divergence from mwm.

---

## Pointers to the source files I read for each finding

- **mwm geometry**: `reference/motif/clients/mwm/WmCDInfo.c:100–660`
  (TitleTextHeight, UpperBorderWidth, LowerBorderWidth, FrameWidth,
  FrameHeight, CornerWidth, CornerHeight, BaseWindow*, FrameX/Y),
  `WmCDInfo.c:670–962` (GetFramePartInfo).
- **mwm drawing**: `reference/motif/clients/mwm/WmCDecor.c:560–994`
  (GenerateFrameDisplayLists),
  `WmCDecor.c:2381–2603` (BevelSystemButton, BevelMinimizeButton,
  BevelMaximizeButton),
  `WmCDecor.c:2607–2726` (DepressGadget / GetDepressInfo).
- **mwm bevel primitive**: `reference/motif/clients/mwm/WmGraphics.c:80–461`
  (BevelRectangle + BevelDepressedRectangle).
- **mwm resize-handle corner shape**: `reference/motif/clients/mwm/WmGraphics.c:466–833`
  (StretcherCorner).
- **mwm shape**: `reference/motif/clients/mwm/WmCDecor.c:2832–2920`
  (SetFrameShape).
- **mwm focus / active state**: `reference/motif/clients/mwm/WmCDecor.c:202–267`
  (FrameExposureProc), `WmCDecor.c:2052–2247`
  (ShowActiveClientFrame / ShowInactiveClientFrame).
- **mwm system menu (button single-click posts the menu)**:
  `reference/motif/clients/mwm/WmEvent.c:700–810`
  (system-button press/release dispatch),
  `WmFunction.c:3040–3150` (F_Post_SMenu).
- **mwm color defaults / formula**:
  `reference/motif/clients/mwm/WmResource.c:586–589`
  (`_defaultColor1 = LightGrey`, `_defaultColor2 = CadetBlue`,
  HEX `#A8A8A8` / `#5F929E`),
  `WmResource.c:4900–4970` (frameBorderWidth / resizeBorderWidth
  dynamic defaults),
  `reference/motif/lib/Xm/Color.c:683–960`
  (CalculateColorsForLightBackground / DarkBackground /
  MediumBackground),
  `reference/motif/lib/Xm/ColorP.h:50–90`
  (XmCOLOR_*_TS_FACTOR / BS_FACTOR / luminosity weights).
- **mwm decoration bit handling**:
  `reference/motif/clients/mwm/WmWinInfo.c:4068–4093`
  (MWM_HINTS_DECORATIONS interpretation).

## Our code touched in the audit

- `Sources/SwiftXServerCore/MotifFrame/MotifFrameView.swift`
  (627 lines, read fully).
- `Sources/SwiftXServerCore/MotifFrame/MotifTheme.swift`
  (98 lines, read fully).
- `Sources/SwiftXServerCore/MotifFrame/MotifWindow.swift`
  (49 lines, read fully).
- `Sources/SwiftXServerCore/WMHints.swift` (lines 85–155, for
  `MotifWMHints` semantics).
- `Tests/SwiftXServerCoreTests/MotifFrameViewGeometryTests.swift`
  (read setup + first 100 lines, for context on the
  decoration-bit cases the existing test pins).
