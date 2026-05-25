# Resize and redraw: the minimal-spec position

Status: SHIPPED 2026-05-25 after both background agents (thesis-validation
and 3-way MIT/XQuartz/us comparison) reviewed and concurred, with the two
carve-outs documented below. The thesis below is preserved as authored;
the post-review carve-outs and reframing are appended at the bottom.

Originally authored as the close-out of two days of bit-preservation
thrash that ended with the SlateBlue bleed in quickplot and the revert
of every descendant-level optimization.

## The thesis

**Strip every bit-preservation optimization beyond what the X protocol
itself defines as content-generation. Honor only the spec's mandatory
contract: bg-paint on newly-viewable regions, Expose for regions the
client must redraw, ConfigureNotify before Expose. Trust the client
toolkit to redraw on Expose. Advertise `backing-store=NotUseful` and
`save-unders=false`, which is what we already advertise — but actually
ship code that matches that advertisement.**

The reasoning is below. The proposed code changes follow.

## Why the optimizations existed

Three pieces of bit-preservation work landed during the May 19→25 push:

1. **2026-05-19 `ef0d6eb`**: `paintRectsForWindow` on `(sizeGrew || posChanged)`
   in `handleConfigureWindow`. Wrote: "the X server owns window-bg painting
   on every visibility transition." Subsequently scoped down to `sizeGrew`
   on 05-25 after dtpad regressed, then to `sizeChanged` once we saw xcalc
   needed it on shrink. The descendant-side painting works today.

2. **2026-05-25 `c59133f` (Step 1)**: NorthWest blit in
   `FlippedXView.resizeBacking`. Preserves the upper-left `min(old, new)`
   rect of the backing bitmap across NSWindow resize. Local Mac-compositor
   latency-hiding — invisible to the X protocol. Always-on.

3. **2026-05-25 descendant bit-gravity blit (reverted)**: tried to preserve
   each widget's pixels across pure-move via per-window blit. Commits
   `bc75692`, `6434c3e`, `0a0a152`, `4031fdb`, all reverted in `1c66da2`
   after the quickplot SlateBlue bleed surfaced.

The motivation in each case was "the toolkit (Xt's `Intrinsic.c:217-222`
sets `bit_gravity = NorthWestGravity` on every Manager) is counting on us
to preserve bits — let's honor that to avoid forcing toolkit-side redraws
on every resize."

## Why that reasoning is wrong for our setup

Three observations have accumulated:

### 1. The toolkit redraws fast over LAN

Empirical: Motif windows on Todd's setup come up nearly instantly when an
Expose hits them. The 50–200ms latency window I kept worrying about isn't
the typical case. The Sun's CPU is faster than a 1990s SS2 for many of these
apps, the LAN is gigabit, and toolkit Redisplay paths are tight loops of
draw calls that pipeline well over TCP.

Even if there's a 50ms flash on every resize-end, the user is mid-drag —
they're not looking at the chrome, they're focused on the act of resizing.
By the time they let go and look, the redraw has completed.

### 2. `bit_gravity = NWG` is a HINT, not a requirement

X11 spec, section on Window Resizing: every Expose handler must be prepared
to redraw at any time, regardless of `bit_gravity`. Clients DO rely on
preservation when the server provides it, but they ALWAYS handle the case
when it doesn't. The X11R6 server's gravity preservation is an optional
optimization, not a correctness requirement.

The reverse-engineered comment in Xt's `Intrinsic.c` ("Try to avoid
redisplay upon resize") is best-effort. The Athena and Motif widget
classes that genuinely depend on bit preservation also set ForgetGravity
explicitly when they can't tolerate stale bits (ScrollBar, DrawnButton,
Scale per the 2026-05-25 gravity survey).

### 3. Our optimization attempts cost more than they bought

Two days of cascading bugs from descendant-level preservation:
- dtpad menu-bar erase on dialog popup (took two reverts to unstick)
- xcalc button-clipping (only fixed by adding bg-paint on shrink)
- quickplot SlateBlue bleed (no clean fix found; we reverted)
- dtpad text-area paint loss on resize (Gap B, still open)

Each of these came from preserving bits and then either (a) painting over
them transiently, (b) painting where bits shouldn't have been preserved, or
(c) failing to paint where bits were never valid. The bug surface scales
with how aggressively we try to preserve.

## What the X protocol actually requires of a server

Mandatory:

1. **Bg-paint on newly-viewable regions.** When a window region becomes
   visible — first map, uncovered by sibling unmap, grown by parent resize —
   the server paints the bg pixel (or ParentRelative-walks for inherited
   bg). The client only paints content on top.

2. **Expose for newly-viewable regions.** Server tells the client which
   regions need redrawing. Client redraws via its toolkit's Redisplay.

3. **ConfigureNotify before Expose.** Geometry changes signaled before the
   client is expected to repaint at the new geometry.

4. **Client-driven CopyArea / CopyPlane.** These are content-generation
   operations the client emits to build its rendering. Mandatory to honor.

Optional (we don't currently implement; we advertise we don't):

- `backing-store = WhenMapped | Always` — preserve content across visibility
  changes (window obscured then uncovered)
- `save-unders = True` — preserve underlying windows' bits when a save-under
  window maps over them; restore on unmap
- `bit_gravity` preservation per-window across the window's own resize/move
- `win_gravity` automatic child sliding on parent resize

## What we should ship

The minimal-spec position is exactly the X protocol's mandatory contract
plus one local-Mac-compositor trick that's invisible to the protocol:

### Keep

- `paintRectsForWindow` and the bg-paint contract for newly-viewable
  regions. Mandatory.
- `Expose` emission for newly-viewable regions. Mandatory.
- ConfigureNotify before Expose, per ICCCM §4.1.5 and the standard
  X11 dispatch ordering. Mandatory.
- Client-driven `CopyArea`, `CopyPlane`, etc. Mandatory.
- `Step 1` NW blit in `FlippedXView.resizeBacking` — see "Step 1 is
  defensible" below.

### Strip

- The `handleTopLevelResize` cascade that walks every mapped descendant
  and paints its bg + emits Expose. Was designed for "bitmap wipe →
  full toolkit redraw" model. With Step 1 doing the bitmap preservation,
  this cascade now fights Step 1's preservation by over-painting. After
  Step 1 lands, the top-level only needs Expose for its own L-shape
  (the newly-claimed pixels). Descendants get Expose via their own
  per-descendant `ConfigureWindow` processing, which the toolkit drives.

- All per-window `bit_gravity` preservation. We advertise we don't do it.
  Toolkit handles Expose-driven redraw. Less code, less bug surface.

- All per-window `win_gravity` automatic sliding. Toolkit sends
  XConfigureWindow per child explicitly. We process each. End state is
  the same; the toolkit's wire traffic is slightly higher.

- The `paintRectsForWindow` call on descendant `sizeChanged` is more
  subtle. Today this handles xcalc's button-border-on-shrink. If we strip
  it, we'd need to verify that xcalc's Athena Command widget redraws its
  border on Expose. Probably does; needs verification.

### Don't add (but flag for future)

- **`save-under` for popup menus.** Highest-value missing optimization —
  Motif menu dismissal would feel instant instead of 100ms of toolkit
  redraw. Same shape as Step 1 (local latency-hiding) but at the
  X-protocol level. Build only when a specific app surfaces the latency
  cost.

- **Per-window `backing-store=WhenMapped`.** Probably never; expensive
  for marginal real-world wins. Save-under handles the dominant case
  (menu popups).

### Step 1 is defensible

Step 1 isn't an X-protocol-level optimization. It's local-Mac-compositor
latency-hiding for the case where the NSWindow's bitmap gets reallocated
by AppKit and the Sun client hasn't yet redrawn for the new geometry.
Without it, every resize causes a visible white flash from bitmap
reallocation. With it, content stays on screen during the gap.

- Costs: ~50 lines, simple math, no clipList interactions, no per-window
  semantics.
- Benefits: hides any latency between Mac resize and Sun redraw. Bounded
  by Sun responsiveness; degrades gracefully (a slow Sun shows old bits
  longer; not "white flash for 30 seconds during a network blip").

Step 1's bug risk is low — it's a single CGContext.draw call with simple
math. The bugs we hit during the May 25 thrash were in the **descendant**
preservation work, not in Step 1 itself.

## Alignment with what we advertise

`SetupAccepted` advertises `backingStores = .never` and `saveUnders = false`.
Today we slightly outperform this advertisement (Step 1 preserves some
bits, the cascade in handleTopLevelResize over-paints in ways that
sometimes preserve). After the strip:

- We advertise NotUseful → we ship NotUseful at the X-protocol level
- Step 1 stays as local Mac-compositor work, not protocol-level
  preservation. Invisible to clients.

The two are honest after the strip. Today they aren't quite.

## What this trades

- **Lose**: the ~50ms toolkit redraw saved when a NWG container resizes.
  Tile-vertical-stack of windows, the redraw is fast enough that the user
  doesn't notice. Net zero perceived cost.

- **Lose**: the partial bit-preservation that handleTopLevelResize's
  cascade was accidentally providing (where its over-paint didn't fully
  wipe Step 1's preserved bits). Was load-bearing for some edge cases we
  hadn't named explicitly.

- **Gain**: every resize/move bug we've fought maps to "did we emit Expose
  and paint bg correctly?" rather than "did we preserve the right bits?".
  Single canonical question.

- **Gain**: ~200 lines stripped (handleTopLevelResize cascade, `paintRectsForWindow`
  call on descendant ConfigureWindow that's solely for non-grow cases,
  `mappedBackgroundPaints` walk).

- **Gain**: no descendant bit_gravity / win_gravity to implement (Gap A
  and Gap B both close as "not load-bearing").

- **Stay solid**: client-driven rendering, Motif containers, Athena
  widgets, xcalc / xterm / dtpad / dthelpview / dtcalc / dtterm / quickplot
  all work. They were working before any optimization landed; they keep
  working without one.

## Open questions

1. Does stripping `paintRectsForWindow` on descendant sizeChanged regress
   xcalc's button-border-on-shrink? Need to verify Athena Command's
   Redisplay paints its own border or relies on server bg-paint contract.

2. Is there a slow-Sun scenario where Step 1's preservation is the
   difference between acceptable and broken? Probably not for our typical
   testbed; could become relevant for remote Sun over WAN.

3. Should `mappedDescendantSnapshots`'s Expose cascade stay (for the case
   where descendant clipLists genuinely grew due to top-level grow) or go
   (let the toolkit's ConfigureWindow cascade drive it)? Probably stays,
   but only emits Expose for the actual L-shape delta, not full clipList.

## Outstanding small bugs that this thesis doesn't address

- dtpad menu-bar erase on dialog popup. Pre-existing, separate code path
  (dialog map/unmap), unaffected by resize work.
- Horizontal scrollbar reverse-image. Pure rendering, multi-app, separate.
- dtpad small artifacts between text area and frame on grow. Probably the
  scrollbar-arrow sub-widget repaint case. Separate.

## Done state

When this lands:

- `handleTopLevelResize` is ~30 lines instead of ~60. Emits ConfigureNotify,
  recomputes clips, emits Expose to top-level for L-shape only.
- `handleConfigureWindow` doesn't paintRectsForWindow on sizeChanged.
  Only emits ConfigureNotify and Expose.
- `FlippedXView.resizeBacking` keeps its NW blit. Comment block updated
  to mention the thesis.
- DECISIONS.md gets a 2026-05-25 close-out: "Strip bit-preservation
  optimizations; honor minimal spec contract."
- SHORTCUTS.md gets the bit_gravity / win_gravity / per-window backing-store
  entries removed (they were aspirational, never implemented).
- STATUS.md updated.

Total code delta: ~200 lines net removal, no new features, no behavior
changes for the apps we test today.

---

## Post-review amendments (2026-05-25)

Two background agents reviewed this thesis:

- **3-way comparison agent** (MIT X11R6 vs XQuartz vs us) returned with
  strong external validation: XQuartz has been shipping this exact
  architecture for ~20 years. `RootlessNoCopyWindow`
  (`reference/xquartz-xserver/miext/rootless/rootlessWindow.c:635`) is
  literally a no-op CopyWindow callback. Modern xorg-server defaults to
  `backingStoreSupport = NotUseful` (`dix/window.c:646`),
  `saveUnderSupport = NotUseful` unconditionally. The X11R6 `Always`
  default was abandoned a long time ago. We're matching the
  deployed-software consensus.

- **Thesis-validation agent** stress-tested every claim against the X
  spec, our code, and the apps we host. Found two specific holes
  documented below.

### Reframe: not "underperforming spec" — "matching deployed consensus"

The thesis original framing ("today we slightly outperform our
advertisement; after the strip, we'll exactly match it") undersells the
position. Every macOS-aware X server has shipped this approach for a
decade. Per-window bit-preservation is economically rational only in
single-framebuffer designs where preserving bits is free (one bitmap, in-
memory blit). We aren't in that architecture. XQuartz isn't either.
XQuartz's answer is `RootlessNoCopyWindow`; ours should be the same.

### Carve-out 1: KEEP `paintRectsForWindow` on descendant `sizeChanged`

The thesis's "Strip" list named "the `paintRectsForWindow` call on
descendant ConfigureWindow that's solely for non-grow cases" as a
removal target. Both agents flagged this is load-bearing:

- Athena Command's `Redisplay` (`reference/X11R6/xc/lib/Xaw/Command.c:396-472`)
  paints an INTERIOR highlight rectangle (offset+inset draw of the
  command rect) but NOT the X-window border itself.
- The 1-pixel CWBorderPixel ring around the X window is **server-painted
  per the bg-paint contract**.
- Xt Core's `borderWidth` defaults to 1; xcalc's Command widgets inherit
  that default (no XCalc.ad override).
- Without `paintRectsForWindow` on `sizeChanged`, xcalc on shrink shows
  exactly the 2026-05-25 symptom: "button surrounds are either not there
  at all or only the top-left is partially rendered." Step 1's NW blit
  preserves the OLD position's border-ring pixels; the new (smaller)
  position has no fresh server-painted ring.

So `paintRectsForWindow` on `sizeChanged` stays in `handleConfigureWindow`.
The original commit `25c3822` that added this on shrink was correct;
keep it.

### Carve-out 2: KEEP `mappedDescendantSnapshots` Expose cascade

The thesis assumed descendants would get Expose via their own per-
descendant `ConfigureWindow` processing after the toolkit's Resize
cascade. The validation agent found this is **only true for descendants
whose geometry actually changes**:

- Xt's `XtResizeWidget`/`XtConfigureWidget`
  (`reference/X11R6/xc/lib/Xt/Geometry.c:434-585`) gate the
  `XConfigureWindow` wire call on `req.changeMask != 0` — i.e., only
  emit when w/h/x/y differ.
- For a NorthWest-anchored container (Athena Form, Motif RowColumn,
  BulletinBoard), TOP-LEFT children typically don't move OR resize on
  parent grow. The geometry manager's per-child loop is a no-op for
  them — zero wire traffic from the toolkit.
- Without our cascade Expose, those NWG-anchored children get no
  wake-up call when the top-level's bitmap was reallocated. Their
  preserved bits from Step 1 will look right if the bitmap survived,
  but any client-side state that needed re-derivation against the new
  parent dimensions won't fire.
- Practically: keep the Expose cascade as insurance for the case where
  the toolkit's per-child wire traffic doesn't tell those NWG children
  anything happened.

So `mappedDescendantSnapshots` and its Expose loop stay. Only
`mappedBackgroundPaints`'s descendant walk is stripped from the resize
path. (The function itself stays — used by MapWindow paths.)

### Future enhancement (flagged, not built)

**Per-resize-edge gravity in Step 1.** XQuartz's `ResizeWeighting`
(`reference/xquartz-xserver/miext/rootless/rootlessWindow.c:765`)
computes which corner stayed pinned during the resize (NW/NE/SE/SW)
based on AppKit's resize-edge metadata and feeds the resulting gravity
to Quartz as `xp_window_changes.bit_gravity`. Drag the bottom-right
corner outward → pin top-left (current Step 1). Drag the top-left
corner inward → pin bottom-right.

We always pin top-left. For most user-driven resizes (drag right edge,
drag bottom edge, drag bottom-right corner), top-left is correct. For
top-left-corner drags, we visually "slide" content during the drag. Not
load-bearing for any current bug; cheap future win.

### Final landing position

`handleTopLevelResize`:
- Emit ConfigureNotify on top-level ✓
- `recomputeClipsForSubtreeContaining` ✓
- ~~Cascade `mappedBackgroundPaints` walk over every descendant~~ →
  **paint only the top-level's bg over its own clipList** (one paint
  call). Top-level's `clipList` is "interior minus descendants" so this
  cleanly covers the newly-claimed L-shape without overpainting child
  windows.
- `emitVisibilityChanges` ✓
- `mappedDescendantSnapshots` Expose cascade ✓ (keep — load-bearing per
  validation agent)

`handleConfigureWindow` (descendant path):
- ConfigureNotify ✓
- recomputeClips ✓
- `repaintParentOverUncovered` ✓ (parent paints bg over child's vacated
  area)
- `paintRectsForWindow` on `sizeChanged` ✓ (keep — xcalc border per
  validation agent)
- Expose on `(sizeGrew || posChanged)` ✓
- No bit-preservation blit (already reverted)
- No paint on pure-move (already reverted)

`FlippedXView`:
- `resizeBacking` NW blit (Step 1) ✓ (kept — local Mac-compositor
  latency hiding, invisible to X protocol)
- `layerContentsPlacement = .topLeft` ✓ (compositor-level NWG backstop)
- `draw(_:)` anchors image to top-left via `translate(0, imgPointsH)`
  ✓ (fixed 2026-05-25)

`ServerConfig.SetupAccepted`:
- `backingStores = .never` (unchanged, now honest)
- `saveUnders = false` (unchanged, now honest)

Total mechanical strip: ~20 lines (one cascade call replaced with a
single paintRectsForWindow). The lighter-than-expected delta is because
the bigger surgery the thesis envisioned (per-window bit_gravity, etc.)
was always work we DIDN'T have to do; the actual code change is just
stopping one cascade.
