# Status 2026-05-27 — dt-app theme dead-rule sweep; CopyArea y-flip reverted

Cleanup session. Two commits, both pushed.

**Retired dead dt-app dialog-button foreground rules (`9aa90c3`).** Spent
the afternoon debugging dtpad's `save_warn` dialog buttons — none of our
`Dtpad*save_warn*…foreground` rules took, no matter the binding
tightness. Kitchen-sink diagnostic at every level from `*OK.foreground`
up to the fully-tight `Dtpad.save_warn_popup.save_warn.OK.foreground`
all failed to land. A paired `background:MidnightBlue` test also didn't
move. But shape rules (`shadowThickness:8`, `marginWidth:20`,
`marginHeight:15`) DID land and visibly bloomed the buttons. That's the
mechanism evidence: Motif sets dialog-button fg/bg programmatically via
`XmGetColors()` at widget-create time (`XtSetArg` under the hood),
which beats every Xrm rule we can write. Shape rules flow through Xrm
normally because they're not in the auto-color path.

So I pulled every never-firing dialog-button fg rule from both the
seed (`DefaultMotifResources.swift`) and the running config
(`~/.swiftx-resources`): `*XmDialogShell*XmPushButton(Gadget).foreground`,
`Dtpad*save_warn*…foreground`, `Dthelpview*XmPushButton(Gadget).foreground`,
the per-instance Dthelpview close/back/print triple, plus all the
`*fontList` Helvetica-italic companions for those rules. Kept the
font/shape rules that actually work. Dialog buttons now render
Black-on-Gray Motif-fallback, which is SS2 visual parity anyway —
this isn't a regression, it's accurate documentation of what we can
and can't control.

**Sealed off SDT Pixel Set impersonation with a giant banner.**
`installCDECustomizationDaemonImpersonation` in
`SelectionMediator.swift` is dormant (retired 2026-05-18, never
called) but kept reading like current architecture across sessions
and dragging diagnoses back toward SDT-Pixel-Set fixes that don't
apply. Now commented out under a `RETIRED` ASCII banner with an
explicit "ask Todd before considering this" gate. Original doc-block
preserved verbatim as historical citation. New memory
`feedback_sdt_pixel_set_retired.md` plus a CLAUDE.md edit so the
trap can't keep firing.

**Reverted the y-flip in `blitCroppedImage` (`2532ba6`).** `be8fdce`
(2026-05-26) added a local y-flip in `blitCroppedImage` to make
Motif horizontal scrollbar thumb shadows render right-side-up. The
fix applies to **every** CopyArea image blit through that path —
quickplot's button-bar bitmaps (and likely other PutImage-sourced
pixmap copies) now render vertically flipped. Backed out the flip.
Scrollbar thumb shadow bug re-opens with it. The button-bar visual
regression was the larger defect; this is the right trade.

**Root cause is unresolved.** Different upstream pixmap writers
(`FillRectangle` / `PolyLine` / etc. vs `PutImage`) appear to
disagree on row order in the pixmap backing, so no single blit-side
rule can be correct for both. The real fix is to make pixmap
writers consistent in y-orientation. Investigate next session by
diffing the pixel buffer of a `FillRectangle`-built thumb pixmap
against a `PutImage`-built button-bar icon during a fresh quickplot
startup.

## What's still open

1. **Pixmap writer y-orientation inconsistency.** The root cause
   behind the scrollbar-thumb-shadow vs button-bar-bitmap conflict.
   Next session priority. Capture quickplot startup; inspect the
   backing buffers of one `FillRectangle`-populated pixmap and one
   `PutImage`-populated pixmap; identify which writer is producing
   inverted row order; normalize on a single y-down convention.
   Then `blitCroppedImage` gets one rule that's correct everywhere.

2. **Horizontal scrollbar thumb shadow** (re-opened). Top/bottom
   shadow colors inverted on Motif horizontal scrollbar thumbs.
   Will close automatically when (1) is fixed.

3. **Carry-overs from prior status entries** — resize-uncover
   repaint gap (dthelpview thinner buttons after resize, dtpad
   text-area paint loss); framer-shared bug investigation; other
   dt-apps smoke tests post-clipping.

# Status 2026-05-24 — Optional Motif frame; SIGPIPE fix; parked-bug closures

Three things landed today.

**Optional Motif window-manager frame for X top-levels.** Opt-in via
Preferences → Display. Vendored from a separate WindowText prototype
into `Sources/SwiftXServerCore/MotifFrame/` (MotifTheme, MotifFrameView,
MotifWindow + a small Preferences provider). NSWindow content rect grows
by the frame insets so the inner X-client area still equals the
client-requested geometry (ICCCM §4.2.1 reparenting model). Title text
follows real mwm policy (center when it fits, left-align + visual clip
mid-glyph when it doesn't — verified against `motif/clients/mwm/
WmGraphics.c::WmDrawXmString`). Per-window button style toggle between
Motif raised glyphs and Mac traffic lights. FlippedXView grew
`layer?.masksToBounds = true` to fix a latent shrink-overshoot bug that
was hidden by AppKit's native title-bar compositing layer.

**SIGPIPE fix.** `signal(SIGPIPE, SIG_IGN)` at the top of
`ServerEntry.run()`. Latent bug since the listener was written —
`writeAllToSocket` calls plain `Darwin.write()`, so a post-EOF write
returned EPIPE *and* the kernel killed the process by signal. Symptom:
"I quit my X client and the server vanished." Recent timing changes
(GUI redesign + my new Motif close-button → WM_DELETE handshake) made
the race more likely. One-line fix in `Sources/SwiftXServer/
ServerEntry.swift`.

**OSF/Motif source pulled into `reference/motif/`.** Community-
maintained Motif 2.3.x (`https://git.code.sf.net/p/motif/code`,
LGPL 2.1) cloned via `reference/fetch.sh`. ~73MB. `clients/mwm/` is
the canonical standalone mwm (direct ancestor of CDE's `dtwm`); `lib/Xm/`
is the widget library. For the first time we can read what Motif
widgets actually expect from the server. README + SOURCE.md updated.

**Two agent-driven closures**:

- **2026-05-10 "park dt-Motif widget chrome redraw"** — formally closed
  in `DECISIONS.md` 2026-05-24. Symptom ("buttons don't render at all")
  was actually fixed during the 05-13 → 05-18 sweep (VisibilityNotify
  state derived from `borderClip ∩ interiorBox`, QueryTextExtents,
  PolySegment pixmap path, PutImage Bitmap + CopyArea cross-window/
  pixmap, CDE-impersonation retirement). Both background agents found
  explicit closure evidence — no live re-investigation needed.

- **Expose-architecture flooding** — also closed in the same DECISIONS
  entry. Survey of 21 Motif widget classes via `reference/motif/lib/Xm/*`
  showed every Motif widget declares `visible_interest = FALSE`, so
  VisibilityNotify gates nothing on the Motif side. The dominant Motif
  gates are `XtIsRealized` and `MenuShell.popped_up`, both purely
  client-side. Xt's `XtExposeCompressMaximal` (default for every
  manager — BulletinB.c:372, RowColumn.c:837, …) already coalesces our
  per-clip-rect Expose events client-side. Recommendation: keep the
  current model; the visibility-tracking work envisioned in the parking
  decision would have been wasted effort.

**Status of in-flight bugs**: see "What's still open" near the bottom
of this file (updated today). The big remaining real one is the
resize-uncover repaint gap in `ServerSession.handleConfigureWindow`'s
descendant-uncover branch (dthelpview buttons thinner after resize;
dtpad text-area paint loss). Distinct from the now-closed chrome
parking.

# Status 2026-05-22 — x11perf clean sweep + error-path test suite

x11perf survey from the SS2 is 254/254. Every test in the build runs to
completion and reports a number. The three-day push that got us here
was a chain of unblocks: ScreenSaver-trio stubs (107/108/115), GetImage
with ARGB→pixel reverse-mapping, PolyText16+ImageText16 CHAR2B variants,
CopyPlane via a 1-bpp bitmap synthesized from the src ARGB and routed
through the existing PutImage path. Plus a bookkeeping pass that
brought OPCODE_STATUS in sync with the Request enum (14 catch-up rows).

Today's other landing: an error-path test sweep delegated to a worktree
agent, then merged back cleanly. `Tests/SwiftXServerCoreTests/ErrorPathSweepTests.swift`
adds 69 new tests on top of the existing 49 in `XErrorEmissionTests.swift`,
table-driven and grouped by argument type (window, GC, drawable,
colormap, font, cursor, atom). The sweep caught six silent-drop bugs:
ReparentWindow.parent, WarpPointer.srcWindow + dstWindow, GrabButton.confineTo,
AllocNamedColor/LookupColor/QueryColors cmap, and SetSelectionOwner/
GetSelectionOwner/ConvertSelection selection-atom. ReparentWindow was
the worst — it was emitting a ReparentNotify event with the bogus
parent ID embedded in it, a lie on the wire. All fixed with small
validation guards.

The worktree pattern worked well — the sweep ran in parallel with the
user's SS2 x11perf survey without contention. One quirk: the agent
branched from the last committed state, which predated three days of
uncommitted GetImage/CopyPlane/text16 work on main. The merge required
dropping four stale `_RoutesToBadRequest` tests that assumed those
opcodes were still routed through `case .unknown` → BadRequest. The
six dispatcher fixes themselves landed cleanly because they touched
sites that the recent work didn't overlap with.

All 631 tests pass (4 unrelated skipped).

# Status 2026-05-19 — End of day

The X server's bg-paint contract is now honored end-to-end. Three big
visible fixes plus a tooling boost that paid for itself the day it
landed. dthelpview, xterm, and most of quickplot's open plot-window
artifacts all unstuck by a single architectural correction.

## Headline

**Three closes:**

1. **dthelpview renders with proper white DisplayArea and blue form
   border, no leftover blue rectangles after expand.** Root cause was
   two-part: (a) draw ops weren't clipped to the window's visible region
   (`clipList`) so a parent's bg paint or Motif's `ClearArea` on the
   form bled right through descendant windows; (b) `handleConfigureWindow`
   updated geometry + emitted Expose but never painted the descendant's
   bg into newly-claimed pixels, so the form's L-shape of new pixels
   after expand stayed as fresh-bitmap-white.

2. **xterm `-bg black -fg cyan` renders correctly black with cyan text
   on black cells.** `GCState.background` default was `0xFFFFFF`, which
   resolved to whitePixel after the 2026-05-19 (earlier today) ColorTable
   canonicalization. xterm relies on the spec default for GC bg
   (background=1 = blackPixel per X11 spec); we were handing it white.
   One-line fix to GCState; verified live.

3. **Quickplot's plot-window drawing artifacts mostly resolved as a
   bonus.** Todd reports today's bg-paint-contract fixes closed "a lot
   if not all" of quickplot's open plot-window issues. Most likely the
   blue-line-at-y=50 artifact on selected pages (open issue #5 in
   `project_motif_quickplot_status`) — textbook "parent's bg paints into
   descendant area" which is exactly what the new clipList composite-clip
   prevents. Re-verify and formally close next session.

**One architectural unlock:** Todd's "Athena widgets just *were* a
color" observation. Once stated, it became the lens for both fixes
(server owns bg paint on every visibility transition; widgets just
declare bg via CWBackPixel). Memorized as `reference_x11_server_owns_bg_paint`
so future "white where bg should be" bugs route to "find the missing
paint, not the wrong color."

## What landed (with file pointers)

### Bridge-layer visible-region clipping (the dthelpview-content fix)

- `Sources/SwiftXServerCore/DrawTarget.swift` — `.window` case now
  carries `id` alongside `topLevel`/`offsetX`/`offsetY` so the bridge
  can look up per-window clipList.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` —
  `windowClipLookup` closure (set by session, mirrors `pixmapBufferLookup`);
  `withDrawContext` for `.window` targets calls the lookup and sets
  `CGContext.clip` to the clipList rects BEFORE the GC user-clip, per
  X.org `mi/migc.c:miComputeCompositeClip`. New `withClip` overload
  takes both window- and GC-clip args. `clearArea` bridge signature
  changed from single-rect to `rects: [Rectangle]` (session does the
  intersection now).
- `Sources/SwiftXServerCore/ServerSession.swift` — `handleClearArea`
  intersects request rect with `entry.clipList`, passes surviving
  rects to bridge. `paintRectsForWindow` clips inner bg rect to the
  window's clipList. Session registers `windowClipLookup` on the
  bridge at init.
- `Sources/SwiftXServerCore/WindowBridge.swift` — protocol updates for
  new `clearArea` shape + `setWindowClipLookup`. MockWindowBridge
  default-impls updated.

### Paint-on-grow for descendant ConfigureWindow (the dthelpview-form fix)

- `Sources/SwiftXServerCore/ServerSession.swift` `handleConfigureWindow`
  — when descendant grows or moves, calls `paintRectsForWindow` on the
  descendant and emits via `paintWindowRects`, so its bg lands in its
  new visible region before the Expose. Mirrors the X server's
  contract per `reference_x11_server_owns_bg_paint`.
- `handleTopLevelResize` reordered: `recomputeClips` now runs BEFORE
  `mappedBackgroundPaints` (correctness no-op so the top-level's paint
  sees its fresh clipList).
- New `descendantBgPaints(of:byteOrder:)` helper — mirrors the 2026-05-19
  Expose cascade for the non-top-level MapWindow path so the dthelpview
  "children mapped before wrapper shell" pattern paints each descendant's
  bg as the subtree becomes viewable.

### GCState bg default (the xterm fix)

- `Sources/SwiftXServerCore/GCState.swift` — `background: UInt32 = 1`
  (was `0xFFFFFF`). Spec default per X11 protocol §7. The 0xFFFFFF
  sentinel was harmless until the 2026-05-19 ColorTable change pinned
  it to whitePixel.

### ChronoDumper value-list decoders (the tooling that made today fast)

- `Sources/SwiftXCaptureCore/ChronoDumper.swift` — three new inline
  decoders:
  - `decodeWindowAttrs(mask:values:)` for `CreateWindow` +
    `ChangeWindowAttributes` value-lists. Surfaces `bg-pixmap`,
    `bg-px`, `border-px`, `bit-grav`, `win-grav`, `override`,
    `save-under`. The smoking gun decoder — killed three wrong
    hypotheses for the DisplayArea bg in five minutes.
  - `decodeConfigureWindow(mask:values:)` for `ConfigureWindow`'s
    `x`/`y`/`w`/`h`/`bw`/`sibling`/`stack-mode` value-list.
  - `AllocColor` / `AllocNamedColor` reply pixel value formatting
    (`→ pixel=0x10 rgb=(...)`) so we never have to mentally count
    allocations to figure out what pixel `0x13` is.

### Docs / ledgers

- `SHORTCUTS.md` — three new Closed entries (clipping, paint-on-grow,
  GCState bg default). dthelpview cosmetic open entry rewritten —
  bg+aspect-ratio gaps separated; bg now closed, aspect-ratio remains.
  Two new Open entries: `subWindowMode=IncludeInferiors` untracked;
  border-ring rect not clipped to borderClip.
- New memory `reference_x11_server_owns_bg_paint.md` — the
  architectural principle behind both fixes. Linked from MEMORY.md.
- `project_motif_quickplot_status` — 2026-05-19 stamp noting today's
  fixes likely closed open issue #5 (and possibly #4); re-verify next
  session before formally closing.

### Tests

- New `DrawingDispatchTests.testClearAreaClippedByMappedChildren`
  locks in parent-ClearArea-clipped-by-children invariant. Existing
  `testClearAreaUsesWindowBackground` updated (post-fix, unmapped
  windows have empty clipList so the test now maps the window first).
- `CapturedAppReplayTests.testReplayDthelpview` baseline rebased to
  843 requests for the fresh `-manPage`-mode capture taken today
  (previous was 414 pre-`-manPage`; intermediate was 875 from an
  earlier capture).
- 542 total tests pass (294 server + 248 capture/framer), 4 skipped, 0 failures.

## What's still open (next session's queue)

1. **Verify quickplot fixes formally.** Open issues #4 (about-dialog
   animations) and #5 (blue-line-at-y=50 plot artifact) likely closed
   by today's clipping + paint-on-grow work, but unverified
   end-to-end. Should be the first thing — quick visual check on the
   live app, formally close the memory entries if confirmed.

2. ~~**dthelpview aspect ratio wider than SS2.**~~ **Closed 2026-05-20**
   via mean-not-max AVERAGE_WIDTH + Monaco-Bold fallback. See memory
   `project_dthelpview_cosmetic_open` for the FONTPROP spec audit lesson.

3. **Smoke other dt-apps and Motif clients post-clipping.** dtcalc,
   dtterm, dticon — quickplot got bonus fixes, others probably did too.
   Walk through each, note what's improved, what's still off.

4. **Resize-uncover repaint gap.** The 2026-05-10 "park Motif button
   chrome" parking decision is closed (DECISIONS 2026-05-24 — chrome
   renders fine post the 05-13/05-14/05-17 VisibilityNotify +
   QueryTextExtents + PolySegment-pixmap + PutImage/CopyArea fixes,
   and post the 05-18 CDE-impersonation retirement). The residual
   distinct bug is: dthelpview button-bar buttons look thinner after
   resize than before; dtpad's text-area drops content on resize.
   Root is in `ServerSession.handleConfigureWindow`'s descendant-
   uncover branch — not Expose architecture, not PushButton internals.
   Capture u5→swiftx during a dtpad resize and diff Expose against
   gold.

5. **Framer-shared bug investigation.** Deferred again. Still open.

## Working tree at end of day

Two commits today on `main`:

- `ef0d6eb` — Honor X server bg-paint contract: clip draws + paint on
  grow + fix GC bg default (the big one — clipping + paint-on-grow +
  GCState + ChronoDumper value-list decoders + 1 new regression test)
- `44f30ea` — quickplot memory: note that bg-paint-contract fixes
  resolved plot-window artifacts

Six commits ahead of `origin/main` total.

## Reflection

Three lessons from the day worth keeping:

**Tooling pays back disproportionately when it surfaces "what's
actually on the wire?".** The `CreateWindow` value-list decode was 50
lines added to ChronoDumper and immediately killed three hours of
hypothesis-spinning. Yesterday's GC fg/bg decode did the same for the
dtcalc LCD bug. Pattern: when a draw-related bug class shows up,
spend 30 minutes adding the relevant decoder before going deeper —
the diagnosis time saved is huge. Added two more decoders proactively
today (ConfigureWindow value-list, AllocColor/AllocNamedColor reply
pixel) on the same theory. Stopping there per "add when we hit the
same bug shape twice."

**Capture-first / screenshot-diff-first beats speculation every
time.** I went down two wrong paths today (ParentRelative hypothesis;
"the remaining blue strips are correct-by-spec"). Both got killed by
data Todd produced — the swiftx capture for the first, the
SS2/swiftx side-by-side for the second. `feedback_wire_matches_gold`
keeps being right. When I can't explain a pixel, ask for a comparison
shot or a capture before guessing.

**One architectural lens can unify N seemingly-unrelated bugs.**
Todd's "Athena widgets just *were* a color" observation didn't just
explain dthelpview — it instantly told me where the xterm
white-text-bg bug had to be (broken GC bg default; not a paint path
issue). And it predicted quickplot's plot-window artifacts would
close as a side effect. The right lens is force-multiplying; the
memory entry preserves it for the next session that hits a
"wrong-color-where-bg-should-be" symptom.
