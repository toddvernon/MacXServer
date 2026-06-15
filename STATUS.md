# Status 2026-06-14

Marathon day, **MacXServer v0.9.5 shipped** (signed/notarized/stapled,
download button live on macxserver.com). Day broke into seven chunks:
shaped-client deform fix in the morning, Motif chrome audit against
mwm source + two MAJOR-severity findings closed mid-day, single-knob
color-derivation refactor in the afternoon, TrueColor cleanup pass in
the early evening (PutImage depth-24, CopyPlane window-depth fix),
CWBackPixmap honoring (xli renders + pans cleanly) in the mid-evening,
pointer/mouse-button rework with new Mouse tab in Preferences in the
late evening, and the first **server-side xterm extension** —
scrollbar widget recognition + button override — as the closing piece.
Two unrelated docs surfaced: Helios mission statement (untracked then,
tracked tonight) for AI-driven dev on vintage Suns via macXserver's
own terminal. 1305 tests green (+12 from morning baseline:
2 PutImage depth-24, 7 CWBackPixmap, 3 Pointer/Mouse config), 27
skipped (unchanged baseline).

## Pointer rework + first xterm server-side extension (late evening)

Started as a "quick wheel-mouse fix" and grew into a small architecture
moment — the first server-side hack that uses macXserver's "we know
what client we're hosting" position to do something X11 protocol
can't express. Bones for a Helios-class feature surface (see
`Helios-Mission.md` tracked tonight).

**Mouse wheel → Button4/5.** `FlippedXView.scrollWheel(with:)`
accumulates `event.scrollingDeltaY` and emits synthetic
Button4 (up) / Button5 (down) press+release pairs at a 10-point detent
threshold, capped at 16 emissions per AppKit event. Horizontal scroll
goes Button6/7. Modern xterm reads natively; vintage xterm needs one
`.Xdefaults` line.

**Per-Mac-button mapping moved out of resources, into a new
Preferences › Mouse tab.** Three popups — Left click, Wheel click,
Right click — each picks what X-protocol action that physical button
performs in content areas. Labels are action-verbs ("Select text",
"Paste selection", "Extend selection / open menu") not button numbers;
the X11 wire numbering stays the server's private business. Default
is identity 1/2/3 for a standard 3-button mouse. UserDefaults-backed,
live-reactive (next click after a popup change uses the new mapping),
with a one-time migration that strips the old `[pointer]` block from
existing users' `~/.macxserver-resources` and translates the prior
`swapButtons23` boolean to the equivalent popup state.

The previous afternoon iteration tried to ship this as a single boolean
in the resource file (`swapButtons23`) but the resource-file UX
surfaced two problems immediately: nobody knows what X11 button
numbers mean, and "the file is the UI" is wrong for something a user
needs to think about. Pulling it into a typed dialog with semantic
labels is the right shape.

**`dispatchCrossWindowDrag` remap bug closed.** Found by capturing
the wire and diffing press/release: with `swapButtons23` on, the press
went through `FlippedXView.dispatchMouse` and got the remap, but the
release went through the bridge's cross-window-drag monitor and used
the RAW button number from `xButton(forNSEventType:)`. Wire ended up
with `ButtonPress(2)` ... `ButtonRelease(3)`, heldButtons never
emptied, implicit grab pinned the scrollbar, all subsequent clicks
got redirected through the stuck grab, double-click-to-close
needed retries. Fix: moved `remapButton` onto `PointerConfig` itself
(single source of truth) and applied it in both code paths. Patterns
match the MIT X server's `dix/events.c ProcessOtherEvent` — one place
swaps physical→logical, everything downstream uses the logical
number.

**Server-side xterm scrollbar extension** (the new pattern). One
Mouse-tab checkbox: "On an xterm scrollbar, any mouse button grabs
the thumb." When on, every click that lands in an xterm-shaped
scrollbar widget gets its wire button rewritten to 2 ("grab thumb")
regardless of the user's per-Mac-button popup mapping. So left-click
still selects text in the xterm content area, but left-click on the
scrollbar grabs the thumb — which X11's flat global pointer mapping
cannot express on its own. The cheating-with-knowledge mechanism:

- Session-level `wmClass == "XTerm"` check (we already track WM_CLASS
  for capture-file naming).
- `isXtermScrollbarWindow(_:)` heuristic at click time —
  width ≤ 25, height ≥ parent.height / 2, x within 2 pixels of the
  parent's left or right edge. Athena renders its 1-pixel border
  outside the geometry rect so xterm's left scrollbar reports
  `x = -1` not `x = 0`; live testing tonight surfaced this and the
  tolerance landed in the same hour.
- `pendingButtonOverrides: [UInt8: UInt8]` maps original-wire to
  effective-wire across the press/release pair, so the rewrite
  survives the gesture (drag off-scrollbar releases still match the
  press's wire button). Generic — any future "server knows X" rewrite
  reuses it.
- Override applied in BOTH `handleMouseEvent` (press / release) and
  `handleMouseDragged` (MotionNotify state-bit) so the wire is
  consistent end-to-end.

Importantly the override gates on `wmClass == "XTerm"` so non-xterm
clients are untouched. New `PointerConfig.xtermScrollbarThumbOverride`
flag, off by default. The whole xterm-extension surface fits in
~50 lines today; the `pendingButtonOverrides` map + the
"`isXtermScrollbarWindow` is the first widget-role inference"
groundwork is the foundation for the next class of hacks (Helios's
"intercept this xterm keystroke and route it to the chat input"
falls out of the same plumbing).

**Helios docs.** `Helios-Mission.md` (untracked all day, tracked in
this commit) captures the larger arc: macXserver owns the xterm fd
and cell grid, so it's the natural home for a Claude-driven dev
workbench targeting vintage Suns. MVP is the hello-world syntax-error
self-correction loop; we're not building it yet, but the
xterm-extension primitives shipped tonight (widget-role inference,
press/release wire rewrites, per-app gating) are exactly what
Phase 0 needs.

## Release: MacXServer v0.9.5 (today)

- Tag: `MacXServer-v0.9.5`. GitHub release at
  `releases/tag/MacXServer-v0.9.5`. Hugo `appVersion` bumped to 0.9.5;
  download button live on macxserver.com.
- Built, signed (Developer ID Application), notarized (notarytool
  --wait), stapled, republished via `./release.sh MacXServer 0.9.5`.
- Diff vs v0.9.4 (which shipped late 2026-06-13): shaped-client deform
  fix (oclock / xeyes), Motif chrome bevel cleanup on shaped clients,
  focus-state coloring across the full chrome (not just title text),
  single-knob color derivation, and the late-06-13 dtpad-settings
  WM_TRANSIENT_FOR fix (`6bdb969`, missed v0.9.4 cut by ~20 minutes).

## Shaped-client deform fix (morning)

Two commits (`02b253a`, `377283d`). Symptom from Todd's 2026-06-13
screenshot: oclock could be resized by dragging the now-transparent
NSWindow edges into non-square bounds, which it drew as an ellipse
with hands extending well past the visible face. xeyes had the same
shape. Two separate things were wrong:

1. **NSWindow let the user resize.** `setWindowBoundingShape` left
   `.resizable` in the styleMask the whole time the client was shaped,
   so AppKit still offered invisible resize zones around the
   transparent edges. Fix: `styleMask.remove(.resizable)` when
   applying a non-nil shape, `insert` when clearing. Matches Sun mwm:
   "you can't make it happen because there's nothing to drag" (Todd
   verified live on u5).
2. **Our title-bar drawing rendered the full outer frame bevel +
   grooves inside the title strip on shaped clients** even though the
   strip should just be the title widget itself. Real mwm shapes its
   frame window to match (client shape ∪ title bar) and draws no
   surrounding chrome (`WmCDecor.c:2854-2911 SetFrameShape`, "currently
   punt on resize handle around the frame"). Fix: when
   `clientIsShaped`, `draw()` just clears the bounds and calls
   `drawTitleBar` — no outer fill, no outer bevel, no corner grooves.
   Title widget renders with its own intrinsic raised bevel.

Cost flagged: real Sun mwm leaves narrow in-title-bar resize handles
at the upper-left / upper-right corners of the title bar. We don't
expose those — shaped clients are fully fixed-size on our side.
Re-adding them is custom mouse handling on the title-bar corners
with an aspect-ratio lock; punted, the visible behavior matches Sun
closely enough for now.

## Motif frame audit (mid-day)

`MOTIF_FRAME_AUDIT_2026-06-14.md`. Forked an agent to audit
`MotifFrameView` against the authoritative mwm source under
`reference/motif/clients/mwm/`. 15 findings: 3 MAJOR, 6 MINOR, 6
COSMETIC. Three of the MAJORs were addressed today:

- **F1 (focused vs unfocused color distinction)** — initially shipped
  in `952fdae` as a 50% title-text blend toward chrome fill. Todd
  said the focus shift wasn't visible enough; expanded into the
  full single-knob derivation (next section) where every chrome
  surface shifts state, not just the title text.
- **F2 (system-menu button behavior)** — mwm's left-corner button
  pops a system menu on single-click; we now require a double-click
  on it to close the window outright. Single-click does nothing.
  Decision per Todd: Mac users already have traffic-light close /
  minimize / zoom via the native title bar, so a Motif pop-up menu
  is redundant. Documented at the call site (`MotifFrameView` mouseUp
  case 0 requires `event.clickCount >= 2`).
- **F3 (maximize state bevel inversion)** — deliberately deferred
  per Todd's explicit "I like the way it works now." mwm inverts
  the maximize button's bevel when the window is zoomed; we don't.
  Skipped on purpose, not an oversight.

The other 12 audit findings (6 MINOR: MWM_DECOR_ALL XOR semantic,
icon-tile bevels 2px vs mwm 1px, corner grooves 6px stubs vs ~30px
L-pieces, etc.; 6 COSMETIC) remain open. None are user-visible
quality issues; the audit doc has the full table for the next pass.

## Single-knob color derivation (afternoon)

`eedcc5f` — `MotifTheme: single-knob color derivation for frame chrome`.
Refactor that replaced four hardcoded color resources with one base
color + derivation math:

**Before**: `Mwm*background`, `Mwm*topShadowColor`,
`Mwm*bottomShadowColor`, `Mwm*title*foreground` all set independently
in the resource file. Focus state shifted only the title text
(50% blend toward chrome fill). The four-key surface tempted
inconsistent edits.

**After**: one `Mwm*background` (active bg). Highlight, shadow, title
text all derived from it via mwm's `XmGetColors`-style blend math
(highlight = 70% toward white, shadow = 60% toward black, title text
= contrast-picked against luminance). Inactive bg derived from
active by blending 50% toward a dark neutral gray — the entire
inactive palette then re-derives from that darker base. Optional
`Mwm*inactiveBackground` override for users who want a specific
inactive shade.

Net effect on focus state: every chrome surface (outer bevels, grooves,
button tiles, traffic-light gradient, title text) shifts together
when the window loses focus, not just the title. Visually obvious
which window is active without squinting.

Implementation:
- `MotifTheme`: new `activeBackground` / `inactiveBackground` fields,
  static derivation helpers (`colors(for:)`, `deriveInactive(from:)`,
  `contrastingTitleColor(for:)`), computed `activeColors` /
  `inactiveColors` returning a new `MotifStateColors` struct.
- `MotifFrameView`: new `private var colors: MotifStateColors`
  accessor that picks active vs inactive based on `isActiveWindow`;
  all 7 chrome draw sites switched from
  `MotifTheme.current.{fill,highlight,shadow,titleColor}` to
  `colors.{...}`. Old title-text dimming logic deleted (per-state
  title color makes it intrinsic).
- `MotifTheme.default` geometry aligned to seed values
  (bevelWidth=1, frameWidth=3, titleBarHeight=26). Previously
  defaults drifted (2/2/32) so commenting out the `[motif-frame]`
  section produced different dimensions than a fresh seed. Now a
  user with no resource file, an empty section, or fully-commented
  values sees identical chrome to a first-launch user.
- Seed `[motif-frame]` block in `DefaultThemes.swift` and Todd's
  existing `~/.macxserver-resources` updated to the new
  single-knob shape (four removed keys → one bg + four geometry).

Trade-off accepted: per-color overrides are gone. If derivation ever
looks wrong, the fix is to tune the formula (everyone benefits), not
override per-site. Backward-compatibility wasn't preserved
deliberately — the old per-color resources are silently ignored if
they're still in a user's file. Doc note in seed explains the model.

## TrueColor cleanup pass (evening)

Closed out the carryover items from the 2026-06-13 TrueColor visual
switch. Five items on the list; landed three with code, audited two
to closure without code changes.

**PutImage ZPixmap depth-24 (the big one).** The depth-24 ZPixmap
arm was silent-dropping — well-behaved Linux clients sending
PutImage on the now-primary path got nothing. Added
`expandZPixmapDepth24`: reads 4 bytes per pixel `[pad, R, G, B]`
(msbFirst per imageByteOrder, the symmetric inverse of GetImage's
depth-24 emission) and converts to BGRA for the bridge ARGB blit.
No colormap involvement, lossless. Dispatch refactored to do
explicit depth-match validation against the drawable's depth per
spec — Bitmap requires depth=1, ZPixmap requires the request depth
to match the drawable's depth. Spec-illegal combos now emit BadMatch
instead of silent-dropping. Three new tests in
`PutImageDispatchTests` cover the happy path and the two BadMatch
cases.

**Vintage depth-8 ZPixmap → BadMatch.** The PseudoColor-era
motifbur menu-icon path. After the TrueColor switch each source
byte unpacked to a near-black-blue shade — non-meaningful rendering
that masqueraded as success. Now emits BadMatch (no advertised
PixmapFormat for depth-8). One existing test rewritten; vintage
motifbur replay captures will surface the error rather than render
broken-colored icons.

**CopyPlane fixes.** Two stale spots from the PseudoColor era:
(1) the window-source-depth assumption was hardcoded to 8 (the old
rootDepth), so CopyPlane on plane index ≥8 of a window would have
emitted spurious BadMatch — now 24 to match the actual rootDepth;
(2) the handler comment + OPCODE_STATUS row 132 still described
the lossy ARGB-reverse-map-misses-pixel-zero behavior from when
ColorTable was a real allocation table. Under TrueColor
`ColorTable.pixel(for:)` is a pure bit-pack of R/G/B — lossless,
no misses. Comment and status row refreshed.

**Colormap-op BadMatch claim → false alarm.** STATUS note from
2026-06-13 said AllocColorCells / AllocColorPlanes / StoreColors /
StoreNamedColor should emit BadMatch under TrueColor "per spec."
Verified against `reference/X11R6/xc/programs/Xserver/dix/colormap.c`:
the X11R6 reference server returns `BadAlloc` for
AllocColorCells/AllocColorPlanes on non-DynamicClass visuals and
`BadAccess` for StoreColors/StoreNamedColor — which is exactly what
we already emit. The colormap-MARK comment updated to record the
verification; no code change.

**PixelBuffer depth-24 support → no-op.** Per the PixelBuffer file
header, the Mac-side bitmap is always 32-bit ARGB regardless of
X-side depth; depth conversion happens at the I/O boundary
(PutImage / GetImage / CopyPlane). PutImage was the only gap,
which the depth-24 work above closes.

OPCODE_STATUS rows 72 (PutImage) and 63 (CopyPlane) updated.
OPCODES_PUBLIC.yaml coverage strings updated to match. SHORTCUTS
PutImage entry updated to reflect "XYPixmap is the only remaining
silent-drop; spec-illegal depth combos now emit BadMatch."

## CWBackPixmap honoring (late evening)

xli over the SSH launcher surfaced this. xli's strategy: build the
image in a depth-24 pixmap with 19 PutImages, then set
`ChangeWindowAttributes window=... mask=0x841 [bg-pixmap=<pixmap-id>]`
on the top-level and expect the server to paint the window bg using
the pixmap content. We silently dropped CWBackPixmap (tracked
SHORTCUT since 2026-05-15), so the window came up all white. The
PutImages were landing correctly — the broken half was the
server-owned bg paint that should have used the pixmap source.

Three pieces landed:

**Storage**: `WindowEntry.backPixmapId: UInt32?` and
`backPixmapParentRelative: Bool` next to existing `backPixel`.
Setters enforce X spec's "alternatives" rule — setting either
implicitly clears the other. `WindowTable` gets `setBackPixmapId`,
`setBackPixmapParentRelative`, `setBackgroundNone` helpers.

**Parsing**: CreateWindow and ChangeWindowAttributes both read
`CW.backPixmap` from the value list with the spec's three cases —
0=None (clear bg), 1=ParentRelative (flag set), N=pixmap id
(validated). Bit order matters: CWBackPixmap is bit 0, CWBackPixel
is bit 1, and the reference X server applies bits in ascending
order, so a CWBackPixel in the same call overrides CWBackPixmap.
Validations: BadPixmap on unknown id, BadMatch on depth mismatch.

**Paint**: new bridge method `paintWindowFromPixmap(topLevel:,
sourcePixmapId:, rects:, originDeviceX:, originDeviceY:)`.
`CocoaWindowBridge` snapshots the pixmap's CGBitmapContext as a
CGImage, crops to each rect's source region (clipped to pixmap
bounds — out-of-bounds = unpainted for now), and uses
`drawImageRespectingYFlip` so depth-24 pixels land top-down.
`paintWindowPixmapBackgrounds(topLevelId:)` walks the subtree and
issues the blit for every window with `backPixmapId` set.
`paintRectsForWindow` skips its bg-fill branch when `backPixmapId
!= nil` — the solid-color and pixmap paths are mutually exclusive
per window. Called from the MapWindow paint site right after
`paintWindowRects`.

Open shortcuts logged: pixmap tiling when window > pixmap (xli's
pixmap is larger than its window, so single-blit covers it);
ParentRelative honoring (flag stored but `paintWindowPixmapBackgrounds`
skips it — no client we host sets it); CWBorderPixmap still silently
dropped.

## Pointer feature pass (very late evening)

Two small UX wins driven by Todd's wheel-mouse + xterm scrollbar gripe.

**Mouse wheel → Button4/5.** `FlippedXView.scrollWheel(with:)`
accumulates `event.scrollingDeltaY` (and X for horizontal) and emits
synthetic X Button4 (up) / Button5 (down) press+release pairs per
detent threshold crossing (10 points; tuned for both Logitech wheels
and Magic Mouse / trackpad). Per-event emission capped at 16 so a
flick-inertia scroll doesn't fire 200 button events into a vintage
xterm. Horizontal scroll generates Button6/7 — most clients ignore
them, xterm handles via translation table. Modern xterm reads
Button4/5 natively for scroll-history; vintage Sun xterm needs one
`.Xdefaults` translation line, documented in the seed file.

**`[pointer] swapButtons23`** config flag in
`~/.macxserver-resources`. Wheel-mouse users (where the physical
button-2 IS the wheel click and awkward to drag) set it to `true`
and Mac right-click reports as X button 2 — xterm's Athena
scrollbar now grabs the thumb on Mac right-click instead of
wheel-press. Mac wheel-click reports as button 3 (Motif menu post).
Three-button-mouse users with a real middle button leave it false.
Default off, opt-in. New `PointerConfig` struct mirrors
`MotifTheme`'s load-at-session-init + `.current`/`.install` pattern;
swap applied via `FlippedXView.remapButton(_:)` before both
`dispatchMouse` and `dispatchDrag`. Scroll-wheel buttons 4/5/6/7
pass through unchanged.

Files touched: `FlippedXView.swift` (~70 lines for scrollWheel +
remapButton), new `PointerConfig.swift` (~50 lines),
`ResourceFile.swift` (`.pointer` section kind + `pointerSettings`
accessor), `ServerSession.swift` (install at startup), `DefaultThemes.swift`
(seed `[pointer]` section with explanatory comments). 5 new tests
in `ResourceFileTests` cover the parse, the bool spelling tolerance,
the remap function, and the seed roundtrip.

**Follow-on smear fix.** First xli run worked at MapWindow but
pan-via-drag accumulated vertical-streak smears along the leading
edge. xli's pan idiom (revealed by a second capture): outer parent
window stays still, inner child has the bg-pixmap and gets
`ConfigureWindow y=-2, -3, -4, ... -282` on each MotionNotify, so the
child slides up within the parent and progressively-deeper rows of
the bg-pixmap become visible at the bottom edge of the parent.

The pure-move ConfigureWindow path was running its bit-gravity blit
(content shifts up) but the newly-exposed strip at the bottom got no
fresh paint — the bg-paint block was gated on
`eventMask & exposureMask`, and xli's child has no ExposureMask (it
expects the server to honor the bg contract without client
involvement). So each pan left another sliver of stale MapWindow-era
pixels behind. Fix: added an unconditional `paintWindowFromPixmap`
for the `newClip - blitDst` region whenever the moved window has
`backPixmapId`, with the origin tracking the moved child's new
content top-left. After: pan is clean. 7th test added in
`ChangeWindowAttributesTests` (the pure-move regression).

Result on Todd's hardware: xli renders the photo correctly AND pans
noticeably faster than the same xli running against the vintage Sun
workstation upstream.

OPCODE_STATUS rows 1 and 2 updated. OPCODES_PUBLIC.yaml coverage
lines updated.

## Today's commits (X repo, chronological)

- `02b253a` — SHAPE: drop `.resizable` while client is shaped (oclock/xeyes deform fix)
- `046f677` — STATUS: roll forward to 2026-06-14 — shaped-client deform fix
- `377283d` — SHAPE: draw title widget only, no surrounding frame bevel/grooves
- `952fdae` — MotifFrame: focus state title-text dim + system-menu double-click close
- `eedcc5f` — MotifTheme: single-knob color derivation for frame chrome

(Hugo: `appVersion` bump to 0.9.5 for today's release.)

5 commits in the X repo today, one Hugo bump, one public release
shipped clean. One audit doc added (`MOTIF_FRAME_AUDIT_2026-06-14.md`).
No DECISIONS / SHORTCUTS / OPCODE_STATUS rolls today — the work was
all in our chrome (rendering layer, not protocol).

## What's working

- v0.9.5 live: notarized, stapled, `spctl`-clean. Hugo site download
  button updated.
- oclock and xeyes now render correctly: title-bar-only frame, no
  resize, no deform.
- Active vs inactive Motif frames visually distinct across the whole
  chrome (not just title text). Inactive bg darker + desaturated by
  derivation.
- Single-knob color model: change `Mwm*background` and the entire
  chrome (active + inactive, all surfaces) recolors coherently.
- Default chrome dimensions consistent across full-config, empty
  section, no-file scenarios.
- 1293 tests green, 27 skipped (unchanged baseline). Build clean.

## What's next / open

- **v0.9.5 in the wild** — watch for in-the-field reports on the
  shaped-client / focus-state changes. The focus-state shift is the
  most visible behavior change of the release.
- **Motif audit leftovers** (12 of 15 findings still open): see
  `MOTIF_FRAME_AUDIT_2026-06-14.md`. 6 MINOR (icon-tile bevel
  thickness, corner-groove L-piece length, MWM_DECOR_ALL XOR
  handling, etc.); 6 COSMETIC. None are blocking quality issues;
  pick off as time allows.
- **F3 (maximize state bevel inversion)** is deferred *deliberately*
  per Todd. Skip in any audit-leftover sweep.
- **TrueColor cleanup follow-on** — closed in the evening pass; see
  the dedicated section above. XYPixmap PutImage is the only
  remaining PutImage silent-drop and stays open until a hosted
  client exercises it.
- **WM-proxy charter punch-list leftovers** (carryover): #12
  SetSelectionOwner time-comparison gate (~5 lines), #7 CWBackPixmap
  ParentRelative descendant case, #8 GetProperty type filter,
  #10 / #12b / #12c lower-priority items.
- **macXcapture still at v0.9.1.** No capture-side code moved
  today; no reason to cut a new capture release.

---

## Preserved below: 2026-06-13 marathon day

Marathon day, **MacXServer v0.9.3 shipped** (signed/notarized/stapled,
on macxserver.com). Five substantive chunks landed in sequence: WM-proxy
contract pass in the morning, TrueColor visual switch in the afternoon,
depth-1 paper/ink caret fix, dialog title-bar carve-out fix and
WM_TRANSIENT_FOR z-order plumbing in the evening. 1293 tests green, two
investigation docs preserved for the audit trail, both repos clean,
v0.9.3 verified live.

Headline lands (chronological):

1. **Morning — WM-proxy contract pass.** WM_DELETE_WINDOW gating on
   WM_PROTOCOLS, NSWindow close deferred until the client responds (fixes
   dtpad "save unsaved changes?" orphan), WM_NORMAL_HINTS plumbed to
   `NSWindow.contentMin/MaxSize` / `contentResizeIncrements` /
   `contentAspectRatio` (quickplot's plot-window aspect ratio now honored
   during user resize; xterm character-cell resize snap works),
   _MOTIF_WM_HINTS decoration bits applied per-window on top of the
   static `[motif-frame]` config.

2. **Afternoon — TrueColor 24-bit visual switch.** Supersedes the
   2026-05-05 PseudoColor 8-bit choice (DECISIONS 2026-06-13 first
   entry for the full reasoning). Driven by Todd's "wacky colors in
   capture replay" symptom, which traced to PseudoColor cell-collision;
   the broader re-think solved that plus the GetImage AA-edge fidelity
   loss, the AllocColor 256-cell ceiling, and the modern-Linux-app
   blocker that the 2026-06-12 SSH launcher exposed.

3. **End-of-afternoon — depth-1 paper/ink fix.** Todd's smoke test
   caught the Motif XmText caret rendering as a solid black block
   instead of a blinking I-beam. Root cause: depth-1 pixmaps follow
   X's paper/ink convention (pixel & 1 = paper(0)/ink(1)) independent
   of visual class; the convention was implicit under PseudoColor's
   pinned cells. TrueColor moved blackPixel to 0, silently inverting
   the depth-1 meaning. Fix: target-aware `resolveColor` that
   special-cases depth-1 to honor paper/ink.

4. **Evening — Motif chrome tuning + revert.** First attempted to
   shrink chrome at 3x via per-scale multipliers; reverted because the
   approach silently over-rode explicit resource-file values and made
   dialog rendering worse. Captured the failure modes in
   `CHROME_NOTES_2026-06-13.md` so the next attempt starts from sound
   ground. Then landed the real fixes in isolation: seed defaults
   updated to match Todd's personal `[motif-frame]` values
   (frameBorderWidth 2→3, resizeBorderWidth 2→1, titleBarHeight
   32→26); `titleBarRect()` now extends frame-to-frame on dialogs
   that hide menu/min/max via `_MOTIF_WM_HINTS` (matches Sun mwm,
   verified against u5); `raisedTileCentered` floor()'s offsets to
   avoid half-pixel blur.

5. **Late evening — modal investigation + WM_TRANSIENT_FOR plumbing.**
   Quickplot's About / Quit / Lines dialogs misbehaved relative to
   the command window. Investigation against `reference/quickplot/`,
   `reference/motif/lib/Xt/`, and Sun running the same scenario
   confirmed: (a) quickplot's dialogs are explicitly MODELESS, not
   modal — `XmNdialogStyle` defaults to MODELESS in dialog.c:465;
   (b) the "both dismiss on Cancel" matches Sun behavior exactly;
   (c) the real gap was `WM_TRANSIENT_FOR` layering — Sun mwm keeps
   transient dialogs above their parent regardless of focus, we
   didn't. Implemented via z-order maintenance in
   `CocoaWindowBridge`: `child.order(.above, relativeTo: parent.windowNumber)`
   on every parent `windowDidBecomeKey`. Initially tried
   `NSWindow.addChildWindow` and reverted because it couples position
   (parent move drags child along), trapping the user when a dialog
   covers a parent button. Documented as a deliberate
   Mac-convention divergence in DECISIONS 2026-06-13 second entry.

Working-tree clean across both repos, all pushed to origin. **1293
tests green, 27 skipped** (1284 baseline + 5 MotifFrameViewGeometryTests
+ 4 WMTransientForTests). Live v0.9.3 download artifact verified
clean (`spctl` accepted, `stapler validate` passes).

## Release: MacXServer v0.9.3 (today)

- Tag: `MacXServer-v0.9.3`. GitHub release at
  `releases/tag/MacXServer-v0.9.3`. Hugo `appVersion` bumped to 0.9.3
  (Hugo `54f1ff0`); website download button live and validated.
- Built, signed (Developer ID Application), notarized (notarytool
  --wait), stapled, republished via `./release.sh MacXServer 0.9.3`.
  Live download spot-checked via `ditto -x -k` + `spctl` + `stapler`
  end-to-end.
- Whatever shows up vs v0.9.2: SSH launcher (which actually shipped in
  0.9.2), WM_DELETE_WINDOW gating + NSWindow close defer,
  WM_NORMAL_HINTS / _MOTIF_WM_HINTS server-side application, TrueColor
  visual flip, depth-1 paper/ink fix.

## Today's commits (X repo, chronological)

- `b5df2e0` — WM-proxy contract pass (WM_DELETE_WINDOW + WM_NORMAL_HINTS + _MOTIF_WM_HINTS + tests)
- `25a9814` — STATUS: roll in Gatekeeper docs + launcher feature page
- `6f7bba6` — release.sh: comment the unzip canary
- `f74b7fb` — STATUS: end-of-day v0.9.2
- `6431316` — Gatekeeper investigation/findings/probe-script tracked
- `ed5355a` — Switch advertised visual from PseudoColor 8-bit to TrueColor 24-bit
- `2f517ed` — TrueColor follow-ups: GetImage depth-24 output, docs, SHORTCUTS cleanup
- `f151feb` — TrueColor: honor depth-1 paper/ink convention
- `87caf85` — STATUS: end-of-day v0.9.3 shipped
- `99afed5` — Motif chrome: update seed defaults + CHROME_NOTES from failed-attempt
- `e252338` — MotifFrameView: extend title bar across hidden-button corners
- `0cfd6c8` — Notes: open modal-dialog investigation
- `7d95474` — WM_TRANSIENT_FOR: attach transient dialogs as NSWindow child windows (reverted approach)
- `f85161b` — Notes: mark modal investigation RESOLVED
- `c6f76f5` — WM_TRANSIENT_FOR: maintain z-order ourselves, not via addChildWindow

(Hugo: `6bb1270` appVersion bump to 0.9.2 drift fix; `54f1ff0`
appVersion bump to 0.9.3 for today's release.)

15 commits in the X repo today, 2 in the Hugo repo, one public
release shipped clean. Two architectural decisions logged in
DECISIONS.md (TrueColor supersession + WM_TRANSIENT_FOR
divergence). Two investigation docs preserved
(`CHROME_NOTES_2026-06-13.md`, `MODAL_INVESTIGATION_2026-06-13.md`).

## Charter status check

Closed today (from the WM-proxy / charter-fidelity punch list and from
the modal-dialog investigation):

- **#4 WM_DELETE_WINDOW gating** — done (Bug A + Bug B both closed)
- **#6 WM_NORMAL_HINTS / _MOTIF_WM_HINTS honoring** — done (both
  properties decoded + applied end-to-end, with the slot-pending
  timing fix + the depth-1 paper/ink fix to keep Motif caret rendering)
- **#9 AllocColor pain (capture-replay colors)** — closed by the
  TrueColor switch. New captures don't have the pixel-translation
  problem at all (pixel values ARE the RGB). Existing PseudoColor gold
  captures replay against TrueColor as muted near-black-blue shades
  rather than the previous "wacky color collision" symptom — visually
  wrong but no longer corrupted by collision (per DECISIONS analysis).
- **#11 TRANSIENT_FOR → NSPanel** — done, but via manual z-order
  maintenance rather than `NSWindow.addChildWindow` (DECISIONS
  2026-06-13 second entry; the addChildWindow approach was tried first
  and reverted because it couples position).
- **Title-bar carve-out on hidden-button dialogs** — emerged from the
  WM-proxy work, closed with `titleBarRect()` extending frame-to-frame
  when `_MOTIF_WM_HINTS` decoration bits hide menu/min/max. Verified
  against u5.

Still open from that punch list:
- **#12 SetSelectionOwner time-comparison gate** — ~5 lines, deferred
- **#7 CWBackPixmap ParentRelative descendant case** — verify-then-fix
- **#8 GetProperty type filter** — latent INCR dep
- **#10 / 12b / 12c** lower-priority items per Todd's gut sort

## What's open in the TrueColor cleanup follow-on

(Logged in SHORTCUTS, deferred from 0.9.3 cut)

- **PutImage ZPixmap depth-24**: silent-drops today. Modern Linux clients
  doing `XPutImage` with depth-24 data won't render. Fix is ~30 lines
  (new arm in the format/depth switch, BGRA byte-swap for the bridge).
  Likely the first thing to surface when running a real Linux app via
  the SSH launcher.
- **PixelBuffer depth-24 support**: `CreatePixmap(depth: 24, ...)`
  creates a depth-8-shaped PixelBuffer. GTK/Qt widgets that cache
  rendered content in offscreen depth-24 pixmaps would hit this. ~40-60
  lines plus per-op verification.
- **Colormap ops BadMatch**: AllocColorCells / AllocColorPlanes /
  StoreColors / StoreNamedColor should emit `BadMatch` per X spec on
  TrueColor visuals (we emit `BadAlloc` today, which Xt's color
  converter accepts as a fallback trigger but is technically
  spec-wrong). ~5-line fix per handler.
- **CopyPlane reverse-map cleanup**: OPCODE_STATUS row 132 still
  describes the PseudoColor reverse-map path; needs the same
  direct-BGRA-extraction treatment GetImage got. Probably already works
  for the common plane bits but worth verifying.
- **Depth-8 ZPixmap semantics**: today accepts depth-8 ZPixmap PutImage
  and renders each byte as a near-black shade of blue (TrueColor unpack
  of an 8-bit value). Should either emit BadMatch (depth-doesn't-match
  the advertised visual) or silent-drop with a clearer log. Either way,
  not visually meaningful as it stands.

None blocking; each surfaces when a specific client exercises it.

## SHORTCUTS items closed today

- AllocColor freelist / cell cap (replaced by TrueColor degenerate alloc)
- Color resolution falls back to black for unknown pixels (every 24-bit
  value is now a valid RGB)
- GetImage reverse-maps ARGB → 8-bit pixel via ColorTable (direct ARGB
  extraction now)

Opened today (WM-proxy contract gaps, deferred to follow-on):
- WM_DELETE_WINDOW force-close skips recursive inferior teardown
  (latent — every hosted client claims WM_DELETE_WINDOW so the force
  path doesn't fire in practice)
- Hung-client polite close has no timeout fallback (NSWindow stays
  open forever if the client never responds; second-click force-
  close not implemented)
- _MOTIF_WM_HINTS decoration bits silently dropped on native-chrome
  NSWindows (only honored on Motif-frame NSWindows; NSWindow.styleMask
  can't be safely mutated post-create)
- WM_TRANSIENT_FOR transients don't follow parent through Spaces,
  don't minimize with parent, don't auto-close with parent (deliberate
  per DECISIONS 2026-06-13 second entry; could be re-added selectively
  via NSWindow observers without taking on position coupling)

## What's next / open

- **v0.9.3 in the wild** — watch for in-the-field reports. The post-
  v0.9.3 evening work (title-bar carve-out, WM_TRANSIENT_FOR, seed
  defaults) didn't ship — would justify a v0.9.4 cut if the modal/
  layering improvements feel worth releasing in their own right.
- **macXcapture still at v0.9.1.** No capture-side code moved today
  beyond diagnostic-log polish; no reason to cut a new capture release.
- **TrueColor cleanup follow-on items** (#18 PutImage depth-24,
  #19 PixelBuffer depth-24, #20 colormap-op BadMatch, plus
  CopyPlane / depth-8 ZPixmap cleanup) — pick off as real clients
  surface them. None blocking.
- **The other punch-list items (#7 CWBackPixmap descendant case,
  #8 GetProperty type filter, #12 SetSelectionOwner time gate)** —
  when convenient. #12 is a 5-line drop-in.
- **WM_TRANSIENT_FOR re-add Spaces/minimize coupling** — could
  observe parent's `windowDidChangeSpace` / `windowDidMiniaturize` and
  mirror onto transients WITHOUT taking on position coupling. Worth
  doing if the gap becomes user-visible. See DECISIONS 2026-06-13
  second entry "Cost flagged" for the full list.

## TrueColor 24-bit visual switch — detailed write-up

Discussion that drove the change started from Todd's "wacky colors in
capture replay" symptom. Tracing back: vintage clients reference
captured pixel cookies that meant something on Sun's PseudoColor
colormap; on replay against our PseudoColor server they collide with
whatever some *other* client's earlier AllocColor put at the same cell
index. Pixel-translation fix would have addressed that one symptom; a
broader visual-class re-think solved it plus a stack of unrelated
pains (GetImage AA-edge fidelity loss, AllocColor 256-cell ceiling we
weren't enforcing, modern Linux apps via the SSH launcher blocked from
mapping windows, eternal InstallColormap/UninstallColormap maintenance
debt). DECISIONS.md 2026-06-13 has the full reasoning + alternatives.

Code changes:
- `ServerConfig.makeSetupAccepted`: TrueColor 24-bit visual, RGB888
  masks, rootDepth=24, pixmapFormat depth-24 bitsPerPixel-32 scanlinePad-32.
  `whitePixel=0x00FFFFFF`, `blackPixel=0x00000000` (canonical Linux).
- `ColorTable`: degenerate pack/unpack. `allocate()` bit-packs RGB,
  `rgb(for:)` bit-unpacks, no state needed for the mapping. `count`
  still tracks distinct allocations for CapturedAppReplayTests
  baselines. No pinned cells, no shared-cell match, no 256-cell ceiling.
- `GCState` defaults flipped: fg=blackPixel (0), bg=whitePixel (0xFFFFFF).
- `GetImage` on a window: now reports depth=24 and emits 4 bytes per
  pixel `[pad, red, green, blue]` extracted directly from BGRA backing.
  AA-edge fidelity preserved by construction; no reverse-map step.

Tests:
- `ColorTableTests` rewritten for TrueColor pack/unpack (8 cases).
- 6 other test files updated to use TrueColor-packed pixel values
  where they previously hardcoded PseudoColor pin assumptions
  (DrawingDispatch / FontDispatch / PutImageDispatch / ShapeExtension /
  ShapeOnDescendant / StartupReplies).
- `CapturedAppReplayTests`: untouched, still pass. Todd's intuition
  was right — the captures stayed valid because those tests verify
  dispatch + resource counts, not rendered output.
- Full suite: **1284 tests, 0 failures**, 27 skipped (unchanged baseline).

What's deferred (open, follow-on):
- **PutImage depth-24 ZPixmap**: currently silent-dropped. Modern
  Linux clients sending PutImage depth-24 image data won't render.
  Tracked in SHORTCUTS. Add when an actual client surfaces.
- **PixelBuffer depth-24 support**: CreatePixmap(depth: 24) needs a
  PixelBuffer that stores 32-bit pixels. Not blocking today; will
  surface when something actually exercises it.
- **Colormap ops (AllocColorCells / StoreColors / etc.)**: should
  emit BadMatch per TrueColor spec semantics. Today they no-op or
  emit BadAlloc per the PseudoColor-era OPCODE_STATUS notes. Cleanup,
  not blocking.

Smoke test pending: Todd to run xterm / xcalc / dtpad / quickplot
post-switch and confirm visuals are unchanged for vintage apps. Per
DECISIONS reasoning they should render identically since the API is
the same and vintage apps use DefaultVisual without caring about its
class.

SHORTCUTS closed today (PseudoColor-era items):
- "AllocColor has no freelist and no cell cap" — TrueColor alloc is
  degenerate, no state to leak.
- "Color resolution falls back to black for unknown pixels" — every
  24-bit value is a valid RGB now.
- "GetImage reverse-maps ARGB → 8-bit pixel via ColorTable" — direct
  ARGB extraction; AA edges lossless.

OPCODE_STATUS rows updated for AllocColor / QueryColors / GetImage
to reflect the TrueColor semantics; dated 2026-06-13.

## WM-proxy contract pass (morning)

Closed two real charter gaps that we'd been silently ignoring for
top-level Motif windows. WM_DELETE_WINDOW now
respects WM_PROTOCOLS membership (no more sending the polite message to
clients that never claimed it), and the NSWindow no longer closes
underneath a "save unsaved changes?" dialog before the client can react.
WM_NORMAL_HINTS and _MOTIF_WM_HINTS are now decoded server-side and
plumbed into `NSWindow.contentMinSize` / `contentMaxSize` /
`contentResizeIncrements` / `contentAspectRatio` and per-window Motif
chrome decoration bits — was completely unimplemented before today (the
property bytes were stored but never read). 1283 tests green; 19 new
tests for the wire-up. Build clean.

## Afternoon follow-ups: timing, crash, validation, decision

After the morning's WM-proxy contract pass landed, drove dtpad / dtterm /
xterm against the new code to verify. Found and fixed two real bugs,
discovered one design question, and validated one win:

- **Timing bug fix** (`CocoaWindowBridge.applySizeHints` /
  `applyMotifDecorations`). Hints arriving between `CreateWindow` and
  `MapWindow` were silently dropped — `slot(id)?.window` was nil and
  the apply returned early. Added `sizeHints` / `motifHints` caching on
  the `Slot` struct (same pattern as the existing `pendingTitle`);
  `mapTopLevel` now reads and applies any pending hints after the
  NSWindow is created. Caught by Todd reporting "min size not enforced"
  on xterm — turned out the intercept was firing but the apply wasn't.
- **Latent crash fix** (`CocoaWindowBridge.fillGXxorPixelValue`).
  Shrinking dtterm small enough for its cursor-blink XOR rect to extend
  past the right edge of the canvas tripped a fatal "Range requires
  lowerBound <= upperBound" — `x0` was clamped to `max(0, ...)` but not
  also bounded above by `ctxW`, so when the rect was fully off-canvas
  `x0 > x1` and `for dx in x0..<x1` threw. Added `guard x1 > x0, y1 >
  y0 else { continue }` defensive skip. Latent until today because
  nothing else exercised the "shrink a window with an active XOR rect
  past the canvas" path.
- **Diagnostic logging** in `ServerSession.changeProperty` now prints
  `prop=N (NAME)`, type, format, byte count on every write. Keeping it —
  next time someone asks "why isn't WM_FOO working?" this single log
  line answers it without a rebuild.
- **Decision: no UX policy floor on declared minimums.** xterm declares
  10×17 X pixel minimum (1 char cell); Sun-era dtpad declares 0×0
  (empty WM_SIZE_HINTS struct with PMinSize bit on but values zero).
  Both are spec-correct vintage X behavior — Linux WMs honor them and
  let the user shrink to nothing. Could have imposed a Mac-style 360×220
  floor; chose not to. See DECISIONS.md 2026-06-13 entry for the
  reasoning.
- **Concrete validation: quickplot's aspect-ratio constraint now works
  end-to-end.** The xlib plot window declares `PAspect` in WM_NORMAL_HINTS;
  pre-fix we ignored it, post-fix the NSWindow honors it during user
  resize. First user-visible WM_NORMAL_HINTS win.

## WM-proxy contract pass (today)

Charter framing: macXserver is the WM (no client-side WM runs against
us); macOS supplies actual window management via AppKit. The two items
hit today are the contact surface between those layers — places where
the X client thinks it's negotiating with a window manager (us) but we
weren't doing our half.

**#4 WM_DELETE_WINDOW gating** (`ServerSession.handleCloseRequest`,
`CocoaWindowBridge.windowShouldClose`). Two bugs closed:

- *Bug A*: `handleCloseRequest` sent `ClientMessage(WM_DELETE_WINDOW)`
  unconditionally to every top-level. Now reads the window's
  `WM_PROTOCOLS` property and only sends the polite message if the
  `WM_DELETE_WINDOW` atom is listed. Clients that don't claim it get the
  force path: `bridge.destroyTopLevel` emits `DestroyNotify` so the
  client learns its window is gone, NSWindow orderOuts + closes.
- *Bug B*: `windowShouldClose` returned `true`, closing the NSWindow
  before the client could react. Specifically broke dtpad-style
  "save changes? Yes/No/Cancel" flow: main window vanished, save dialog
  appeared parentless, user-Cancel left the X main window alive with
  no NSWindow. Now returns `false` — NSWindow stays open until the
  client's natural `XDestroyWindow` (polite path) or our `destroyTopLevel`
  (force path) closes it.

**#6 WM_NORMAL_HINTS + _MOTIF_WM_HINTS application** (new
`Sources/SwiftXServerCore/WMHints.swift`, `ServerSession` ChangeProperty
interception, `CocoaWindowBridge.applySizeHints` /
`applyMotifDecorations`, `MotifFrameView` decoration gating). Both
properties had server-side decoders only in the capture tool; the server
stored them as opaque bytes and never read them. Now intercepted at
`ChangeProperty` (mirroring the existing WM_NAME / WM_CLASS / selection-
sink pattern) and routed to AppKit:

- `WM_NORMAL_HINTS`: `PMinSize` → `contentMinSize`, `PMaxSize` →
  `contentMaxSize`, `PResizeInc` → `contentResizeIncrements` (xterm's
  character-cell snap finally works), `PAspect` → `contentAspectRatio`.
  Coordinate-scaled to points; widened by Motif chrome padding when the
  NSWindow is a `MotifWindow`.
- `_MOTIF_WM_HINTS` decoration bits (BORDER, TITLE, MENU, MINIMIZE,
  MAXIMIZE, RESIZEH): gated in `MotifFrameView.drawTitleBar` so per-window
  decoration overrides hide the right chrome elements without changing
  the chrome layout (X-client area stays stable). Static `[motif-frame]`
  config still wins when the property is absent or sets the `ALL` sentinel.

**Tests**: 12 new across `WMHintsTests` (decoder edge cases incl. both
byte orders + pre-ICCCM 15-element form) and `WMHintsDispatchTests`
(integration — ChangeProperty reaches bridge with decoded values; close
gates correctly on WM_PROTOCOLS three ways: claimed → polite, absent →
force, present but lacks WM_DELETE_WINDOW → force).

**Known gaps logged in SHORTCUTS**: force-close skips recursive inferior
teardown (latent — every hosted client claims WM_DELETE_WINDOW); hung-
client polite close has no timeout fallback (user can re-click);
_MOTIF_WM_HINTS on native-chrome NSWindows is silently dropped (Motif
Frame off path).

## 2026-06-12 — Feature day: SSH launcher + v0.9.2 (preserved below)

Feature day: SSH launcher, macxserver.com page documenting it,
**MacXServer v0.9.2 shipped** (signed/notarized/stapled, on the website),
and the Gatekeeper browser-dependence investigation docs from yesterday's
research finally committed to the tree. The Launchers menu now supports
modern Linux/BSD/Solaris boxes alongside the telnet path for vintage Sun
workstations: new `transport = ssh` key on the host block, spawns
`/usr/bin/ssh` with `BatchMode=yes` (keys-only, no password injection),
direct-DISPLAY back to our server on 6000 (no `-X` X11 forwarding).
Decisions and trade-offs logged in DECISIONS.md (2026-06-12 entry).
Website launcher feature page updated and deployed twice — once for the
SSH framing, once for the bold "keys only" call-out.

**Working tree clean. Both repos pushed.** Tests green
(21 launcher + full suite). Live downloads on macxserver.com pull v0.9.2.

Yesterday's launch-day notes — public-release flip, v0.9.0 shipping, and
the four bug fixes (Gatekeeper docs, xterm menu drift, dtfile transparent
icons, orphaned xterm menu) — moved to the body below for the record.

## Release: MacXServer v0.9.2 (today)

- Tag: `MacXServer-v0.9.2`. GitHub release at
  `releases/tag/MacXServer-v0.9.2`. Hugo `appVersion` bumped to 0.9.2;
  website download button verified live and pointing at the new artifact.
- Built, signed (Developer ID Application), notarized (notarytool
  --wait), stapled, and republished via `./release.sh MacXServer 0.9.2`.
  Validated end-to-end against the live download: `spctl -a` accepts
  "Notarized Developer ID"; `xcrun stapler validate` passes.
- MacXCapture untouched this session — still at v0.9.1; no rebuild
  needed.
- Gotcha worth not unlearning: the test-download hint that release.sh
  prints at the end deliberately uses `unzip` (which strips the
  codesign-friendly metadata `ditto` packed in, so `spctl` fails on the
  result). That false alarm was the only thing that prompted validating
  the 0.9.2 publish from the right tool (`ditto -x -k`) and confirming
  the actual artifact is healthy. Comment in release.sh now documents
  the trap so it stays a canary, not a bug.

## What's next / open

- No new open bugs from today. SSH launcher works on Todd's nuc; xterm
  font sized via `-fn 10x20` in the launcher entry.
- macXcapture still at v0.9.1. If a capture-side feature lands, cut
  v0.9.2 there too; otherwise no need.
- The Gatekeeper investigation has a probe script ready to run on a
  fresh Mac. Live status remains "pipeline healthy, dialog is the
  standard Sequoia first-launch path"; no action item until the next
  in-the-wild report.

## SSH launcher (today)

- New transport `transport = ssh` on the launcher-file host block. Default
  remains `telnet` so every existing `~/.macxserver-launchers` keeps
  working byte-for-byte. Default port shifts to 22 when transport is ssh.
- New `SSHLauncher` in `Sources/SwiftXServerCore/`. Spawns
  `/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15 -p PORT user@host '…remote command…'`. Stdout +
  stderr stream into the existing progress window.
- Remote command shape is identical to the telnet path: `/bin/sh -c
  'DISPLAY=…; export DISPLAY; nohup CMD </dev/null >/dev/null 2>&1 &'`.
  The `/bin/sh -c` wrap is mandatory — accounts whose login shell is
  csh/tcsh (caught while setting up Todd's nuc: `2: Command not found.`
  was csh choking on `2>&1`) reject Bourne syntax outright. X traffic
  goes direct to our server on 6000; we do NOT use ssh's `-X`/`-Y` X11
  forwarding (no remote-sshd config required, no xauth cookie on our side).
- Auth is keys-only. `BatchMode=yes` makes ssh fail fast instead of hanging
  if keys aren't set up. AppDelegate's ssh dispatch skips the password
  prompt and Keychain entirely. A `password = …` field on an ssh entry is
  parsed but ignored, with a load-time warning emitted via the log sink.
- New `RemoteLauncher` protocol so `AppDelegate.activeLauncher` can hold
  either type. TelnetLauncher and SSHLauncher both conform.
- Tests: `LauncherFileTests` gained `testTransportParsing`,
  `testTransportItemOverride`, `testSSHWithPasswordWarns`.
  `SSHLauncherTests` pins the exact argv shape and the auth-failure-text
  detector. All 21 launcher tests green, build clean.
- Seed comment in `DefaultLaunchers.swift` documents `transport`, the
  per-transport default port, and the keys-only constraint. Existing
  installed launcher files are not migrated automatically (the seed only
  writes on first run when the file is missing); the format is
  forward-compatible so this is a no-op for current users.
- macxserver.com launcher feature page shipped same day: "Two transports"
  paragraph documenting both telnet and ssh, a `[host:nuc]` config example
  with the `-fn 10x20` font tip that came out of debugging Todd's NUC,
  bold "Password auth isn't supported on the SSH path. Keys only." line
  to make the keys-only constraint unmissable. Comparison-table row in
  `why-macxserver-instead-of-xquartz.md` rewritten from "Sun" to
  "Sun/Linux". Two deploys via `deploy.sh` (rsync to linode); production
  verified live both times. Homepage framing ("modern attaches to the
  Swift foundation, not to what the server runs") deliberately left
  untouched — feature page describes capability, homepage holds the line
  on positioning.

## Gatekeeper browser-dependence docs (today, work from 2026-06-11)

Three artifacts from the June 11 investigation finally tracked in git
(they'd been sitting untracked in the working tree). Continues the
Gatekeeper thread from commits `4fbeeea` / `9b5d45e` / `8b47cd1`:

- `GATEKEEPER_BROWSER_INVESTIGATION.md` — the dossier, written for a
  fresh-eyes analyst with no project context and no preferred answer.
  Documents the reproducible Safari-vs-Chrome difference on first launch,
  what we've verified is healthy (signing, notarization, stapling),
  competing explanations, and what we'd still want to confirm.
- `GATEKEEPER_BROWSER_FINDINGS.md` — that analyst's report back, plus
  Todd's reader's-note that the analyst's "Safari working is luck"
  framing oversteps the empirical observation (the same mechanism the
  analyst proposed — translocation + `LSQuarantineType` + Sequoia
  launch-responsibility — *predicts* the reproducible asymmetry, so the
  difference is real even though the folk-LLM allowlist story isn't).
- `scripts/gatekeeper-probe.sh` — diagnostic script that captures
  quarantine xattr / spctl / stapler / translocation state side by side
  for the two browser download paths, ready to run on a fresh Mac when
  one's available.

Live status of the original report is unchanged from yesterday: pipeline
is healthy, dialog is the standard Sequoia first-launch path,
download-page docs already updated.

## 2026-06-11 — Launch day + four bug fixes (preserved for the record)

## Release / launch

- Repo `toddvernon/MacXServer` is public. **MacXServer v0.9.0** and
  **MacXCapture v0.9.0** are shipped as GitHub releases, signed +
  notarized + stapled (verified the live download zips: `spctl` →
  "accepted, Notarized Developer ID"; `stapler validate` passes). Both
  Hugo sites' download buttons point at the v0.9.0 artifacts.
- Earlier today's cleanup pass (commit `1d31ebf`): dropped the pre-GUI CLI
  capture wrappers (`run-*.sh`, `connection.example.json`) and stray repo
  droppings; README capture section now points at the GUI Record mode.

## Gatekeeper "could not verify" report (resolved — was not a bug)

A friend got the macOS "Apple could not verify MacXServer is free of
malware" dialog. Downloaded the exact live zips and proved our artifacts
ARE notarized + stapled + Gatekeeper-accepted, so the pipeline is healthy.
The dialog is the quarantined-first-launch path (stale copy or a transient
online check). Added a **"First launch on macOS"** section to both
download pages explaining the System Settings → Privacy & Security →
"Open Anyway" step, and softened the over-promising "first launch is
clean" line. Deployed to macxserver.com + macxcapture.com, verified live.
Still waiting on the friend's macOS version + `spctl`/`stapler` output to
confirm it was a stale copy vs a transient check.

## Bug fix 1 — xterm menu drift (commit `f3bfcdf`)

Ctrl-click menus drifted off the window the further it was dragged toward
the screen's right/bottom. Root cause: the advertised X root (1280×900 on
the 5K) was smaller than the area windows can be dragged into; a window
dragged past the advertised width reported an X-root x the client clamped
its popup against. Fix: `DisplayConfig.pick()` now uses the preset table
only to gate the integer scale, then derives the logical root as
`floor(native ÷ scale)` so the X screen covers the whole panel. Scale
chosen per display is unchanged (font sizing unaffected). Touched the
preset contract in SERVER_RESOLUTION_SCALING_AND_FONTS.md (Todd approved);
DECISIONS.md entry added. Tests updated + `testLogicalRootSpansWholeDisplay`.

## Bug fix 2 — dtfile transparent icons (commit `ceef64e`)

Folder/document icons drew with a gray box and a white strip (the
transparent regions weren't clipped). Wire-confirmed from an in-process-tee
capture: dtfile sets a depth-1 `clip_mask` pixmap on the GC + clip origin
per icon, then CopyArea. We honored the clip-rectangle list but dropped the
pixmap clip_mask entirely. Fix: thread clip_mask + origin from GCState →
handleCopyArea → bridge; read the mask via the existing `StippleBitGrid`,
convert opaque bits to horizontal run-rects at the clip origin, clip the
blit to them (rect-clip, not a CG image-mask, to dodge the y-flip hazard).
Two asymmetric orientation/polarity tests added per GRAPHICS_Y_FLIP.md.
Verified visually on real dtfile. OPCODE_STATUS/SHORTCUTS/OPCODES_PUBLIC
updated.

## Bug fix 3 — orphaned xterm menu (commit `bfdadde`)

A Ctrl+button xterm popup menu could be left stranded on screen as a black
window. Root cause was the mouse-up, not the Ctrl key (Todd's hunch about
Ctrl was a red herring): xterm grabs the pointer when it posts the menu and
dismisses on ButtonRelease outside a menu item, so the dismiss depends on
getting that release. Our cross-NSWindow drag monitor
(`dispatchCrossWindowDrag`) dropped any event whose cursor was over no
managed window — fine for motion, fatal for the release. So a release over
empty desktop never reached xterm and the menu hung around. Fix: route the
off-window release to the grab anchor instead of dropping it. New
`dragAnchorWindowId` remembers the last top-level the pointer was over
during the grab (survives going off-window, unlike `dragLastWindowId` which
nils for enter/exit bookkeeping); the release is reported relative to it
with out-of-bounds coords, which is how real X reports a release outside the
event window. The session's grab redirect re-targets to the actual grab
window. Verified live (drag menu onto desktop, release → dismisses).

Belt-and-suspenders in the same commit: **"Drop All Clients" is now a true
nuke.** After cancelling the sessions it calls
`CocoaWindowBridge.closeAllWindows()`, which closes and forgets every
managed NSWindow regardless of hierarchy or session ownership, and clears
any lingering grab tracking / native-drag lock. `cleanupOnDisconnect` only
reaps windows still linked to a session's window table, so an orphan whose
slot drifted from the table could survive it; this guarantees the screen is
clear. Wired via a weak bridge ref on the AppDelegate. AppKit-side code, so
not exercised by the mock-bridge unit suite.

## Housekeeping

- Reconciled GetInputFocus/QueryKeymap public coverage (synthetic-reply
  wording) so `check-opcode-coverage-drift.sh` is clean (commit `2af23c8`,
  site deployed).
- Two diagnostic improvements are now permanent in the capture dumper and
  earned their keep today: `root=(x,y)` printed on pointer events, and
  `clipMask`/`clipXOrigin`/`clipYOrigin` decoded on GC ops.

## What's working

- 1265 tests green. Both apps build + ship signed/notarized. Live xterm,
  dtfile icons now correct, menus track their windows across the display and
  no longer orphan when dismissed off-window.

## What's next / open

1. **Friend's Gatekeeper report** (now its own doc:
   `GATEKEEPER_FIRST_LAUNCH.md`): he sent the actual dialog screenshot, and
   it's the **standard Sequoia/26 quarantine block** ("Apple could not verify
   ... is free of malware", Move to Trash / Done), which a correctly
   notarized app also shows. That de-escalates it: "Open Anyway" is never in
   that dialog (it moved to System Settings > Privacy & Security since
   Sequoia), so his "no Open Anyway" likely just means he stopped at the
   dialog and never opened Settings. Pivotal open question: after clicking
   Done, does Settings > Privacy & Security show an Open Anyway button? If
   yes, it's the expected gate (done). If genuinely absent, fall back to
   damaged-copy (unzip stripped xattrs) or managed/non-admin Mac. Repro'd on
   two Macs (macOS 26 + 25, exact versions TBC via `sw_vers`); scene
   preserved. Pipeline verified good, no build change expected.
2. **Latent server gaps** (carryover, untouched): pixmap clip_mask is
   honored for CopyArea only, not other output ops (no client needs it yet);
   native-title-bar drag-lock gap on Motif-Frame-OFF windows; same-window
   memmove CopyArea still ignores the rect-list clip. The orphan-xterm-menu
   carryover (was on the 06-10 list) is now closed — see Bug fix 3.
3. Key-material housekeeping (from 06-10): move `Certificates.p12` out of
   plain Dropbox to 1Password if desired.
4. No other known bugs as of end of day (Todd: "that's all the bugs I know
   of right now").

# Status 2026-06-10

Two big threads today: finished the code-signing + notarization setup (both
Macs can now ship signed + notarized releases), and a long website-polish pass
across both Hugo sites. Also nailed down the launcher-file format, fixed its
docs, and ran a clean-room audit of the public repo.

## Signing + notarization: DONE on both Macs

- **Developer ID Application cert** issued and installed:
  `Developer ID Application: CarePenguin, inc (X478U667PR)`. Signed under the
  CarePenguin team because the personal "Todd Vernon" team (NXNG297DL6) was
  inaccessible (the covey@ Apple ID login was blocked on the developer
  portal). The team string only shows via `codesign -dvv` / `spctl`, never in
  a Gatekeeper dialog, so it's cosmetic. `release.sh` is hardcoded to
  `TEAM_ID=X478U667PR`.
- **notarytool keychain profile `notary`** created and validated against Apple
  on both Macs.
- **Smoke test passed**: `./release.sh MacXCapture 0.0.1` ran the full loop
  (archive → sign → notarize Accepted → staple → zip → GitHub release → Hugo
  deploy). The throwaway 0.0.1 release + tag were deleted afterward.
- **Laptop provisioned over SSH**: imported the cert via `.p12`, then had to
  run `security set-key-partition-list` (imported keys fail codesign with
  `errSecInternalComponent` in a non-GUI session without it). Documented in
  NOTARIZE-SETUP.md. Verified with a real codesign of a throwaway binary.
- Private cheat-sheet at `RELEASING.local.md` (gitignored, synced via Dropbox,
  symlinked into both working trees) holds the team ID, notary Key ID /
  Issuer ID, troubleshooting, and the new-Mac setup steps.

## In-repo (~/dev/X) commits today

- Retarget `release.sh` to the CarePenguin team; neutralize the team comment
  (dropped the covey@ backstory from the public file).
- `NOTARIZE-SETUP.md`: document `set-key-partition-list` for SSH/headless
  imports; genericize the identity examples for the public repo; fix the
  smoke-test version example (the script requires strict X.Y.Z semver).
- `USING_CLAUDE.md`: human-facing companion to CLAUDE.md (how to drive Claude
  Code on this project, the required-reading map, the ground rules, PR flow).
  Linked from README and CONTRIBUTING.
- `.gitignore`: add `RELEASING.local.md`.

## Clean-room audit (pre-public-release check)

Fresh `git clone` into /tmp, judged only the clone. Result: clean.
- No secrets/keys/certs in tree or history; notary Key ID / Issuer ID in zero
  commits; private files (`CLAUDE.local.md`, `RELEASING.local.md`,
  `connection.json`, `.claude-memory`) correctly absent from the clone.
- Builds from scratch following the repo's own docs: `swift build -c release`
  (~33s), `swift test` (1262 tests, 0 failures), `xcodebuild -scheme
  MacXServer` (BUILD SUCCEEDED).
- Onboarding docs strong (README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY,
  LICENSE, CLAUDE.md, USING_CLAUDE.md); no dangling references to private
  files. Verdict: publish-ready.

## Websites (both Hugo sites, tracked in their own repos)

All committed to MacXServerSite / MacXCaptureSite and deployed live.
- Prose wrapped to 80 cols across macxserver-hugo; homepage intro tightened.
- Launcher feature page rewritten to the real two-level format
  (`[host:KEY]` / `[KEY/ITEM]`); the old example used a fake `keychain` key
  and an unsupported multi-app-per-section shape. New config-editor screenshot.
- macxcapture About page: added the Todd photo + full-width content to match
  macxserver.
- macxserver: About moved to the last nav item; quickplot GitHub link removed
  (can't distribute that app); deep-dives intro made full width;
  title/tagline spacing bumped.
- **Mobile hamburger menu** on both sites (oldsilicon desktop-first pattern):
  the horizontal nav ran off-screen below 769px; now it collapses to a
  tappable dropdown, with the normal horizontal nav restored on desktop.
- CSS confirmed consistent between the two sites (intentional accent-color and
  per-site differences only; no real drift).

## Launcher file format (resolved)

- Real format confirmed in `LauncherFile.swift`: two accepted shapes
  (`[host:KEY]` + `[KEY/ITEM]` two-level, or legacy flat `[label ...]`). Nine
  keys: host, user, command, port, verbose, login_prompt, password_prompt,
  shell_prompt, password. No `keychain` key (Keychain is automatic via the
  `user@host` account; omit `password` to use it, or set it inline as
  plaintext).
- The shipped seed (`DefaultLaunchers.swift`) already documents the two-level
  format correctly. Todd's installed `~/.macxserver-launchers` was from an
  older seed (flat, missing `password`); migrated it to two-level (backup at
  `~/.macxserver-launchers.bak`).

## What's next

1. **Flip the GitHub repo public** (`toddvernon/MacXServer`) in Settings — the
   one remaining manual step. The clean-room audit says it's ready.
2. **Cut the first real release(s)** at launch: `./release.sh MacXServer
   X.Y.Z` and `./release.sh MacXCapture X.Y.Z`. Until then both sites'
   download buttons point at `...-v0.0.0...` and 404 (placeholder appVersion;
   `release.sh` bumps it on a real run).
3. Key-material housekeeping: the notary `.p8` Downloads copy was deleted; a
   password-protected cert backup remains at
   `~/Dropbox/dev/X/Certificates.p12`. Move it to 1Password if you'd rather it
   not sit in Dropbox.
4. Carryover server work (untouched today): re-test the orphan xterm
   right-click menu (should be covered by the Motif grab fix); decide on the
   native-title-bar drag-lock gap on Motif-Frame-OFF windows.
