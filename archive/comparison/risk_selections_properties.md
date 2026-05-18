# Risk register — selections + properties

Authority: X11 protocol spec > ICCCM > X11R6 dix > xorg/XQuartz > swift-x.
swift-x evidence cited as `Sources/<file>:<line>` from a read-only pass.

The headline: the ConvertSelection time-preservation invariant — the
load-bearing fix from 2026-05-10 — is correct and tested. The rest of the
surface is thinner than it looks because dt-apps and quickplot exercise it only
at init via short, non-paginated, single-client paths. The minute anyone real
does a copy/paste of more than ~64KB, or a second X client joins, or a client
disconnects mid-session holding PRIMARY, things break in ways that won't look
like "the selection code is broken."

## Bucket 1 — actively bleeding now

### Selection ownership never auto-revokes on destroy/disconnect (HIGH)

Severity: high. Missing: `DeleteWindowFromAnySelections` and
`DeleteClientFromAnySelections` equivalents. Trigger: any dt-app or Motif app
that takes PRIMARY (xterm-style on a mouse drag, or the dt-apps' `Customize
Data:N`-style ownership probes), then exits or has its window destroyed. The
selection ownership entry sits forever in `ServerCoordinator.selectionOwners`.
Next client to do `GetSelectionOwner` gets back a stale window id, then
`ConvertSelection` forwards a `SelectionRequest` to a destroyed window — swift-x
has no path to detect "owner is gone, fall back to property=None." Real R6
(`dispatch.c:3720 DeleteWindowFromAnySelections`, `dispatch.c:3735
DeleteClientFromAnySelections`) walks the table and nulls the owner; xorg's
`dix/selection.c:112` does the same. The 2026-05-10 fix relied on dt-apps
reading via direct `GetProperty` BEFORE `ConvertSelection`, so this dormant bug
never showed up — but the moment xterm-style mode is on (Edit > Preferences >
Copy mode = "as xterm sees it"), `requestSelectionConversion`
(ServerSession.swift:476) fires a `SelectionRequest` event into the void. Fix
shape: in `destroyWindow` handler (ServerSession.swift:2519) and in session
teardown, walk `coordinator.selectionOwners`, null any owner==thisWindow /
owner-belongs-to-this-session. Note: spec requires the SelectionClear event to
fire to the prior owner when ownership transfers to a new owner — see next item.

### SelectionClear is never emitted (HIGH)

Severity: high. Missing: SelectionClear event emission on ownership transfer.
Trigger: a real X client takes PRIMARY (xterm A), then another real X client
takes PRIMARY (xterm B), then xterm A keeps highlighting and assumes it still
owns PRIMARY — visible double-highlight, plus B's `ConvertSelection` may race
against A still believing it's the owner. Spec is unambiguous (section 9.4
SetSelectionOwner: "If the new owner is not the same as the current owner and
the current owner is not None, then the current owner is sent a SelectionClear
event"); R6 `dispatch.c:855-862` emits it; xorg `dix/selection.c:184-191` emits
it. swift-x: `grep SelectionClear ServerSession.swift` returns nothing. The
handler at ServerSession.swift:3671 just overwrites the coordinator entry. Fix
shape: in the SetSelectionOwner handler, before overwriting, if there's a prior
owner with a different window AND the prior owner is a real client (not a stub
window ≥ 0xFFFE_0000), emit `SelectionClearEvent` to the prior owner. The Framer
wire encoder is already wired (`SelectionEvents.swift:3`).

### GetProperty(delete=True) unconditionally deletes (MEDIUM, becomes HIGH when item 7 is implemented)

Severity: medium today, high once anyone implements INCR. Missing: the spec rule
"if delete is True and bytes-after is zero, the property is also deleted."
Trigger: the INCR pattern — a requestor reads a large property via repeated
`GetProperty(offset=N, length=K, delete=True)` calls. Spec (section 5.3.4
GetProperty / `x11protocol.html` GetProperty) and R6 `property.c:544` only
delete after the final chunk. swift-x always deletes on the FIRST `delete=True`
call (ServerSession.swift:3024 `if r.delete, existing != nil {
properties.delete(...) }`). Doesn't bite today because nobody asks for partial
reads — `r.longOffset` and `r.longLength` are decoded (GetProperty.swift:51,52)
but never honored in the handler. Fix shape: implement partial reads + tie the
delete to "we returned everything." Note: today's behavior is "everything is the
last chunk because everything fits in one reply," which is accidentally
consistent — but pretending offset/length work and then deleting prematurely
will be the bug shape when this comes up.

### Property type filter ignored on GetProperty (MEDIUM)

Severity: medium. Missing: when the request specifies a non-AnyPropertyType type
that differs from the stored property's type, spec requires returning the
property's actual type + format + bytes-after with an empty value
(`x11protocol.html` GetProperty — "if the specified property exists but its type
does not match the specified type, then the return type is the actual type of
the property, the format is the actual format of the property (never zero), the
bytes-after is the length of the property in bytes, and the value is empty").
R6: `property.c:497-507`. swift-x: ServerSession.swift:3005 looks up by
`(window, property)` only, never compares `entry.type` against `r.type`, returns
the data regardless. Trigger: clients that probe a property's type with a wrong
filter (idiomatic in Xt for "is this a STRING or a COMPOUND_TEXT?"). swift-x
will hand them back bytes that don't match the type they asked for, and the
toolkit may misinterpret. The bug-shape will look like "client received
unexpected data type" rather than "property handling is broken." Fix shape:
ServerSession.swift:3005 — if r.type != 0 and entry.type != r.type, return reply
with format/bytesAfter/type set to the stored entry's and value=[].

### ChangeProperty Append/Prepend doesn't enforce format/type match (LOW)

Severity: low. Missing: BadMatch on Append/Prepend when stored type/format
differ from request. R6 `property.c:302-305`. swift-x
`ResourceTables.swift:382-389` silently appends bytes regardless. Trigger: a
buggy client that Appends with the wrong format silently corrupts its own
property. Real X would BadMatch. The dt-apps don't trip this. Fix shape: lift
the type+format check into `PropertyTable.change` and have the caller surface
BadMatch.

### SetSelectionOwner ignores time comparison and CurrentTime substitution (LOW)

Severity: low. Missing: three rules per spec: (a) if request time < current
last-change time, no-op; (b) if request time > server time, no-op; (c)
CurrentTime (0) should be substituted with the actual server time when storing
`lastTimeChanged`. R6 `dispatch.c:817-851` does all three; xorg
`dix/selection.c:154-182` does all three. swift-x ServerSession.swift:3671-3682
just unconditionally writes the new owner. Trigger: hard to trigger from a
single well-behaved client (they always pass either the real timestamp or
CurrentTime). Bites when two clients race for the selection — Xt's selection
ownership-confirmation handshake (`SetSelectionOwner` then `GetSelectionOwner`
to verify) can falsely succeed even when the client passed a stale time. Fix
shape: add the time-comparison logic and CurrentTime substitution. CurrentTime
substitution in particular costs near-nothing — replace `r.time` with
`serverTime` if `r.time == 0` before storing. The store side stays in
ServerCoordinator; the no-op-on-stale check needs to be in the session.

### Atom 0 is silently accepted in some paths (LOW)

Severity: low. Missing: `BadAtom` on atom 0 where the spec requires an atom
argument (not the AnyPropertyType / None contexts). The validateAtom guard at
ServerSession.swift:1596 emits BadAtom when atom 0 reaches it, but callers
explicitly skip the call for `r.type` in ChangeProperty/GetProperty
(ServerSession.swift:2931, 3001) since 0 is a valid sentinel there. For
`r.property` (which must be non-None per spec), validateAtom IS called. This
looks right. Note: this is fine — flagging only because the comment at 1593-1595
says "atom 0 is the caller's responsibility" and that's a footgun to remember;
no fix needed unless an audit catches a missed call site.

## Bucket 2 — will bleed when X happens

### No INCR (HIGH when triggered)

Severity: high once the trigger appears. Missing: the entire INCR mechanism per
ICCCM §2 "Large Data Transfers" + "INCR Properties". Trigger: any selection
conversion where the data exceeds ~64KB minus the request header —
`Setup.maximumRequestLength` in the swift-x setup reply. dt-apps' init-time
selection probes return empty so the issue never triggers. xterm scrollback copy
of more than a screen of text from a Sun would trigger it. Real X selection
owners (in xclipboard, in modern toolkits) hand back type=INCR with the
byte-count as data; the requestor deletes that property, then loops
`PropertyNotify(state==NewValue)` + `GetProperty(delete=True, ...)`, terminated
by a zero-length property. swift-x: nowhere in the source. Even if a Sun client
decided to use INCR for a large paste, swift-x's `requestSelectionConversion`
(ServerSession.swift:476) only handles the simple case — it doesn't listen for
PropertyNotify on the sink window or read the INCR header. Fix shape: gate
copy/paste of large blobs through the INCR state machine on both ends.
xpbproxy's `is_incr_type` (x-selection.m:273) and `property_event:`
(x-selection.m:1063) are the reference. Until then, swift-x cannot reliably
bridge anything bigger than a Sun xterm's max-line-length worth of selection.

### No MULTIPLE target (MEDIUM when triggered)

Severity: medium. Missing: the MULTIPLE target convention from ICCCM §2.6.2.
Trigger: any client requesting `ConvertSelection` with target=MULTIPLE (which
means "the property contains a list of (target, property) atom pairs and you
process them all in one round-trip"). xpbproxy doesn't handle this either
(`x-selection.m:64`: "1. handle MULTIPLE - I need to study the ICCCM further,
and find a test app."). dt-apps don't ask for MULTIPLE during their init. Less
era-critical than INCR since real X11R6 clients rarely used MULTIPLE for the
simple text-paste case. Fix shape: when target==MULTIPLE atom, GetProperty the
property (which is type=ATOM_PAIR), iterate the pairs, fan out to per-target
handlers, and write back a property whose pairs have property=None on each
refused conversion. Defer until a real client hits it.

### No TARGETS reply (MEDIUM when triggered)

Severity: medium. Missing: the TARGETS target. Trigger: any well-behaved modern
requestor that asks "what targets does this selection support?" before doing the
actual fetch. Real Motif Text widgets don't always do this; xpbproxy does
(`x-selection.m:579 send_targets:`). swift-x's `requestSelectionConversion`
(ServerSession.swift:476) hard-codes target=STRING (atom 31) and never offers
anything else. The asymmetry is fine for now (we only talk STRING) but the
moment a Sun client converts CLIPBOARD with target=TARGETS to discover available
formats, the request forwards to the owner as a SelectionRequest, the owner
replies with property=None (rejecting the target), and the requestor falls back.
No swift-x change needed unless we ourselves want to be a selection owner that
answers TARGETS — and we don't, the stub-owner shim does empty.

### No multi-client SelectionRequest routing (MEDIUM when triggered)

Severity: medium. Missing: routing a SelectionRequest event to the right client
session. Trigger: any two-client scenario where client A owns PRIMARY and client
B does ConvertSelection. Today swift-x is single-client-per-session (the
SelectionRequest is just written to the same session's outbound —
ServerSession.swift:3642-3651), so "the owner" and "the requestor" are always
the same client. The coordinator holds owner windows but not the owner session.
When multi-client lands (per the SERVER_CONCURRENCY plan), the coordinator needs
a `(selection, ownerWindow, ownerSession)` triple, and ConvertSelection needs to
write the SelectionRequest to the OWNER's outbound queue, not the requesting
client's. Fix shape: extend ServerCoordinator.SelectionState with `weak var
session` and have the session register itself when it sets ownership. The
mediator already returns the right enum cases — only the actual emission needs
to look up the owner session and call its outbound.

### No PropertyNotify on stub-daemon property pre-publish (LOW when triggered)

Severity: low. Missing: PropertyNotify(state=NewValue) on the SDT Pixel Set
property when the stub window is set up in
`installCDECustomizationDaemonImpersonation` (SelectionMediator.swift:139). It
bypasses the session-level emitPropertyNotify entirely (calls properties.change
directly). Trigger: a dt-app that listens for PropertyChangeMask on the daemon
window to detect when the customization daemon publishes data. They don't today
(they GetProperty directly), so this is dormant. Fix shape: route through
emitPropertyNotify if/when a dt-app turns out to need it. Documented here
because the SHORTCUTS-style stub-daemon path is exactly the kind of corner that
bites later.

## Bucket 3 — theoretical / spec-only

### RotateProperties not implemented (LOW)

Severity: low. Missing: opcode 114 RotateProperties has no decoder and no
dispatch case. Only the name is registered (`OpcodeNames.swift:116`). Trigger:
vanishingly rare in R6 era — used by some Xt internal property-rotation idioms
but I haven't seen it in any captured Sun session. Fix shape: add a
`RotateProperties` request struct (`nAtoms`, `nPositions`/delta, `[atoms]`),
wire dispatch to rotate the per-window property entries' names by `delta mod N`,
emit PropertyNotify per spec, BadMatch on duplicate atoms / missing property. R6
`property.c:103` is the reference.

### ListProperties not implemented (LOW)

Severity: low. Missing: opcode 21 ListProperties — returns the list of atoms for
properties on a window. R6 `property.c:608`. swift-x silently drops (no case in
dispatch). Trigger: xprop and any inspector tool. Doesn't affect normal client
traffic. Fix shape: walk `properties.properties[r.window]` keys, return atom
array.

### Atom uniqueness across clients (LOW — currently correct)

Severity: low / no issue. swift-x atoms are server-global via
`ServerCoordinator.atoms` (ServerCoordinator.swift:19). The same name returns
the same id across sessions. AtomTable is keyed by exact-bytes string match
(case-sensitive, no normalization). R6 atom.c uses a finger-printed BST, but the
protocol-visible behavior matches. No risk found; recording the audit for
completeness.

### GetSelectionOwner doesn't validate the selection atom (LOW)

Severity: low. Missing: BadAtom on an unknown selection atom (R6
`dispatch.c:902` `if (ValidAtom(stuff->id))` else BadAtom). swift-x
ServerSession.swift:3597 calls `coordinator.selectionOwner(r.selection)` which
just returns nil for unknown atoms, replying owner=0 (None) — which is what a
valid-but-unowned selection would also reply. Functionally indistinguishable
from a real client's perspective, but technically spec-divergent. Fix shape:
insert `validateAtom(r.selection, ...)` before the lookup. Same one-line
treatment applies to ConvertSelection (line 3611) and SetSelectionOwner (line
3671). Note: today we'd false-pass tests, but a strict spec auditor would flag
it.

### CUT_BUFFER0..7 not pre-allocated on root (LOW)

Severity: low. Missing: traditional R6 servers pre-create empty CUT_BUFFER0..7
properties on the root window with type=STRING, length=0, so old-school
`xcutsel`-style clients can `RotateProperties` them. swift-x doesn't. Predefined
atoms exist (PredefinedAtoms.swift:16-23) but no root-window properties get
pre-set for them. Trigger: pre-ICCCM clients (xterm in its "use cut buffers"
mode). xterm on Sun was switched to selections long before R6 so this is
unlikely. Fix shape: pre-set during ServerSession init if and only if a real
client trips on it. Defer.

### Predefined atoms only go up to 68 (LOW — correct for R6)

Severity: low / informational. swift-x's predefined atom table stops at 68
(`PredefinedAtoms.swift`, also `AtomTable.swift:15`). R6's `Xatom.h` ends at
XA_LAST_PREDEFINED = 68 (`WM_TRANSIENT_FOR`). Matches the era target exactly.
Modern xorg adds nothing to the predefined set either — `_NET_*` and friends are
all dynamically interned. No risk; confirming the audit.
