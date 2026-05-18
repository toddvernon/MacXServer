# Selections + properties — three-way comparison

Scope: SetSelectionOwner / GetSelectionOwner / ConvertSelection,
SelectionRequest / SelectionNotify / SelectionClear, ChangeProperty /
GetProperty / DeleteProperty / RotateProperties / ListProperties,
PropertyNotify, InternAtom / GetAtomName, predefined atoms, ICCCM INCR +
MULTIPLE + TARGETS conventions, root-window properties (RESOURCE_MANAGER /
_MOTIF_* / CUT_BUFFER0..7 / CDE Customize Data:N + SDT Pixel Set), atom
uniqueness.

## Spec

The X11 protocol spec (`reference/x11-protocol-spec/x11protocol.html`) is the
authority. The relevant rules:

**SetSelectionOwner** — three time-comparison rules that almost every
implementation gets right and a casual reader misses: (a) if request time is
earlier than the selection's last-change time, no-op (still returns Success);
(b) if request time is later than the server's current time, no-op; (c) when
storing, replace CurrentTime (0) with the actual server time. If the new owner
differs from the prior owner and the prior owner is not None, a SelectionClear
event MUST be sent to the prior owner. If the owner client disconnects or its
owner window is destroyed, the owner automatically reverts to None —
last-change-time is preserved.

**GetSelectionOwner** — pure lookup. BadAtom on invalid selection atom. Returns
None when unowned.

**ConvertSelection** — "the arguments are passed on unchanged in either of the
events." This is the load-bearing sentence. The `time` field of the
SelectionRequest or SelectionNotify event carries the request's `time` verbatim.
There is no permission for the server to substitute serverTime. Xt requestors
(and CDE's libDt) match selection replies by `event->time == info->time`;
substituting drops them on the floor.

**ChangeProperty** — BadMatch on Append/Prepend when format or type of the new
data differs from the stored property. Element-count interpretation depends on
format (8/16/32). PropertyNotify(state=NewValue) on success.

**GetProperty** — three reply shapes. (1) Property doesn't exist: type=None,
format=0, bytes-after=0, empty value. The `delete` argument is ignored. (2)
Property exists but type filter doesn't match: type=actual, format=actual (never
zero), bytes-after=full property byte length, empty value. The `delete` argument
is ignored. (3) Property exists and type matches (or AnyPropertyType): compute
`N=length, I=4*long-offset, T=N-I, L=min(T, 4*long-length), A=N-(I+L)`. Value is
the slice `[I..I+L)`; bytes-after=A. Value error if I exceeds N.
**PropertyNotify(state=Deleted) and the actual deletion only fire when
`delete==True AND bytes-after==0`** — that is, on the final chunk of an
INCR-style paginated read. This is the rule swift-x violates today.

**RotateProperties** — rotate the values across the listed property names by
`delta mod N`. BadMatch on duplicate atoms or any non-existent property.
PropertyNotify per property in list order.

**Atoms** — `InternAtom(only_if_exists=False)` always returns the same ID for a
given name within a single server lifetime. Predefined atoms 1..68 are universal
(their names are baked into client code). All atoms post-68 are server-assigned
and may differ across server instances.

## ICCCM

The spec defines the wire format; ICCCM (`reference/icccm/icccm.html` chapter 2)
defines the cooperation patterns.

**SelectionClear listening**: a well-behaved selection owner must register
PropertyChangeMask + handle SelectionClear to drop its "I own the selection"
state, and SelectionRequest to respond. Implementing the server side without
emitting SelectionClear means well-behaved clients can't even know they've lost
ownership.

**TARGETS**: every selection owner is conventionally expected to support
`target=TARGETS`, responding with a property of type=ATOM listing the targets it
supports. Modern toolkit-aware clients (xpbproxy is one) ask for TARGETS first,
then pick a target from the list. Era-correct R6 Motif/Xt clients sometimes ask
for TARGETS and fall back to STRING when they don't get a useful list — so an
owner that ignores TARGETS isn't fatal.

**MULTIPLE**: one round-trip, multiple (target, property) pairs in a property of
type=ATOM_PAIR. Each pair's property field is overwritten with None if the
corresponding conversion failed. Surprisingly rare in real R6 Sun traffic;
xpbproxy explicitly punts (`x-selection.m:64`).

**INCR**: for large data. Owner replies with a property of `type=INCR,
format=32, value=<lower-bound>`. Requestor deletes that property to start the
stream. Owner then appends chunks of the real data (with the real type) to the
same property; each chunk waits for `PropertyNotify(state==Deleted)` from the
requestor before the next append. A zero-length append terminates. The
requestor's loop is `GetProperty(delete=True)` + wait for
`PropertyNotify(state=NewValue)` — and this REQUIRES the spec's "delete only
when bytes-after==0" semantic to work, because the requestor calls GetProperty
with delete=True even on intermediate chunks.

**Cut buffers (chapter 3)**: legacy. PRIMARY/SECONDARY are the selections;
CUT_BUFFER0..7 are eight properties on the root window that some pre-ICCCM
clients (notably very old xterm) used as a poor-man's clipboard via
RotateProperties. Largely vestigial by the Sun-R6 era but still occasionally
seen.

**Root-window properties** in any sane CDE/Motif session: `RESOURCE_MANAGER`
(xrdb-merged Xresources), `_MOTIF_DRAG_WINDOW` (drag protocol coordinator),
`_MOTIF_WM_INFO` ({flags, wmWindow}), `_MOTIF_DEFAULT_BINDINGS`, plus CDE's
`Customize Data:N` selection atoms and `SDT Pixel Set` property on the
customization daemon window. Without these, Motif/CDE either falls back to
default colors or hangs in init.

## X11R6 source

R6 doesn't have a `dix/selection.c`; selection handlers live in
`dix/dispatch.c`.

- `dix/dispatch.c:808 ProcSetSelectionOwner` — all three time rules at lines
  819-822 (future timestamps), 849-851 (past timestamps), and the
  `CurrentSelections[i].lastTimeChanged = time` at line 882 (CurrentTime
  substitution happens via `ClientTimeToServerTime` at line 817 before the
  comparisons). SelectionClear emission at lines 855-862.
- `dix/dispatch.c:896 ProcGetSelectionOwner` — BadAtom on invalid atom (line
  921), else linear scan of CurrentSelections.
- `dix/dispatch.c:927 ProcConvertSelection` — paramsOkay block checks
  `ValidAtom(selection)`, `ValidAtom(target)`, `ValidAtom(property)` (or
  property==None). Forwards SelectionRequest with `event.u.selectionRequest.time
  = stuff->time` (line 955). No-owner fallback: SelectionNotify with
  property=None (line 972), `time = stuff->time` (line 968).
- `dix/dispatch.c:3720 DeleteWindowFromAnySelections` and `3735
  DeleteClientFromAnySelections` — walks the selection table and nulls
  owner/client. Called from window destroy and client disconnect paths.
- `dix/property.c:103 ProcRotateProperties` — full implementation, BadMatch on
  duplicate atoms (line 137) or missing properties (line 148), PropertyNotify
  per atom (lines 167-171), no-op when `delta mod N == 0` (line 157).
- `dix/property.c:181 ProcChangeProperty` + `:242 ChangeWindowProperty` —
  BadMatch when Append/Prepend with mismatched format (line 302) or type (line
  304).
- `dix/property.c:453 ProcGetProperty` — the canonical paginated read.
  Type-mismatch fast path (lines 497-507) returns the property's actual
  type+format+full-length-in-bytesAfter and empty value. Otherwise computes
  ind/len/bytesAfter exactly per spec (lines 519-533). `delete && bytesAfter ==
  0` triggers PropertyNotify(state=Delete) at lines 544-554 and the actual
  deletion at lines 572-583.
- `dix/atom.c:71 MakeAtom` — finger-printed BST keyed on (length, string-bytes),
  so collisions are resolved by strncmp. `lastAtom` is the monotonic counter.
  Predefined atoms (1..68) are pre-installed via `MakePredeclaredAtoms`.

R6 doesn't implement INCR, MULTIPLE, or TARGETS in the server — those are
entirely client-side conventions per ICCCM. The server just shuttles properties
and events; the toolkits do the rest.

## xorg / XQuartz today

The core server-side logic in modern xorg has barely moved from R6.
`dix/selection.c` and `dix/property.c` are the same algorithm with XACE security
hooks bolted on the side and a callback list for selection introspection. The
big XQuartz-specific divergence is the **Cocoa pasteboard bridge**, which is NOT
in the server but in a separate process called `xpbproxy`.

- `dix/selection.c:142 ProcSetSelectionOwner` — same as R6 plus
  `XaceHookSelectionAccess` + `SelectionCallback` calls. Spec rules preserved
  verbatim. SelectionClear emission at lines 184-191.
- `dix/selection.c:226 ProcGetSelectionOwner` — same as R6 plus access hook.
- `dix/selection.c:259 ProcConvertSelection` — same as R6, with the addition at
  line 282: `if (stuff->time == CurrentTime) UpdateCurrentTime();` (server keeps
  its idea of "now" fresh) — but still forwards `stuff->time` verbatim in the
  SelectionRequest event (line 293). The spec-mandated "arguments passed
  unchanged" invariant is preserved.
- `dix/selection.c:112 DeleteWindowFromAnySelections` and `:127
  DeleteClientFromAnySelections` — same as R6, with the addition of
  CallSelectionCallback so introspection clients get notified.
- `dix/property.c` — same shape as R6.

**The Cocoa pasteboard bridge (`hw/xquartz/pbproxy/`)**: xpbproxy is its own X
client process that talks to the local Xquartz server over a real X connection.
It registers for `XFixesSelectionNotify` events on PRIMARY
(`x-selection.m:1488`) so it gets a kernel-private side-channel poke whenever
any X client takes selection ownership. Its main loop (`x-input.m`) also polls
NSPasteboard's `changeCount` to detect Mac-side copies.

The mental model: xpbproxy is a fake X client whose job is to (a) own
PRIMARY+CLIPBOARD on the X side whenever the Mac pasteboard is "newer" than any
X selection, and (b) eagerly grab content from any X client that takes
PRIMARY/CLIPBOARD and stuff it into NSPasteboard. The pasteboard is treated as
the source of truth on direction transitions; the X selection is the source of
truth between them. Five user-toggleable preferences gate the directions
(`pbproxy_prefs` at `x-selection.m:78`): primary_on_grab,
clipboard_to_pasteboard, pasteboard_to_primary, pasteboard_to_clipboard, active.
The default is "everything synchronized both ways except primary-on-mouse-up."
It's a lot of policy for a clipboard.

xpbproxy implements TARGETS (`send_targets:` at `x-selection.m:579`), STRING
(`send_string:utf8:NO`), UTF8_STRING (`send_string:utf8:YES`), COMPOUND_TEXT,
and the image targets. It implements INCR as a requestor (`is_incr_type:` at
line 273, `property_event:` at line 1063) but NOT as an owner — it always sends
whole. It explicitly does NOT implement MULTIPLE (line 64). When responding to
SelectionRequest events from X clients, it ChangeProperty's the data and
`XSendEvent`s a SelectionNotify back to the requestor (`send_reply:` at line
559) — exactly the protocol owner pattern.

The XQuartz server side itself (dix/selection.c, dix/property.c) is just R6. All
of the Mac-pasteboard logic lives outside the server in xpbproxy as a normal X
client. That's the architectural call-out: **XQuartz does not bridge the
pasteboard in the server**; it ships a daemon to do it via the ordinary client
protocol.

## swift-x

Per-server state lives in `ServerCoordinator`
(Sources/SwiftXServerCore/ServerCoordinator.swift). Per-session selection
routing policy lives in `SelectionMediator`
(Sources/SwiftXServerCore/SelectionMediator.swift). Property storage lives in
`PropertyTable` (Sources/SwiftXServerCore/ResourceTables.swift:374-409). Atom
interning lives in `AtomTable` (Sources/SwiftXServerCore/AtomTable.swift),
seeded with the 1..68 predefined names from
`Sources/Framer/PredefinedAtoms.swift`.

- `ServerCoordinator.selectionOwners: [UInt32: SelectionState]`
  (ServerCoordinator.swift:30) keyed by selection atom, valued with `(window,
  time)`. NSLock-guarded. The coordinator is shared across all sessions on the
  server (the per-server tier of the two-tier model).
- `SelectionMediator.convertSelection(_:)` (SelectionMediator.swift:80) returns
  an enum: `replyNoOwner`, `forwardToRealOwner(window)`, or
  `stubOwnerReplyEmpty(window)` based on whether the resolved owner is in the
  server-internal stub range (≥ 0xFFFE_0000). The session then emits the right
  event using a single shared time path.
- `SelectionMediator.installCDECustomizationDaemonImpersonation()`
  (SelectionMediator.swift:116) is the 2026-05-10 unlock for CDE dt-apps. It
  registers a synthetic InputOnly window at 0xFFFE_0003 as the owner of the
  `Customize Data:0` selection AND pre-publishes the `SDT Pixel Set` property on
  that window with bytes captured verbatim from a real u5 CDE customization
  daemon. When dt-apps GetProperty(SDT Pixel Set) on the daemon window, they get
  the real bytes; when they then ConvertSelection as a formality, the stub-owner
  short-circuit answers with empty bytes + SelectionNotify(success).
- `ServerSession` handler for `convertSelection`
  (ServerSession.swift:3611-3667): three branches matching the mediator's enum.
  In all three branches, `event.time = r.time` — the load-bearing
  time-preservation invariant. Comment at line 3613 explains why ("Xt's
  HandleSelectionReplies in X11R6 Selection.c uses MATCH_SELECT, which checks
  `event->time == info->time` and silently drops the event if they differ").
  Test coverage: `Tests/SwiftXServerCoreTests/ConvertSelectionTests.swift:50`
  and `:79` assert time round-trip.
- `ServerSession.changeProperty` handler (ServerSession.swift:2923) — validates
  window + property atom (skips type validation when type==0), writes through to
  PropertyTable, emits PropertyNotify(NewValue) via `emitPropertyNotify`
  (ServerSession.swift:1184). Side-channel hooks: WM_NAME / WM_ICON_NAME (atoms
  39, 37) get pushed to NSWindow titles; WM_CLASS triggers the per-session log
  rename + title prefix; arrivals at `selectionSinkWindow` (0xFFFE_0001) with
  the magic property `SWIFTX_CLIP_FROM_X` write to NSPasteboard
  (ServerSession.swift:2978-2984). That's swift-x's pasteboard bridge: a single
  property-write interception on a single sink window. Compare and contrast with
  xpbproxy's many-hundred-line state machine.
- `ServerSession.deleteProperty` handler (ServerSession.swift:2986) — validates,
  deletes, emits PropertyNotify(Deleted) only if the property existed.
- `ServerSession.getProperty` handler (ServerSession.swift:2997) — validates,
  looks up by `(window, property)` only (no type filter), returns the whole
  property regardless of `r.longOffset` / `r.longLength` (decoded into the
  request struct at GetProperty.swift:51,52 but ignored at use site).
  `bytesAfter` always 0. `delete=True` always deletes immediately — does not
  honor the spec's "only on bytes-after==0" rule.
- `ServerSession.setSelectionOwner` handler (ServerSession.swift:3671) — owner=0
  clears, else writes through to coordinator. Does not enforce the three time
  rules, does not substitute CurrentTime, does not emit SelectionClear to the
  prior owner.
- `ServerSession.getSelectionOwner` handler (ServerSession.swift:3597) —
  coordinator lookup. Does not validate the selection atom.
- `ServerSession.destroyWindow` handler (ServerSession.swift:2519) — calls
  `properties.deleteAll(window:)` but does not walk
  `coordinator.selectionOwners` to null any owner-by-this-window. This is the
  "selection ownership stale after destroy" risk.
- Mac-side pasteboard bridge: the entire Cocoa-pasteboard story is a
  `requestSelectionConversion` (ServerSession.swift:476) call that emits a
  single SelectionRequest event with target=STRING (atom 31, hard-coded) to the
  current PRIMARY owner, requestor=selectionSinkWindow (0xFFFE_0001,
  hard-coded), property=SWIFTX_CLIP_FROM_X. When the owner ChangeProperty's the
  result back, the handler at ServerSession.swift:2978 intercepts and writes the
  bytes (as ISO Latin-1) to NSPasteboard. No TARGETS negotiation, no UTF8_STRING
  fallback, no INCR. For pasting Mac→X, the paste handler synthesizes
  KeyPress/KeyRelease events per character via the US-ASCII keymap
  (`handlePaste` at ServerSession.swift:502) — it does not use the selection
  protocol at all. That's a deliberate divergence from xpbproxy's "be a fake X
  client that owns the selection" model: swift-x lives inside the server, so it
  has the option of synthesizing keystrokes that look like a typing user, which
  xpbproxy can't.
- RotateProperties (opcode 114) and ListProperties (opcode 21): named in
  `Sources/Framer/OpcodeNames.swift` but have no request struct, no dispatch
  case, no behavior. Silent drop.

Root-window properties pre-published in ServerSession init
(ServerSession.swift:310-416): `_MOTIF_DRAG_WINDOW` (rationale: dodges a Motif
segfault when no drag coordinator exists), `_MOTIF_WM_INFO` ({flags=1,
wmWindow=0xFFFE_0002 stub child of root}), `RESOURCE_MANAGER`
(text="*customization:\t-color\n" to steer Xt to load -color flavored
app-defaults under CDE). Then SelectionMediator's stub-daemon impersonation
publishes `SDT Pixel Set` on 0xFFFE_0003.

## Surprises and divergences

**The MATCH_SELECT fix is the smallest correct change anyone in the X server
world has ever made**: one-line "echo r.time verbatim, don't substitute
serverTime" in the SelectionNotify path. Until 2026-05-10, swift-x was using
serverTime there (presumably copy-pasted from ButtonPress / KeyPress emission,
which DOES legitimately use serverTime). The bug was invisible — SelectionNotify
did fire, dt-apps just silently dropped it inside Xt and the apps wedged in
their init handshake forever. The whole CDE/Motif app suite came online once
that line changed. There's a blog hook in that.

**xpbproxy is more complicated than the X server's selection code**. It's about
1500 lines of Objective-C running as a separate X client; the server's
selection.c is about 300 lines of C. The asymmetry happens because pasteboard
semantics are not selection semantics: pasteboards have no concept of "owner
client," they have "last writer wins" + a generation counter; selections have
"owner can refuse a conversion" + per-target negotiation. Bridging between them
requires emulating an X owner client with a state machine that polls the
pasteboard's generation counter, plus a state machine that handles all the
SelectionRequest event shapes a real X owner has to handle. swift-x has the
option to skirt most of this because it IS the server: the
property-write-interception path at ServerSession.swift:2978 is a one-line
shortcut that wouldn't be available to an external bridge. But it's also why
swift-x's bridge is incomplete (no TARGETS, no INCR, no MULTIPLE, no
UTF8_STRING) and xpbproxy's is mostly complete.

**No SelectionClear, no auto-revoke**: this combination is the biggest
currently-dormant trapdoor. Today the server is single-client-per-session and
there are no real Sun-side races for PRIMARY ownership, so neither bites. The
day someone runs two real Sun clients at once, ownership transitions and
disconnect cleanup both become correctness-critical and both are missing. R6 and
xorg both implement these in fewer than 30 total lines. The fix is small; the
latent bug is large.

**swift-x decodes longOffset/longLength but ignores them**:
GetProperty.swift:51-52 reads the fields, ServerSession.swift:2997 just doesn't
use them. Real Sun clients today never ask for partial reads because they never
get INCR responses (we never SEND INCR, since stubs return empty), so the offset
is always 0 and length is always "lots." The handler accidentally returns the
right answer for every actual request it receives. This is a fragile-by-design
state — works because the inputs are constrained, breaks the moment a real INCR
producer talks to us.

**Atom range design is era-correct**: 1..68 predefined, 69+ dynamic, monotonic.
Resource-ID range design also looks era-correct: `resourceIdBase=0x04400000,
resourceIdMask=0x001FFFFF`, with the coordinator allocating non-overlapping
per-client ranges. The stub windows live at 0xFFFE_xxxx, comfortably above any
client allocation. The convention "stub window iff id ≥ 0xFFFE_0000" is the
routing key in SelectionMediator.isStubWindow.

**XQuartz's dix is just R6 with hooks**: the architectural lift in 30 years of
xorg evolution went into extensions, not into core protocol implementations.
selection.c and property.c read like minor edits to the same R6 code. That's
reassuring for the era target — there's no "modern X did this completely
differently and you'll have to deal with it" surprise lurking. The hard parts
(XACE, the introspection callbacks) are no-ops for our purposes.

## Blog hooks

1. **"The one-line fix that unblocked CDE: MATCH_SELECT and the time field that
   must not change."** Walk through what Xt's `HandleSelectionReplies` does, how
   it uses `event->time == info->time` as the correlation token, why swift-x's
   instinct to fill in serverTime was wrong, and how the bug shape was
   "everything works on the wire, the client sees the events, then drops them
   silently inside its own toolkit." This is a great showcase for why
   protocol-level XErrors aren't enough — sometimes the bug is that you're TOO
   helpful and rewrite a field that the client side relies on being preserved
   verbatim.

2. **"The Cocoa pasteboard is not a clipboard, and three different X servers
   have three different lies about it."** XQuartz runs xpbproxy as a separate
   process pretending to be an X client; the real X server doesn't know the Mac
   pasteboard exists. swift-x sneaks a property-write interception into the
   server itself (one line in the ChangeProperty handler) and skips the
   protocol-mediated dance entirely. R6 of course never had the problem because
   there was no Mac pasteboard. Compare the architectural cost of "pretend to be
   a client" vs "be the server" vs "the world doesn't exist" — and what each
   lets you skip. The xpbproxy-vs-swift-x asymmetry on TARGETS / UTF8_STRING /
   INCR support is a direct consequence of where the bridge sits in the stack.

3. **"The dormant trapdoor in single-client X servers: selection ownership
   cleanup."** A single-client server with no multi-client tests passes every
   test you write, including the ones that look like they cover ownership
   transitions — because the same client owns and requests, the SelectionRequest
   forwards correctly, everyone goes home happy. The moment a second client
   joins, the missing SelectionClear emission means client A still thinks it
   owns the selection; the missing auto-revoke means a disappeared client's
   ownership entry sits in the coordinator forever. The fix is small (~30
   lines), but the absence is hard to notice if your test corpus is
   single-client. Useful cautionary tale about the limits of corpus-grounded
   testing.
