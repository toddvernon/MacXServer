# Window semantics — three-way comparison

Authority order: spec > X11R6 > xorg+XQuartz > swift-x. Scope per fork brief:
substructure-redirect, override-redirect, save-under, backing-store, visibility
tracking, stacking, gravity, the family of *Notify events around the window
tree, do-not-propagate, cursor, border-width, InputOnly/InputOutput,
Expose-on-map-descendants.

## What the spec says

The X protocol spec at `reference/x11-protocol-spec/x11protocol.html` defines a
window as a recursive tree with two attribute pools: *core* (the value list
shared with CreateWindow/ChangeWindowAttributes, sec 9 "CreateWindow") and
*derived state* (clipList, visibility, mapped-bit, etc., not directly readable
but observable through events and replies).

**Substructure redirect** (sec 1421-1437 of the glossary plus per-request notes
at sec "MapWindow" `:2005-2015`, "ConfigureWindow" `:2119-2127`,
"CirculateWindow" `:2329-2334`): when a client has selected
`SubstructureRedirectMask` on a window's parent and the window's
`override-redirect` attribute is False,
MapWindow/ConfigureWindow/CirculateWindow on that window emits
MapRequest/ConfigureRequest/CirculateRequest **to the redirecting client** and
**does not perform the operation**. This is the WM contract. Only one client per
parent may select this.

**Override-redirect** (sec "CreateWindow" `:1660-1664`): a per-window BOOL that
suppresses the substructure-redirect mechanism on operations against this
window. Used for popup menus, tooltips, drag indicators. Has *no other* effect —
does not bypass exposure, does not bypass visibility events.

**Save-under** (sec `:1631-1635`, glossary): a per-window advisory hint that the
server should save what's underneath when this window is mapped, so the
underlying windows don't generate Expose when this window unmaps. Almost
universally ignored by modern servers.

**Backing-store** (sec `:1607-1629`): three-state advisory hint — NotUseful /
WhenMapped / Always. Server *may* maintain obscured-region contents. When it
does, Expose events are suppressed for the maintained region. Per-server
capability is advertised in the SetupReply's screen `backing-stores` field.
Per-window state stored regardless of capability.

**VisibilityNotify** (sec `:8584-8651` events:VisibilityNotify): three states —
Unobscured / PartiallyObscured / FullyObscured. The load-bearing line: "the
state of the window is calculated **ignoring all of the window's subwindows**."
So a window with its entire interior covered by a child reports Unobscured. The
state changes only on *sibling* obscuration or on viewability transitions. Spec
also pins ordering: VisibilityNotify follows hierarchy events
(UnmapNotify/MapNotify/ConfigureNotify/GravityNotify/CirculateNotify) caused by
the same change, and precedes Expose events on the same window. Never fires on
InputOnly windows.

**Stacking** (sec "ConfigureWindow" `:2243-2310`): every window has an ordered
position among its siblings. CWSibling + CWStackMode pairs let a client say
`{Above, Below, TopIf, BottomIf, Opposite}`. With no sibling specified, the
operation applies relative to all siblings. CirculateWindow takes RaiseLowest or
LowerHighest and acts based on overlap detection. New windows go on top of
siblings (sec `:1459`).

**Gravity** (sec "ConfigureWindow" `:2143-2241`): two attributes per window.
Bit-gravity controls how the window's own pixel contents shift when its size
changes — values map (NorthWest, North, NorthEast, West, Center, East,
SouthWest, South, SouthEast) to per-pixel offset deltas, plus Static (anchored
to root) and Forget (discard contents). Win-gravity controls how a child window
moves when its parent is resized — same naming, plus Unmap
(unmap-on-parent-resize, generates an UnmapNotify with from-configure=True).
Servers are permitted to ignore bit-gravity and treat as Forget; win-gravity is
not optional.

**The notify cluster**: CreateNotify (sec `:8653`), DestroyNotify (`:8675-8699`,
inferior-first ordering required), UnmapNotify (`:8701-8723` with from-configure
flag), MapNotify (`:8725-8743`), MapRequest (`:8745-8758`), ReparentNotify
(`:8760-8783`), ConfigureNotify (`:8785-8819` with above-sibling field for
Z-position reporting), GravityNotify (`:8821-8842`), ResizeRequest (`:8843+`),
ConfigureRequest, CirculateNotify, CirculateRequest. Most have both a Structure
variant (StructureNotifyMask on the window) and a Substructure variant
(SubstructureNotifyMask on the parent) that differ only in the `event` field.

**Other**: do-not-propagate-mask suppresses event propagation up the ancestor
chain when no one has selected; cursor attribute (None = inherit from parent);
border-width must be zero for InputOnly (`:1453-1457`); InputOnly windows do not
participate in graphics, Expose, or VisibilityNotify (`:1420-1425`);
ChangeSaveSet maintains a per-client list of windows whose
grandparents-up-to-root should not destroy when the client dies.

## What X11R6 did

R6 source is at `reference/X11R6/xc/programs/Xserver/`. Window machinery lives
mostly in `dix/window.c` (request-level handlers) and `mi/mivaltree.c` +
`mi/miexpose.c` (geometry and event computation).

The window data structure (`include/window.h`) has a sibling chain
(`firstChild`/`lastChild`/`nextSib`/`prevSib`) — that's how stacking is
represented, not via an explicit Z-index field. The chain is ordered
top-to-bottom.

`dix/window.c:MapWindow:2529-2616` is the canonical map. The first thing it does
after the early-return on already-mapped is check `RedirectSend(pParent)` and
`!pWin->overrideRedirect`, fabricate a `MapRequest` xEvent, and call
`MaybeDeliverEventsToClient(pParent, &event, 1, SubstructureRedirectMask,
client)` — if that delivers (returns 1), it returns Success without setting
mapped=TRUE. Otherwise sets mapped=TRUE, delivers MapNotify, calls
`RealizeTree(pWin)` to propagate mapped→viewable, then `MarkOverlappedWindows` +
`ValidateTree(pLayerWin->parent, pLayerWin, VTMap)` + `HandleExposures`.
ValidateTree calls into `mi/mivaltree.c:miValidateTree:540` which in turn calls
`miComputeClips`.

`mi/mivaltree.c:miComputeClips:159-477` is the heart of window geometry. It
takes a `universe` region (parent-clip-with-prior-siblings-removed) and the
window itself, then:
1. Lines 197-234: compute new visibility from `RECT_IN_REGION(universe,
   &borderSize)` where `borderSize` is the window's full extent including
   border. If rgnIN → Unobscured, rgnPART → PartiallyObscured, rgnOUT →
   FullyObscured. **Note this is computed before children are subtracted from
   universe** — that's the spec-correct "ignoring subwindows" semantics.
   SendVisibilityNotify fires if the state actually changed and the window has
   VisibilityChangeMask.
2. Lines 317-366: derive `borderClip` from universe ∩ borderBox.
3. Lines 368-427: recurse into children (in sibling-chain order, with sort
   heuristic at line 372-389 picking front-to-back or back-to-front based on
   which sibling ordering already has the chain). Each child gets `universe ∩
   childBorderSize`. After each child, subtract its borderSize from the running
   universe so subsequent siblings see less.
4. Lines 429-446: compute the `exposed` region (universe − old-clipList
   intersect new-clipList) for Expose event generation. Spec section "MapWindow
   `:2017-2026`" requires Expose for the newly-viewable region.
5. Lines 449-458: handle backing-store — `SaveDoomedAreas(pParent, exposed, dx,
   dy)` saves regions about to be obscured if `pParent->backStorage` is set. The
   save-under cousin is in the `DO_SAVE_UNDERS` blocks of `MapWindow` (lines
   2576-2590 and 2682-2727).

`dix/window.c:ChangeWindowAttributes:905-1411` reads every CW bit individually.
The interesting ones for this dimension:
- CWBitGravity (`:1071-1081`): validates `val <= StaticGravity`, sets
  `pWin->bitGravity`.
- CWWinGravity (`:1082-1092`): same shape.
- CWBackingStore (`:1093-1104`): validates value, sets `pWin->backingStore`,
  clears `forcedBS`.
- CWSaveUnder (`:1131-1156`): under `#ifdef DO_SAVE_UNDERS`, fires off
  `ChangeSaveUnder` if the window's viewability and DO_SAVE_UNDERS-eligibility
  match.
- CWOverrideRedirect (validated to BOOL).
- CWCursor: looked up via `LookupIDByType(cursorID, RT_CURSOR)`, refcount bumped
  on the new cursor and decremented on the old.

`dix/window.c:ConfigureWindow:2074-2310` does the heavy lifting for geometry and
stacking. CWSibling without CWStackMode is BadMatch (line 2100). CWStackMode
without CWSibling means "relative to all siblings"; with a sibling, relative to
that one. `WhereDoIGoInTheStack` at line 2184 actually computes the new
sibling-chain position from `{Above, Below, TopIf, BottomIf, Opposite}` + the
geometry. SubstructureRedirect interposition happens at lines 2190-2212, *after*
the new position has been computed but *before* the operation is committed.
ResizeRedirect interposition at lines 2217-2232.

`dix/window.c:CirculateWindow:2324-2398` implements RaiseLowest / LowerHighest
by walking the sibling chain looking for "lowest mapped that is occluded by
another" or "highest that occludes another" via `AnyWindowOverlapsMe` and
`IOverlapAnyWindow`. SubstructureRedirect interposes here too.

`dix/window.c:MapSubwindows:2626-2796` is more interesting than it looks: it
walks the chain top-to-bottom (per spec), marks each unmapped child as mapped,
and only ValidateTrees *once* at the end after every child is marked — so
descendant-Expose generation sees the final state of every newly-viewable
sibling, not a per-child interim state.

`dix/window.c:UnmapWindow:2798-2900` (R6) and the modern equivalent: when a
window unmaps, `MarkOverlappedWindows` + `ValidateTree` recomputes clips for all
formerly-obscured neighbors, then HandleExposures emits Expose events for the
newly-uncovered regions. The from-configure flag is set by callers (e.g.
win-gravity Unmap path).

`dix/window.c:SendVisibilityNotify:3030-3039` is trivial — fills the event
struct and `DeliverEvents(pWin, &event, 1, NullWindow)`. The interesting logic
is upstream in miComputeClips.

R6 also has `mi/mibstore.c` (backing-store implementation, separate file, not
always compiled) — modern xorg has mostly removed it but the R6 source includes
the full mibstore machinery.

## What xorg + XQuartz do today

xorg at `reference/xquartz-xserver/`. Core DIX is in `dix/window.c` (~3300
lines, very similar shape to R6); rootless DDX overrides are in
`miext/rootless/` and `hw/xquartz/`. The R6 → modern delta is mostly:
- Function declarations moved to ANSI-C prototypes.
- `dixLookupResource` replaces `LookupIDByType`.
- XACE (`Xace`) access-control hooks (e.g. `XaceHook(XACE_RESOURCE_ACCESS, ...)`
  at `dix/window.c:MapWindow:2665-2667`) — a security-policy gate; not
  era-relevant for us.
- PANORAMIX / Xinerama threaded through several functions (e.g.
  `SendVisibilityNotify:3016-3104` is mostly PANORAMIX cross-screen
  reconciliation now).
- Backing-store was largely retired. `dix/window.c:472-473` declares
  `disableBackingStore` and `enableBackingStore` globals defaulting to
  FALSE/FALSE, and `:646-652` sets `pScreen->backingStoreSupport = NotUseful`
  unless enableBackingStore was forced on (rarely). XQuartz inherits this. So
  modern xorg + XQuartz tell every client "backing-store NotUseful" but still
  store the per-window attribute for GetWindowAttributes integrity
  (`:1322-1336`).

The core algorithmic shape is unchanged: same sibling chain, same
miComputeClips, same RECT_IN_REGION-vs-borderSize visibility test
(`mi/mivaltree.c:miComputeClips`). The cross-screen wrapper
`SendVisibilityNotify` at `dix/window.c:3016-3104` adds PANORAMIX coordination
but the base path is identical.

**XQuartz rootless overrides** (`miext/rootless/rootlessWindow.c`):
- `RootlessCreateWindow:147-176`: hooks CreateWindow but doesn't create a
  physical surface — defers to RealizeWindow. SETWINREC sets the per-window
  rootless record to NULL initially. `HUGE_ROOT` macro temporarily makes the
  root window enormous so the new window isn't clipped during DIX-level region
  setup.
- `RootlessRealizeWindow:438-476`: called when a window becomes viewable. For
  `IsTopLevel(pWin) && pWin->drawable.class == InputOutput`, calls
  `RootlessEnsureFrame` to create the actual Cocoa frame (CGSWindowRef or
  similar). Subwindows (non-top-level) don't get a frame — they're drawn into
  the parent top-level's surface. **Override-redirect** windows that are
  top-level *do* get a frame (XQuartz uses a borderless NSWindow for them). The
  OR check is at the WM-protocol level in `hw/xquartz/applewm.c` and
  `quartz-wm`.
- `RootlessReorderWindow:540-`: when X stacking changes within a parent, walks
  the sibling chain looking for the next-higher window with a frame and reorders
  the Cocoa frame to match. So Z-order in Cocoa-space follows X stacking for
  top-levels; descendants are flattened into parent surface.
- `RootlessConfigureWindow` (called from the wrapped ConfigureWindow): the
  geometry change is propagated to the rootless frame via `imp->MoveFrame` /
  `imp->ResizeFrame`.

Backing store under rootless is conceptually different: macOS already buffers
every NSWindow, so the spec's "should I maintain contents?" is trivially yes for
top-levels. xorg/XQuartz still reports `backing-store NotUseful` in the setup
reply because the *per-window* backing-store attribute is independent of the
*Cocoa* surface backing.

**Quartz WM** lives in `reference/quartz-wm/src/` — it's the *outside* of the
substructure-redirect contract. It selects `SubstructureRedirectMask |
SubstructureNotifyMask` on root (`quartz-wm.h:46`), handles
`MapRequest`/`ConfigureRequest` in `x-input.m:475` and `:614`, and reframes each
top-level X window with an NSWindow-equivalent frame. Override-redirect at
`x-screen.m:117` is the gate that decides whether quartz-wm wraps a window or
leaves it alone.

So: the spec-side stacking + visibility + map/configure handling is unchanged
R6→modern. The rootless layer adds a parallel Cocoa-frame model glued onto the X
side via wrap-and-call hooks. quartz-wm is the WM piece that lives over the
substructure-redirect contract.

## What swift-x does

swift-x's window-semantics code lives almost entirely in two files:
`Sources/SwiftXServerCore/ServerSession.swift` (handlers, ~4000 lines, with the
window-related cases at lines 2424-3440 plus helpers at 1660-1830) and
`Sources/SwiftXServerCore/Region/ClipList.swift` (~135 lines, the geometry
engine).

**Data model** (`Sources/SwiftXServerCore/ResourceTables.swift:7-87`):
`WindowEntry` is a Swift struct stored in `WindowTable._windows: [UInt32:
WindowEntry]` keyed by window ID. There is **no sibling chain** — Z-order is
reconstructed at clip-compute time by sorting children by their `id` value
(`ClipList.swift:directChildren:126-133`). Fields stored: id, parent, depth, x,
y, width, height, borderWidth, windowClass (InputOutput/InputOnly), visual, raw
valueMask + valueList bytes, mapped bool, eventMask, backPixel, borderPixel,
cursor, overrideRedirect, clipList Region, borderClip Region,
lastVisibilityState. **Not stored as parsed fields**: bit-gravity, win-gravity,
backing-store, backing-planes, backing-pixel, save-under, do-not-propagate-mask,
colormap. (They live in the raw valueList bytes but nothing reads them out.)

**CreateWindow** (`ServerSession.swift:2407-2476`): builds a WindowEntry from
the request, extracts backPixel/borderPixel/cursor/overrideRedirect from the
valueList via `ValueListReader`, inserts into the table. If the parent is root,
calls `bridge?.registerTopLevel` — this also runs for override-redirect
top-levels per the comment at `:2438-2448` ("override-redirect popups need a
slot to attach drawing"). Emits CreateNotify(event=parent) via
`notifySubstructure` if the parent has SubstructureNotifyMask.

**ChangeWindowAttributes** (`ServerSession.swift:2478-2517`): reads only four
bits — CWEventMask, CWBackPixel, CWBorderPixel, CWCursor. CWBackPixel update
calls `bridge?.setTopLevelWindowBackground` so NSWindow.backgroundColor tracks
during live-resize. CWCursor triggers a `refreshCursorIfPointerAffected` to
update the on-screen cursor immediately rather than waiting for the next move.
Everything else is dropped silently (no error emitted, no field updated).

**MapWindow** (`ServerSession.swift:2563-2680`): early-return if already mapped
(per spec). Sets mapped=true, calls `recomputeClipsForSubtreeContaining`, then
forks on top-level-vs-descendant:
- Top-level: `bridge?.mapTopLevel` (which in turn calls
  `MockWindowBridge.emitMapSequence` to fabricate a ReparentNotify +
  ConfigureNotify + MapNotify sequence and Expose for the top-level + every
  descendant with ExposureMask) plus a NSWindow backgroundColor set plus
  `paintWindowRects` to fill the bg + descendant bgs. Then a SubstructureNotify
  variant of MapNotify(event=parent).
- Descendant: `paintWindowRects` for the child's bg, then
  `bridge?.mapDescendant` (which emits MapNotify(event=window)), then
  MapNotify(event=parent) via notifySubstructure, then Expose per clipList rect
  if ExposureMask is set.

The synthesized ReparentNotify is XQuartz-style "pretend the top-level was
reparented to a synthetic WM frame" — see
`MockWindowBridge.swift:emitMapSequence:109-127`. All three synthesized events
hardcode `overrideRedirect: false`.

There is no MapRequest path. The `notifySubstructure` helper
(`ServerSession.swift:1204-1218`) only checks `SubstructureNotifyMask`, never
`SubstructureRedirectMask`.

**MapSubwindows** (`ServerSession.swift:2682-2754`): two passes — pass 1 walks
every unmapped direct child and marks them mapped + emits
MapNotify(event=window) via bridge + MapNotify(event=parent) via
notifySubstructure. Pass 2 (only if parent is mapped) walks newlyMapped IDs and
emits Expose per clipList rect plus paints the child bg. The order is
dictionary-iteration sorted by no key — actually, `for (_, w) in windows.windows
where w.parent == r.window` walks in dictionary order, *unsorted*. Diverges from
spec ("in top-to-bottom stacking order").

**UnmapWindow** (`ServerSession.swift:2756-2809`): captures pre-unmap
borderClip, sets mapped=false, forks on top-level vs descendant. Both branches
emit UnmapNotify(event=parent) via notifySubstructure with `fromConfigure:
false` (the field is plumbed but always false; we don't have the
win-gravity-Unmap path that would set it true). Then
`recomputeClipsForSubtreeContaining` and a `repaintParentOverUncovered` call
that paints the parent bg + emits Expose to parent over the now-uncovered
region.

**ConfigureWindow** (`ServerSession.swift:2811-2915`): reads
CWX/CWY/CWWidth/CWHeight — silently drops CWBorderWidth, CWSibling, CWStackMode.
Resize via `windows.resize` (`ResourceTables.swift:176-186`). Emits
ConfigureNotify(event=window) with hardcoded `aboveSibling: 0` and
`overrideRedirect: false` if size or position changed AND the window has
StructureNotifyMask. Same shape for the substructure variant via
notifySubstructure. Then `recomputeClipsForSubtreeContaining` recomputes clips.
E1.5 path repaints parent bg + Exposes parent over uncovered area (similar to
UnmapWindow). E2 path emits Expose on the window itself if it grew.

**ReparentWindow** (`ServerSession.swift:3320-3377`): updates the parent + x/y
in the entry, emits ReparentNotify(event=window) on the moved window directly to
outbound (always, not gated on StructureNotifyMask — a bug, but not the
load-bearing one), and ReparentNotify(event=parent) on both the old and new
parents via notifySubstructure if they have SubstructureNotifyMask. All three
events hardcode `overrideRedirect: false`. Recomputes clips for both old and new
subtrees.

**DestroyWindow** (`ServerSession.swift:2519-2561`): removes the target entry,
deletes properties, emits DestroyNotify(event=parent) via notifySubstructure.
**Does not recurse to destroy inferiors and does not emit DestroyNotify for
inferiors** — this is a spec violation (sec `:8692-8699` mandates inferior-first
ordering). `destroySubtree` at `:1279-1291` is invoked only by DestroySubwindows
(`:3380-3399`); it walks descendants and removes them but emits no events for
inferiors (only the direct-children DestroyNotify(event=parent) afterward).

**CirculateWindow**: not implemented. `grep -n circulateWindow
Sources/SwiftXServerCore/ServerSession.swift` returns no handler case. Opcode 13
falls through dispatch and the client gets no reply, no error, no notification.

**GetWindowAttributes** (`ServerSession.swift:3686-3704`): synthesizes a reply
from the entry's class + mapped state + eventMask. Every other field is zero —
backing-store=0 (NotUseful), bit-gravity=0 (Forget), win-gravity=0,
save-under=false, do-not-propagate-mask=0. The framer struct
(`Sources/Framer/Replies/GetWindowAttributesReply.swift`) supports all the
fields but the handler doesn't populate them from the WindowEntry (and the
WindowEntry doesn't have them).

**Visibility tracking** (`ServerSession.swift:emitVisibilityChanges:1680-1714`):
computes state from `area(entry.clipList) vs entry.width*entry.height`. clipList
in swift-x is post-children-subtraction (`ClipList.swift:84-110`: `parentVisible
∩ interiorBox − children's borderClips`). So a window with children covering its
interior is reported FullyObscured. **This is the wrong region — spec requires
"ignoring all of the window's subwindows" (`x11protocol.html:8601`); xorg/X11R6
implements it using the pre-child-subtraction universe
(`mi/mivaltree.c:miComputeClips:197-234`).** See risk-register item #1.

**Backing-store + save-under**:
`Sources/SwiftXServerCore/ServerConfig.swift:122-123` advertises `backingStores:
.never, saveUnders: false` in the SetupReply, matching modern xorg + XQuartz
behavior. No per-window state is stored. Honest "we don't do this" rather than a
hidden lie.

**Rootless integration** (`Sources/SwiftXServerCore/CocoaWindowBridge.swift`):
for each top-level (real or override-redirect), creates an NSWindow +
FlippedXView pair. The view holds a CG bitmap backing store that's the window's
actual pixel buffer (this is also the "save state for live-resize" — Cocoa's own
surface backing covers what backing-store would in real X). Override-redirect
top-levels get a borderless, non-activating, popup-level NSWindow per the
comments at `ServerSession.swift:2585-2592`. Cross-NSWindow drag tracking is
approximated with `NSEvent.addLocalMonitorForEvents` — XQuartz uses the private
`xp_*` APIs we can't reach (per project memory).

## Surprises and divergences

**Surprise 1: visibility tracking uses the wrong region.** Spent more time on
this per the brief's special interest. The bug is mechanical and small (one
Region needs to be saved at a different point in `recomputeSubtree`) but the
symptom is global — every Motif container window with child widgets gets
reported as FullyObscured, defeating PushButton/Gadget chrome rendering. The
project notes call this out as "parked" (`INVESTIGATION_MOTIF_INPUT.md` per
CLAUDE.md), but the *root cause* isn't where I'd have guessed from the symptom
(which sounds like an Expose-suppression issue) — it's a region-snapshot-timing
issue inside `ClipListEngine.recomputeSubtree`. Detail in
`risk_window_semantics.md` item #1.

**Surprise 2: substructure-redirect is wholly absent but harmless today.**
swift-x runs WM-less rootless: the macOS window manager handles top-level
decoration, and our X clients aren't running a separate WM on the Sun side
talking back through swift-x. So the entire
MapRequest/ConfigureRequest/CirculateRequest chain — which is roughly 40% of the
volume of xorg's `dix/window.c` — is dead code that we don't need... yet. The
moment a client like mwm or twm gets pulled in (or we add an internal Swift WM
for virtual desktops or for proper menu-anchoring), this becomes urgent. Not "is
X going to break" but "can a whole category of X clients even run."

**Surprise 3: stacking is faked by sorting on window ID.** This is one of those
decisions that's reasonable for a non-overlapping-sibling toolkit (Motif widget
layouts are non-overlapping by design) and absolutely wrong as a general
substitute for a stacking-order chain. The comment at
`Region/ClipList.swift:117-126` is honest about this ("stable approximation of
creation order until Step D introduces real X stacking"). The hidden cost is
*every ConfigureNotify lies about above-sibling* — clients that diff
above-sibling to detect restacking will be misled. Most don't, but Athena and
Motif scrollbars in some configurations do.

**Surprise 4: override-redirect lies in synthesized events.**
`MockWindowBridge.emitMapSequence:109-127` hardcodes `overrideRedirect: false`
in the ReparentNotify, ConfigureNotify, and MapNotify it synthesizes — even
though the caller in `ServerSession.swift:2606-2607` is passing through
`overrideRedirect: isOverrideRedirect`. Tracing through...
`MockWindowBridge.swift:98-108` does take an OR parameter? Let me check.

(`MockWindowBridge.swift:emitMapSequence` signature: `window, geometry,
topLevelEventMask, topLevelExposeRects, descendants, byteOrder, sequence,
outbound, syntheticParent`. No overrideRedirect parameter — that's the issue.
The signature drops it and uses `overrideRedirect: false` in the three events at
lines 113, 121, 126.) Confirmed bug.

**Surprise 5: backing-store is honestly stubbed.** Unlike most of the gaps on
this dimension, backing-store + save-under are *advertised* as not-supported
(NotUseful, false). xorg behaves identically
(`xquartz-xserver/dix/window.c:646-652`). The R6 `#ifdef DO_SAVE_UNDERS` blocks
were optional even in 1994. So this is the rare case where doing nothing is
era-correct.

**Surprise 6: DestroyWindow doesn't recurse over inferiors.** I'd assumed any X
server would. swift-x's handler just `windows.remove(r.window)` without walking
children. The separate `destroySubtree` helper exists but is only called from
DestroySubwindows, and even there it removes children without emitting
DestroyNotify for each. Inferior-first DestroyNotify ordering is a spec MUST
(`:8692-8699`) — silent today because we test with apps that close-the-socket
rather than gracefully destroy widget trees.

**Surprise 7: ReparentWindow does not unmap-and-remap.** Spec says when
reparenting a mapped window, the window should be unmapped before reparenting
and remapped after (R6 follows this at `dix/window.c:2519-2530` modern xorg —
`if (WasMapped) UnmapWindow(pWin, FALSE);` etc). swift-x just updates parent +
position in place. Today no test app reparents a mapped window so it's masked,
but the WM-side test (quartz-wm reparenting all top-levels into frame windows)
would expose this immediately.

**Surprise 8: the spec quote about "is now viewable and contents have been
discarded" cuts deep.** Spec MapWindow `:2017-2026`: "If the window is now
viewable and its contents have been discarded, the window is tiled with its
background... and zero or more exposure events are generated. If a backing-store
has been maintained while the window was unmapped, no exposure events are
generated. If a backing-store will now be maintained, a full-window exposure is
always generated." swift-x's MapWindow path *always* emits Expose (no
backing-store branch). Era-correct (we advertise NotUseful) and matches what
xorg/XQuartz do in practice (NotUseful + always-Expose). The interesting bit
isn't the behavior, it's that swift-x and modern xorg/XQuartz are accidentally
aligned here through "we don't have backing-store" rather than through any
explicit design alignment.

## Blog hooks

- "How a single off-by-one-region defeats Motif chrome rendering" — the
  visibility-state-from-clipList bug. Has a clean, tight story: spec quote, R6
  code, swift-x divergence, symptom, fix.
- "What rootless lets you skip, what it makes you keep" — backing-store goes
  away (Cocoa surfaces handle it), substructure-redirect goes away (only need it
  if you bridge to a separate WM), but visibility tracking still needs to be
  honest because toolkits gate behavior on it.
- "X's sibling chain is a data structure, not just an ordering" — why "windows
  keyed by ID + sort-by-id" is fine for non-overlapping widget layouts and
  silently wrong for everything else, and what xorg's `firstChild`/`nextSib` is
  actually doing for you.
