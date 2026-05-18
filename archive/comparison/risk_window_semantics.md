# Window semantics — risk register

Three buckets ordered by urgency. Window-semantics is unusually load-bearing for
swift-x because every Motif/Athena toolkit decision about "should I redraw"
rides on top of these events, and the rootless-NSWindow integration depends on
getting the substructure-redirect contract right (or skipping it correctly for
the WM-less case we actually run in).

## Actively bleeding now

### 1. VisibilityNotify is computed from the wrong region. SEVERE.
The spec (`reference/x11-protocol-spec/x11protocol.html:8584-8602`) is
unambiguous: "the state of the window is calculated **ignoring all of the
window's subwindows**." X11R6 implements this exactly in
`reference/X11R6/xc/programs/Xserver/mi/mivaltree.c:miComputeClips:197-234`: it
`RECT_IN_REGION(universe, &borderSize)` where `universe` is the parent-visible
region after subtracting *prior siblings only* — the window's own children have
not been subtracted yet at this point. Modern xorg keeps the same shape
(`reference/xquartz-xserver/mi/mivaltree.c:miComputeClips`).

swift-x derives state from `clipList`
(`Sources/SwiftXServerCore/ServerSession.swift:emitVisibilityChanges:1680-1714`),
and `clipList` in swift-x is defined as `parentVisible ∩ interior −
each-mapped-child's borderClip`
(`Sources/SwiftXServerCore/Region/ClipList.swift:ClipListEngine.recomputeSubtree:84-110`).
So a Motif container window with PushButton/Gadget children covering its
interior reports `area(clipList) == 0` → FullyObscured, even when nothing
sibling-side obscures it. That's the wrong signal entirely.

Trigger: any dt-Motif app whose toolkit shell maps PushButton/RowColumn
descendants that cover the bulk of the parent (dtcalc, dtterm, dthelpview,
dticon — *every* CDE app we boot today). The XmPushButton class uses the
visibility state to decide whether to bother drawing its shadow chrome on
Expose. Project notes say PushButton chrome "doesn't render" and "Motif's
PushButton class ignores our flood" — that's because we're telling it the window
is FullyObscured, which is its signal to skip shadow rendering. Then it
processes the Expose but the chrome work is gated.

Fix shape: separate the visibility computation from clipList. Add a
`borderClipBeforeChildren` Region to `WindowEntry`, populated in
`recomputeSubtree` right after `let borderClip = parentVisible.intersected(...)`
and *before* the child loop. Compute visibility from the (borderSize ∩
parentVisible) vs borderSize comparison — i.e. before children are subtracted.
Drop the area-vs-width*height heuristic in favor of the rgnIN/rgnPART/rgnOUT
trichotomy from `mi_region_RECT_IN_REGION`. This is the single highest-leverage
fix on this dimension. Verify by enabling VisibilityChangeMask on a Motif
PushButton and watching state transitions during sibling overlap — they should
fire on sibling movement, not on the button's own children mapping.

### 2. Sibling stacking order is fabricated from window-ID sort, not from real Z-order. MODERATE-to-SEVERE.
`Sources/SwiftXServerCore/Region/ClipList.swift:directChildren:126-133` sorts
children by numeric `id` ascending and calls this "a stable approximation of
creation order until Step D introduces real X stacking." The handler for
`ConfigureWindow` (`Sources/SwiftXServerCore/ServerSession.swift:2811-2915`)
silently ignores the CWSibling (`1<<5`) and CWStackMode (`1<<6`) bits —
`ValueListReader` knows the bit positions
(`Sources/SwiftXServerCore/ValueListReader.swift:55-56`) but no code reads them
out. xorg's `dix/window.c:ConfigureWindow` (line 2187 modern, 2074 R6) calls
`WhereDoIGoInTheStack` + `ReflectStackChange` and rewires
`pPrev->nextSib`/`pPrev->prevSib`. swift-x's `aboveSibling` in every
ConfigureNotify is hardcoded to `0` (None), telling clients every window is at
the bottom of the stack (`ServerSession.swift:1504, 2850, 2868`;
`MockWindowBridge.swift:117`).

Trigger: any toolkit that restacks children via
`XRaiseWindow`/`XLowerWindow`/`XConfigureWindow(CWStackMode, CWSibling)`.
Examples that should be tested: Motif menus restack helper windows; Athena
`Form` widget; xclock when its update window restacks itself; mwm's
frame-and-icon restacking. Today most of our test apps happen not to depend on
stacking because Motif widget layouts are non-overlapping — so this is silently
fine *until* it isn't. The first overlapping-sibling case will produce wrong
obscuration math and wrong Expose events.

Fix shape: replace `WindowTable._windows: [UInt32: WindowEntry]` with a
parent-keyed linked list (`firstChild` per WindowEntry plus `nextSib`/`prevSib`
on each entry, mirroring `WindowPtr` in xorg). CreateWindow inserts at the top
of the parent's child list (per spec: "the window is placed on top in the
stacking order with respect to siblings"). ConfigureWindow reads
CWSibling/CWStackMode and reorders. ClipList recursion walks via the chain, top
to bottom (matters: parent-visible-region passed down is
post-higher-siblings-subtracted). ConfigureNotify gets the real prev-sibling-id.

### 3. ConfigureNotify and synthetic events always carry `overrideRedirect: false`. MODERATE.
swift-x synthesizes ReparentNotify on every top-level map with
`overrideRedirect: false` even for OR popups
(`Sources/SwiftXServerCore/MockWindowBridge.swift:emitMapSequence:109-127`).
Same for ConfigureNotify in the live-resize path and the ConfigureWindow handler
(`ServerSession.swift:2850-2873`) and ReparentWindow's emitted ReparentNotify
(`ServerSession.swift:3343-3367`). Spec (`x11protocol.html:8731-8743` MapNotify,
`:8768` ReparentNotify, `:8798-8819` ConfigureNotify) requires the field to come
from the window's attribute.

Trigger: clients that watch override-redirect via SubstructureNotify on the
parent (window managers, Xt's GeometryManager looking at OR popups, anything
reading the field off a captured event). For the WM-less rootless mode we run
today this is masked, but a future quartz-wm-style WM-bridge or any client that
diff-checks event field stability will see it. quickplot's helper-window
plumbing is the most likely first-discoverer.

Fix shape: thread `overrideRedirect` from the WindowEntry into every synthesized
event. The MapWindow handler already has `isOverrideRedirect` in scope
(`ServerSession.swift:2583-2607`); pass it through to `mapTopLevel` and
emitMapSequence, and stop hardcoding `false`.

### 4. DestroyWindow doesn't emit DestroyNotify for inferiors. MODERATE.
Spec (`x11protocol.html:8692-8699`): "DestroyNotify is generated on all
inferiors of the window before being generated on the window itself." swift-x's
destroyWindow handler (`ServerSession.swift:2519-2561`) removes only the target
window (`windows.remove(r.window)`), and the parent-walk function
`destroySubtree` (`ServerSession.swift:1279-1291`) — invoked separately by
DestroySubwindows at line 3390 — silently removes descendants without emitting
any DestroyNotify. So when `dtcalc` quits and destroys its panel widget tree,
every descendant DestroyNotify is missed. Athena/Motif callback chains that
listen for child-destroyed via DestroyNotify (event=window) on each inferior
won't fire.

Trigger: any toolkit teardown that walks DestroyNotify for cleanup (Xt's
destroyCallback chain, applications that need to free per-widget resources).
Today we don't hit this because most test apps terminate by closing the
connection rather than gracefully destroying widgets, but it's the kind of bug
that's invisible until a long-running app accumulates leaks.

Fix shape: rewrite `destroySubtree` to walk depth-first and emit
DestroyNotify(event=window) on every inferior in inferior-first order, plus
DestroyNotify(event=parent) via notifySubstructure to each inferior's parent.
DestroyWindow on the target then becomes destroySubtree(target, includeRoot:
true).

### 5. ChangeWindowAttributes ignores most attribute bits. MODERATE.
The handler (`ServerSession.swift:2478-2517`) reads `CWEventMask`,
`CWBackPixel`, `CWBorderPixel`, `CWCursor` — and silently drops `CWBackPixmap`,
`CWBitGravity`, `CWWinGravity`, `CWBackingStore`, `CWBackingPlanes`,
`CWBackingPixel`, `CWOverrideRedirect`, `CWSaveUnder`, `CWDontPropagate`,
`CWColormap`. The CW enum (`ValueListReader.swift:30-46`) names them all but
they have zero readers in the rest of the codebase. spec
(`x11protocol.html:1715-1799`) and R6
(`dix/window.c:ChangeWindowAttributes:905-1411`) say all of these are mutable
post-creation. The most consequential omission is **mid-life
CWOverrideRedirect** (which Motif toggles on menus during posting) and
**CWColormap** (real palette switching, also a gap separately).

Trigger: any toolkit that flips override-redirect post-create (Motif menus do
this; xeyes' shape extension fallback does too in some Athena versions);
gravity-dependent resize behavior (xterm uses NorthWestGravity, xclock uses
CenterGravity); colormap-flicker apps.

Fix shape: every bit needs a setter on `WindowTable` and a read on this path.
bit-gravity / win-gravity then need to feed into the ConfigureWindow handler
when the parent resizes (`x11protocol.html:2143-2241`). Save-under and
backing-store are advisories and can stay no-op per the spec, but the
*attribute* must be stored so GetWindowAttributes returns what the client wrote.

### 6. GetWindowAttributes lies on every backing/gravity/save-under field. LOW-but-real.
`ServerSession.swift:3686-3704` synthesizes the reply with hard zeros for
bit-gravity, win-gravity, backing-store, save-under, and ignores
do-not-propagate-mask entirely (the framer's reply struct *does* have those
fields but the handler doesn't populate them). Spec
(`x11protocol.html:1820-1830`) says GetWindowAttributes must return the actual
attribute values the client set. Toolkits that
ChangeWindowAttributes(CWBitGravity, NorthWest) and later GetWindowAttributes to
confirm will see ForgetGravity (0) back — which is technically the X spec's
default but means we lie about state the client just set. Once fix #5 lands,
this fix is trivial.

## Will bleed when X happens

### 7. SubstructureRedirect is unimplemented. Trigger: running a WM client. MODERATE if/when used.
swift-x has SubstructureNotify
(`ServerSession.swift:notifySubstructure:1204-1218`) but not
SubstructureRedirect. There's no code that checks a parent's eventMask for
SubstructureRedirectMask (`1<<20`) and converts MapWindow → MapRequest,
ConfigureWindow → ConfigureRequest, CirculateWindow → CirculateRequest *before*
doing the operation. R6 (`dix/window.c:MapWindow:2549-2558`) and modern xorg
(`dix/window.c:MapWindow:2673-2675`) gate every map/configure/circulate on
`RedirectSend(pParent) && !pWin->overrideRedirect`, deliver the *Request event,
and skip the actual operation if a redirect client accepted it.

Trigger: the moment we add a WM (whether quartz-wm style adapter or an internal
in-Swift WM that selects SubstructureRedirectMask on root to interpose
decorations or virtual-desktop logic). Today we run rootless without a separate
WM so the issue is dormant. If anyone tries to use swift-x with mwm or twm
running on the Sun side talking back through the wire — that's an immediate
failure.

Fix shape: before each MapWindow / ConfigureWindow / CirculateWindow operation,
look up the parent's `eventMask & SubstructureRedirectMask`. If set and
`!overrideRedirect`, emit MapRequest/ConfigureRequest/CirculateRequest to the
parent and *return without doing the operation*. The current notifySubstructure
helper structure makes this straightforward.

### 8. Backing-store and save-under are advertised as `.never` / `false` in the setup reply. APPROPRIATE.
`Sources/SwiftXServerCore/ServerConfig.swift:122-123` says `backingStores:
.never, saveUnders: false`. Spec (`x11protocol.html:1264-1272`) allows this.
Modern xorg defaults to NotUseful (`xquartz-xserver/dix/window.c:646-652`).
Era-correct for our rootless target. *No risk*. Listed here only because the
project audit might wonder why we don't honor CWBackingStore on incoming
requests — answer is "we said we don't, so we don't have to."

### 9. No CirculateWindow handler at all. LOW.
`grep -E "circulateWindow|.circulate"
Sources/SwiftXServerCore/ServerSession.swift` returns nothing — the opcode (13)
doesn't have a case in the dispatch. R6/xorg
(`dix/window.c:CirculateWindow:2324`/`2435`) restacks based on overlap detection
(`IOverlapAnyWindow`, `AnyWindowOverlapsMe`). swift-x has no Z-order to
circulate (#2), so the natural pairing is: when stacking gets real, add this.
Until then, the opcode just silently does nothing — which is wrong but
unobservable because no test app calls it.

Trigger: twm/mwm-like clients that use XCirculateSubwindows(Up/Down) on their
own panel-window children. We don't have one of those in our corpus today.

Fix shape: add the case to the dispatch, return `Success` with empty effect for
now (or honest BadImplementation if we want to fail loudly per the CLAUDE.md
"lying on the wire is a ledgered exception" rule). The actual restack logic is
part of fix #2.

### 10. ResizeRequest redirect not implemented. LOW.
Spec (`x11protocol.html:2128-2142`): if another client selected
ResizeRedirectMask on the window and ConfigureWindow changes width/height,
server emits ResizeRequest and uses the current size instead of the requested
size. R6 implements this at `dix/window.c:ConfigureWindow:2217-2232`. swift-x's
handler doesn't check ResizeRedirect.

Trigger: tiling-WM-style apps that interpose on resize requests. Not in our
corpus. Same era-relevance as SubstructureRedirect.

Fix shape: identical to SubstructureRedirect — check the bit, emit the redirect
event, skip the operation if accepted.

### 11. Win-gravity isn't honored on parent-resize. MODERATE when triggered.
Spec (`x11protocol.html:2143-2237`) defines gravity-driven child repositioning +
the GravityNotify event. swift-x stores nothing about gravity (fix #5 needed
first) and there's no code that walks descendants when a parent resizes to apply
gravity offsets. The descendant-resize path
(`ServerSession.swift:descendantResized` at the bridge level,
`Sources/SwiftXServerCore/CocoaWindowBridge.swift`) doesn't reposition children
either.

Trigger: any app whose top-level grows and expects centered / east-anchored
children to follow. xclock and xeyes work because their children fill the
top-level (so gravity is moot). xterm uses NorthWestGravity for its menu popups,
which happens to be the default, so no observable bug today. dtcalc / dtterm
have button rows that might depend on gravity for proportional resize, but CDE
apps are usually fixed-size so this is also masked. The first window we'll see
break is anything that's resizable AND has internal layout that depends on a
non-NorthWest gravity.

Fix shape: on ConfigureWindow that changes width/height, walk direct children.
For each child, look up its win-gravity (now stored per fix #5), compute the
delta, apply it to the child's (x, y), emit GravityNotify, and emit
ConfigureNotify if the child position actually changed.

### 12. Bit-gravity is ignored on window-resize. MODERATE when triggered.
Spec (`x11protocol.html:2186-2228`): bit-gravity defines how the *existing pixel
contents* shift when a window is resized. swift-x's resize path (the
ConfigureWindow handler) emits Expose over the grown area but doesn't translate
the pre-existing bitmap. The R6 server's MoveWindow/ResizeWindow path
(`mi/mivaltree.c:miComputeClips` plus the screen MoveWindow callback) handles
this via the bit-gravity attribute.

Trigger: xterm with a static top-bar that should stick on resize
(NorthWestGravity, default, which happens to match what swift-x does); or any
app with non-default bit-gravity. Per spec (`x11protocol.html:2226-2228`) a
server is permitted to ignore the specified bit-gravity and use Forget. We're
already effectively Forget. Era-correct *behavior* is fine; the *attribute* lie
(fix #6) is the only issue.

## Theoretical / spec-only

### 13. InputOnly should not generate VisibilityNotify. LOW.
Spec (`x11protocol.html:1420-1425`, `8620-8623`): InputOnly windows do not
participate in graphics, exposure, or VisibilityNotify. swift-x's
`emitVisibilityChanges` walks every window in the subtree regardless of class.
Today we don't have any InputOnly windows that select VisibilityChangeMask (the
only one we create is our own MWM stub at `ServerSession.swift:360-373`).
Trivial future tightening.

### 14. ConfigureWindow on a window with no parent. LOW.
Spec (`x11protocol.html:2312`): "Attempts to configure a root window have no
effect." swift-x's handler `validateWindowOrRoot` and the early `let result =
windows.resize(...)` with root not in the windows table means we silently no-op.
Compliant. Listed only because the path is one-line-different from what xorg
does (xorg returns Success after a "if (!pParent) return Success" branch at
`dix/window.c:2177-2178` R6 / modern equivalent).

### 15. Border-width validation. LOW.
Spec (`x11protocol.html:1453-1457`): InputOnly with non-zero border-width must
produce BadMatch. swift-x doesn't enforce this. The MWM stub we create
internally is InputOnly with borderWidth=0, so we don't trigger our own bug; an
external client could.

### 16. ChangeSaveSet opcode is missing entirely. LOW.
Opcode 6, used by WMs to ensure that when a manager dies, the managed windows
reparent back to root rather than being destroyed. We have no WM client today;
no test app issues this. Era-relevant if we ever bridge to mwm.

### 17. Do-not-propagate-mask is stored but not consulted by event delivery. LOW.
The input handlers route events up the parent chain when no client has the
event-type selected on the current window. They don't check the originating
window's `do-not-propagate-mask` to suppress that walk. Spec
(`x11protocol.html:1656-1658`) says they should. Unlikely to bite a Motif/Athena
app since toolkits explicitly select on every window they care about, but a
client that depends on do-not-propagate to silence pointer events on a child
would see leakage.

### 18. `RealChildHead` semantics (window-manager frame protection). LOW.
xorg's `dix/window.c:RealChildHead:736-748` lets a WM mark the boundary above
which CirculateWindow / certain ConfigureWindow Above/Below operations cannot
reorder a window (used for top-of-stack icon/util windows). Not a swift-x issue
today (no WM), but era-relevant if we ever add an internal Swift WM.
