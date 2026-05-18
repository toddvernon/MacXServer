# Shortcut-mentality audit — synthesis

Written 2026-05-15 after 4 parallel forks landed. Cross-cutting read across
the four `audit_*.md` files, deduped against the existing `SHORTCUTS.md`
ledger (which the forks were forbidden from reading), ranked by severity.

## Headline

The forks turned up **one finding identical to a bug we shipped twice
this week, two findings that corrupt or lie on the wire, and a strong
architectural pattern**. Of the four pattern signatures the audit was
designed to find, the most common across all categories is **stored-but-
inert**: the decoder dutifully reads every bit, the storage holds it,
GetXAttributes round-trips it via tests — but no downstream path
consults the stored value. Tests pass, the wire trace looks honest,
and a real client outside the corpus gets nothing.

## Most pernicious findings — UN-ledgered

Ordered by severity. Numbered to match action items downstream.

### 1. QueryFont has the monospace bug we already fixed twice in QueryTextExtents (load-bearing)

`ServerSession.swift:1973 makeQueryFontReply` returns:
- `minBounds == maxBounds == (lsb=0, rsb=cellWidth, width=cellWidth)`
- `charInfos: []`
- `allCharsExist: true`
- `defaultChar: 32`
- `range minByte2..maxByte2 = 32..126`
- `properties: []` (no FONTPROPS at all — no FONT_ASCENT, FAMILY_NAME,
  DEFAULT_CHAR, AVERAGE_WIDTH, etc.)

Per spec, `charInfos: []` + `allCharsExist: true` means "use minBounds /
maxBounds for every char in range" — only correct when minBounds == maxBounds,
i.e. monospace fonts. For Helvetica oblique 12, width('i') ≠ width('M') ≠
width('l'), and any client that calls `XQueryFont` then uses the returned
per_char array — or even just compares `min_bounds.width != max_bounds.width`
to decide whether to call `XTextWidth` per-string vs assume monospace —
mis-measures.

**Class of client that breaks**: Xt LabelWidget label-truncation,
xfontsel preview pane, xfd, xwininfo `-font`, anything pre-computing text
width via QueryFont rather than calling QueryTextExtents per-string.
quickplot's menu code path almost certainly hits this — the bug Todd
saw might be doubly fixed by getting *both* QueryFont and QueryTextExtents
right.

**Fix-shape**: extend FontResolver.measureTextWidth's path to populate
`charInfos` per glyph (one CHARINFO per char in the encoded range). Emit
the ~14 standard FONTPROPS. Compute `allCharsExist` by checking each
char's Core Text glyph index against 0 (missing-glyph). Range from the
resolved font's encoding (ASCII 32..126 → too narrow; iso8859-1
typically 32..255).

This is the same shape as the QueryTextExtents fix that took two passes.
**Strongly recommend** it's the next thing shipped, before the hardware
verification round on the QueryTextExtents fix.

### 2. ChangeProperty Prepend/Append silently overwrites with wrong type/format (load-bearing — CORRUPTING)

`ResourceTables.swift:561-575 PropertyTable.change` accepts a Prepend or
Append request and keeps the existing entry's `type` and `format`,
ignoring the request's. Spec section 10.10 mandates `BadMatch` when
existing.type ≠ request.type OR existing.format ≠ request.format. We
silently store blended bytes of incompatible formats.

**This is the only finding in the audit that corrupts data on the
server side.** Everything else either ignores a request (latent) or
returns a wrong value (visible). This one accepts the request, stores
mismatched bytes, and the client sees garbled data on the next
GetProperty — with no error to indicate something went wrong.

**Class of client at risk**: Xt's intern-and-append idiom for ICCCM
properties; any selection-handling code that appends to a shared
property; xclock's reset path which appends format=8 to its own
previously-format=32 atom (worth verifying).

**Fix-shape**: at the top of the Prepend/Append branch in
`PropertyTable.change`, return `.mismatch` (new enum case) when
existing.type ≠ r.type or existing.format ≠ r.format. Caller emits
BadMatch.

### 3. GCBits.graphicsExposures stored-but-inert (load-bearing for Athena/Xt)

`GCEntry.values` stores the bit faithfully but `GCState.materialise`
(`GCState.swift:60-78`) never reads it. CopyArea at
`ServerSession.swift:2277` emits `NoExposure` unconditionally — even
when the client explicitly turned graphics-exposures OFF.

**Class of client that breaks**: any client that calls `XSetGraphicsExposures(gc, False)`
expecting *neither* GraphicsExpose nor NoExpose events from CopyArea.
Athena ScrollBar does this; Xt's default GC creation often does too.
The clients ignore the spurious NoExpose harmlessly today, but a
client that does an event-queue poll and assumes "no events => nothing
happened" gets the wrong answer.

**Fix-shape**: add `graphicsExposures: Bool` to GCState; gate the
NoExpose / GraphicsExpose emit in CopyArea on it.

### 4. PolyPoint (64) and CopyPlane (63) not wired in Framer (load-bearing for plotting + bitmap-icon clients)

Neither has a Framer decoder. Both fall through to the unknown-opcode
path → BadRequest. CopyPlane was already flagged in the comparison
study (synthesis #3) and the prior audit; PolyPoint is new.

**PolyPoint is load-bearing for plotting clients** (xmgrace, xfig, any
scatter-plot). The X drawing app that has zero PolyPoint calls is the
exception, not the rule.

**Fix-shape**: PolyPoint Framer struct + handler that translates to
1×1 PolyFillRectangle calls (point-pixel-mode via filled-rect of size
1). CopyPlane is gated on pixmap pixel store; can ship at least the
decoder + spec-correct BadMatch/BadDrawable in the meantime.

### 5. CWBackPixmap / CWBorderPixmap silently dropped on CreateWindow + ChangeWindowAttributes (latent for transparent overlays / Motif textured bg)

Both `CW.backPixmap` (bit 0) and `CW.borderPixmap` (bit 2) are never
read by either handler. The recent CWAttrs sweep (yesterday's commit)
added storage for bitGravity / winGravity / backingStore / etc., but
the two pixmap-source bits were missed.

**Class of client that breaks**: clients that construct a window
expecting `backPixmap = None` (no auto-fill on Expose) — used by
transparent overlay widgets and manual-paint everything clients. Also
xterm's bg-pixmap flip path for inverse-video. Twm-style desktops
that tile the root.

**Fix-shape**: extend the CWAttrs sweep to read CW.backPixmap and
CW.borderPixmap. Store as `backPixmap: BackPixmapKind?` enum:
`.none`, `.parentRelative`, `.pixmap(id)`. Teach windowBackground /
paintRectsForWindow to consult it. Pixmap-tile case needs pixmap
pixel store (separate multi-week project), but `.none` and
`.parentRelative` paths can ship immediately and unblock the
overlay-widget class.

### 6. CWBorderWidth dropped in ConfigureWindow (latent for Motif focus highlight)

`ServerSession.swift:3088-3097` reads x/y/width/height/stackMode/sibling
but NOT borderWidth. `WindowTable.resize` (`ResourceTables.swift:359`)
has no borderWidth parameter. ConfigureNotify reports the old (stale)
borderWidth.

**Class of client that breaks**: Motif's BulletinBoard widget changes
borderWidth on focus changes. xfontsel's info-pane uses
ConfigureWindow borderWidth changes. Both clients we hosted.

**Fix-shape**: add borderWidth to the ValueListReader sweep, plumb
through `WindowTable.resize`, repaint the border ring on change, use
the new value in the emitted ConfigureNotify.

### 7. SetSelectionOwner has no time comparison (latent for multi-client clipboard contention)

`ServerCoordinator.swift:73 swapSelectionOwner` unconditionally
overwrites. Spec 4.2.1: silently ignore when `r.time < prior.time` or
`r.time > serverTime`. The handler at `ServerSession.swift:4364-4400`
never consults the prior owner's stored time. Race-prevention property
gone.

Latent because we're single-client today, but the entire point of
selection time-stamping is multi-client. The day we host two clients
contending for PRIMARY, late-arrival ConvertSelection requests can
clobber a newer owner.

**Fix-shape**: in `swapSelectionOwner`, return the prior state without
mutating if r.time < prior.time or r.time > serverTime. ~5 lines.

### 8. ReparentWindow on a mapped window doesn't unmap-then-remap (latent for Motif re-parent)

Spec section 10.4: ReparentWindow on a mapped window performs an
implicit UnmapWindow, the parent change, then a MapWindow if the window
was previously mapped, emitting UnmapNotify and MapNotify around the
ReparentNotify. `ServerSession.swift:3941-4004` emits only
ReparentNotify and does NOT toggle `entry.mapped` or call the bridge's
unmap/map.

**Class of client that breaks**: any toolkit that re-parents a mapped
widget mid-session, virtual-root WMs.

**Fix-shape**: branch on `entry.mapped`: emit UnmapNotify, mutate
parent, emit ReparentNotify, set `mapped=true` again, emit MapNotify.

### 9. GetMotionEvents lie — advertise=256, return=0

`ServerConfig.swift:147` advertises `motionBufferSize: 256` to the
client at handshake. `ServerSession.swift:4208-4214` always returns
nEvents=0. The handler's own comment claims "swift-x doesn't keep a
motion-event ring (motion-buffer-size is advertised as 0)" — the
comment is wrong about the advertise.

Lie-on-the-wire contradiction. Cheap fix: drop motionBufferSize to 0
in setup. Honest fix: sample pointer motion into a ring buffer (~50
lines).

### 10. GetPointerMapping reports 3 buttons (load-bearing for scroll-wheel handling)

`SynthesizedFonts.swift:152 DefaultPointerMap.map = [1,2,3]`. macOS
scroll-wheel events translate to X buttons 4/5 elsewhere in our event
path, but clients that probe `XGetPointerMapping` to decide whether to
handle button 4/5 (xterm `-mc on` mode, dt's wheel-scroll, any modern
plotting client) skip wheel handling because the map says "3-button mouse."

Also: SetPointerMapping is silently dropped — stored-but-inert. A
left-handed user can't swap LMB/RMB.

**Fix-shape**: report at least 5 buttons (1..5 identity). Persist a
mutable mapping on the session, honor SetPointerMapping.

### 11. RotateProperties (114) not wired

Decoder isn't in `Sources/Framer/Requests/Request.swift`; falls through
to BadRequest. Used by Xt for cycling icon-name properties and by some
twm-era utilities.

**Fix-shape**: write the decoder + handler. Spec says rotate a list of
N atoms' values by `delta` positions, emit PropertyNotify(NewValue)
per atom. ~50 lines.

### 12. CDE palette in ColorTable is fingerprinted to one capture (load-bearing for non-CDE clients)

`ColorTable.swift:70-94` pre-seeds RGB16 values for pixels 0x01-0x17.
The comment block 58-69 literally explains "derived empirically from
dtcalc's CreateGC seqs 119-123 in dtcalc-swiftx.xtap."

Already in SHORTCUTS, but the existing entry frames it as a "hardcoded
approximation of the CDE Default scheme." The audit's sharper framing:
**fingerprinted to a single specific capture**. Right for dt-apps
because it was built from a dt-app trace. A non-CDE client that
AllocColor'd pixel 0x09 from a real Sun and stored it expects exact
CDE-grey RGB — gets our guess.

**Recommend**: tighten the SHORTCUTS entry to call out the
fingerprint-to-capture nature, and document that anything non-CDE
referencing these pixels will get our guess at CDE Default rather
than the actual values from their session. Doesn't need a code change.

## Cross-cutting patterns

### Pattern A: decode/store is faithful; materialise/consume is hand-picked

Universal across the audit. Almost every value-list bit is dutifully
parsed and stashed. Then a handful of materialise-time consumers
(`GCState.materialise`, `windowBackground`, the bridge draw methods)
read only the bits the test corpus actually drives. Everything else is
**stored-but-inert**: tests pass, GetXAttributes round-trips look
honest, real clients depending on the documented effect get nothing.

The fix-shape for the systematic version is architectural:
- `GCRenderState` struct threaded through every bridge draw method
  (replaces the 9 disjoint parameters today), with bridge-side capability
  dispatch (CG blend modes for `function`, CGPattern for tile/stipple,
  CGContext.clip for clip-mask).
- A `materialiseAll` GCState method that reads every bit instead of the
  hand-picked subset, then the consumer chooses which to honor.

### Pattern B: empty / uniform / defaulted reply forms

QueryFont charInfos=[] + allCharsExist=true → "every char has maxBounds metrics"
QueryKeymap → all zeros
QueryExtension → present=false always
GetMotionEvents → nEvents=0 always
ListInstalledColormaps → [default] always
GetPointerMapping → [1,2,3] always

Each is plausible-shaped on the wire. Each shipped because the populated
form needed work the corpus didn't punish. Each surfaces the moment a
client probes the populated case — and the audit specifies exactly which
class of client triggers each.

### Pattern C: dangerous corpus-matches cluster in two zones

The constants audit identified font-metrics replies (frozen monospace
assumption) and the CDE palette (capture-fingerprinted RGB) as the two
zones where corpus-matching is most dangerous. The handshake constants
in ServerConfig (resource IDs, vendor, releaseNumber) are corpus-matches
by design and harmless — risk lives inside per-request reply
construction, not handshake state.

### Pattern D: substructure-redirect entirely absent

Anywhere the spec says "if parent has SubstructureRedirectMask, redirect
to the manager," we apply the request unconditionally. MapRequest and
ConfigureRequest emission do not exist anywhere in the codebase.
Invisible single-client today; blocks any "swift-x runs under a WM"
scenario. Worth flagging in DECISIONS / the "non-goals" framing rather
than treating as a fix.

## Confirmations of already-ledgered items

These showed up redundantly in the audit because the forks couldn't read
SHORTCUTS. Listing here so the synthesis-vs-ledger differential is clean.
No new action needed.

- CDE palette pre-seed (mentioned above with sharper framing)
- US-ASCII keyboard map (GetKeyboardMapping returns hardcoded layout)
- AllocColor monotonic with no recycle
- PutImage silent-drops pixel data
- Cross-window CopyArea emits BadImplementation
- WarpPointer doesn't move the macOS pointer
- SendEvent doesn't propagate
- TopIf/BottomIf/Opposite stack-modes approximated as Above
- Synthesized xlsfonts is the Phase-1 set

## Prioritized action list

Day-of items that are mechanical and high-leverage:

**Tier 1 — close the bug we shipped twice**
1. **QueryFont per-glyph charInfos** (the recurrence of QueryTextExtents).
   Use `FontResolver.measureTextWidth`'s glyph-iteration path; populate
   charInfos; emit FONTPROPS. Probably ~100 lines + tests.

**Tier 2 — corrupting or otherwise-load-bearing**
2. **ChangeProperty type/format mismatch → BadMatch** on Prepend/Append.
   Single corrupting bug; small fix. ~30 lines + a test.
3. **GCBits.graphicsExposures plumbed through CopyArea**. ~20 lines.
4. **PolyPoint Framer decoder + handler** as PolyFillRectangle of 1×1
   rects. ~50 lines + a test.

**Tier 3 — close known small gaps**
5. **CWBackPixmap / CWBorderPixmap** at least the `.none` /
   `.parentRelative` paths (skip the tile-pixmap case until pixmap
   pixel store lands).
6. **CWBorderWidth in ConfigureWindow** — add to ValueListReader
   sweep, plumb through resize, repaint border ring.
7. **SetSelectionOwner time-comparison gate.** ~5 lines.
8. **GetMotionEvents / motionBufferSize honesty** — drop the
   advertise to 0 in setup. ~1 line.
9. **GetPointerMapping returns [1,2,3,4,5]** plus SetPointerMapping
   honored. ~30 lines.
10. **RotateProperties decoder + handler.** ~50 lines.

**Defer** (multi-day or hardware-bound)
- Architectural GCRenderState refactor (Pattern A fix). Real work,
  significant scope, but unblocks fill-style / stipple / cap-style /
  join-style / function-everywhere as a single ship.
- Pixmap pixel store + CopyPlane decoder + PutImage real impl. Already
  a multi-week project per prior synthesis.
- ReparentWindow unmap-remap. Latent; ship when a toolkit actually
  trips it.
- MapRequest / ConfigureRequest emission (substructure redirect).
  Blocks a WM scenario we don't have.

## What's NOT in this synthesis

- The 4 per-fork audit files (`audit_*.md`) have many more findings,
  including all the cosmetic ones the prioritized list above skips.
  Read them for the long-tail.
- This synthesis didn't re-verify the forks. Each fork did its own
  reading; line-number citations look right on spot-check but a full
  audit-of-the-audit wasn't done.
- No fix shipped yet — this is the synthesis pass only.
