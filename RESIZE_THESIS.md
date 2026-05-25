# Resize and redraw: the minimal-spec position

Status: proposal, 2026-05-25. Authored as the close-out of two days of
bit-preservation thrash that ended with the SlateBlue bleed in quickplot
and the revert of every descendant-level optimization.

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
