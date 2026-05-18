# Risk register: errors on the wire

Scope: every Bad* code, when emitted per spec, the 32-byte error format,
sequence number tagging, major/minor opcode, resource-id-or-value. Read-only
scan of `Sources/SwiftXServerCore/ServerSession.swift` (4014 lines) plus
`Sources/Framer/ServerMessage.swift` (encoder). Cross-checked against
`reference/x11-protocol-spec/x11protocol.html` chapter 4 and the per-request
"Errors:" lines, and against
`reference/X11R6/xc/programs/Xserver/dix/dispatch.c` for the canonical R6
emission shape.

The good news up front: the framer's `XError.encode`
(ServerMessage.swift:135-151) gets the byte layout right (type=0, code, seq,
badResourceId, minorOpcode, majorOpcode), and `ServerSession.emitError`
(ServerSession.swift:2217-2236) stamps the live sequence number, supports both
byte-orders, and logs prominently with `[XERROR]`. The wire format is not the
problem. What's wrong is *coverage*: most spec-listed error conditions are not
detected at the handler level. The XError-honesty policy is real and partially
in flight, but "silently fake success" is still the default on a long list of
opcodes.

## Bucket 1 — actively bleeding now

### B1.1 CreateWindow validates nothing. Severity: HIGH
swift-x's CreateWindow handler (ServerSession.swift:2416-2476) reads the
value-mask and inserts a WindowEntry with whatever the client sent. There is
zero validation. Spec § "CreateWindow" requires: **Alloc, Colormap, Cursor,
IDChoice, Match, Pixmap, Value, Window**. R6 ProcCreateWindow
(`dix/dispatch.c:337-378`) enforces six of them per request:
`LEGAL_NEW_RESOURCE`, parent LookupWindow → BadWindow, `Ones(stuff->mask) !=
len` → BadLength, `!width || !height` → BadValue, `AddResource` failure →
BadAlloc, plus CreateWindow itself returning Match/Value on class/depth/visual
mismatches. swift-x emits none of these. Triggers in real use: any client
passing an unknown `parent` (race after parent destroy is the canonical case —
Motif/Athena toolkits do this routinely during teardown), zero width/height (Xt
geometry manager defensive paths), duplicate `wid` from a buggy client. Today
the bad CreateWindow just "succeeds" with a phantom window in the table, and
every subsequent operation referencing that window also "succeeds" — the client
never hears about its bug and we accumulate state we don't understand. Fix
shape: add validateWindowOrRoot on parent (only valid parents), check
width/height nonzero, check `wid` not already in `windows`/`pixmaps`/
`gcs`/`fonts`/`cursors`, validate the optional `backing-pixmap` / `colormap` /
`cursor` IDs in the value-list. Emit BadValue for the specific malformed
numeric, BadMatch for parent-depth-mismatch.

### B1.2 OpenFont, CreateGC, CreatePixmap, AllocColor: no IDChoice / drawable validation. Severity: HIGH
- OpenFont (3029-3036): inserts a FontEntry under `r.fid` with no check that
  `fid` is free. Spec: IDChoice, Alloc, Name. We emit none.
- CreatePixmap (3059-3060): one line, `pixmaps.insert(...)`. No IDChoice, no
  BadDrawable on `r.drawable`, no BadValue on width=0/height=0 or unsupported
  depth, no BadAlloc. Spec lists all four.
- CreateGC (3069-3070): same shape. No IDChoice, no BadDrawable, no
  BadFont/BadPixmap/BadCursor on value-list resources, no BadMatch on
  tile/stipple/clip-mask depth.
- AllocColor (3080-3089): no BadColor on the colormap argument (we don't even
  track colormaps — there's only the implicit default one). No BadValue. Always
  "succeeds." Same shape on AllocNamedColor / LookupColor, with the extra
  wrinkle that an unknown name falls back to black instead of emitting BadName
  (3091-3112, 3114-3131; explicit log line says "falling back to black ... we
  don't emit XErrors yet (per SHORTCUTS)" — exact ledgered-lie shape).

R6 enforcement is uniform: `LEGAL_NEW_RESOURCE`, `VERIFY_GEOMETRABLE`,
`VERIFY_DRAWABLE`, etc. (ProcCreatePixmap dispatch.c:1305-1344; ProcCreateGC
dispatch.c:1368-1392). Trigger: any client probing the resource ID space (Xlib's
`XAllocID` is the canonical mechanism, and a confused client passing a stale GC
ID will get a phantom-success from us where R6 says BadGC). We've seen this
category of bug exactly because our resourceIdBase happens to match Sun's — when
those preconditions stop holding, we'll start corrupting state silently. Fix
shape: a generic `validateNewResourceId(id, ...)` helper that emits BadIDChoice
if `id` is in the wrong range or already in use across all resource tables.

### B1.3 ConfigureWindow does not enforce BadMatch on stack-mode/sibling, no BadValue on enum values. Severity: MED
ConfigureWindow (2811-2915) validates the window via `validateWindowOrRoot` and
otherwise reads the value-list and applies it. Per spec, ConfigureWindow must
emit: **Match, Value, Window**. R6 also catches BadLength via `Ones(mask) !=
len` (dispatch.c:591-593). swift-x emits BadWindow only. A client sending
`sibling` without `stack-mode`, or a `stack-mode` enum outside 0..4, or
stack-mode `TopIf/BottomIf/Opposite` with sibling-not-a- sibling — all should be
BadMatch / BadValue per spec, and all of these "succeed" today. Trigger: any WM
that drives stacking through ConfigureWindow (quartz-wm is the canonical case
but we're rootless — first WM-flavored client probing stacking will hit this).
Fix shape: when CWSibling is in the mask, require CWStackMode also set; validate
stack-mode enum range; verify sibling is a real sibling.

### B1.4 PutImage, PolyText8/16, ImageText8/16 silently fall back when font/drawable invalid. Severity: MED
PutImage handler (3303-3318) emits BadDrawable on unknown drawable and BadGC on
unknown GC — that part is honest. But ImageText8/PolyText8 (handler helpers in
2080-2122) silently fall back to a synthesized "fixed" font when the GC's font
slot is unknown. Spec says: GContext is part of the request, its current font is
part of GC state, and an unknown font in a graphics request should produce
BadFont (or BadMatch on cross-screen GC). xterm hitting "phantom-fixed
substitute" is a debugging-rabbit-hole away from the truth. Trigger: a client
whose font allocation got freed under it (Motif does this on widget
destruction). We'll render with the wrong font and the client won't know. Fix
shape: emit BadFont when the GC's font slot references a freed font.

### B1.5 Request decode failure swallowed silently. Severity: MED
`tryRequest` (2380-2408) catches decode errors and logs but emits NO XError.
Comment: "M1: don't synthesize XError for decode failures yet — for our capture
corpus, decode is trusted." Live clients are not trusted. R6 + xorg emit
`BadLength` for under/oversize requests via the `REQUEST_*_SIZE` macros,
returned from every Proc and turned into an error by the dispatcher. Trigger:
any framer decode bug, any client that sends a slightly-malformed request (this
happens — corrupted middleware, partial sends across a broken bridge, version
skew). Today we just stop dispatching and the client hangs in `_XReply` waiting
for a response that's not coming. Also: `tryRequest` line 2388-2391 returns nil
on `totalSize < 4`, which is "closing" — should be BadLength on the wire, not a
silent close. Fix shape: on decode throw, emit `BadLength` (most likely cause)
using `bytes[0]` as the major opcode and the current sequence number.

### B1.6 SetupRefused is never emitted. Severity: LOW-MED
ServerSession.swift:2340-2347 handles a bad byte-order marker by logging and
returning nil — which lets the transport close, but the client sees an
unexpected EOF instead of a SetupRefused with a useful `reason` string. The
framer (`Framer/Setup/SetupReply.swift:27-64`) has a `SetupRefused` encoder
ready to go, and ServerSession.swift:2215 even references the SetupRefused path
in a comment. Just unused. xorg/XQuartz call `SendConnSetup(client, reason)` in
this case (`dix/dispatch.c:3683-3697`) and write a proper xConnSetupPrefix with
`success=xFalse`. swift-x also doesn't enforce the protocol-major/minor fields,
so a client speaking X12 (hypothetical) would get the same silent disconnect.
Trigger: any client with a corrupted setup (rare; only an issue once we have
non-trivial clients connecting). Fix shape: build a SetupRefused with a useful
reason string, emit it, then close.

## Bucket 2 — will bleed when X happens

### B2.1 No multi-client BadAccess paths. Trigger: a second client connects.
The spec lists BadAccess for: GrabButton/GrabKey (someone else already grabbed
the same combo), FreeColors on entries not owned by this client, StoreColors on
a read-only colormap, ChangeHosts from a non-local client, SelectInput with
redirect masks already taken. swift-x is single-client-only today (per CLAUDE.md
status note) and emits BadAccess from nowhere. When the session manager and a
regular client both want SubstructureRedirect on root (canonical BadAccess),
we'll grant both. Fix shape: when multi-client lands, add per-resource "owner
client" tracking and enforce these. Not load-bearing yet.

### B2.2 GetImage, CopyPlane unimplemented; CopyArea cross-window emits BadImplementation. Trigger: client uses any of them.
CopyArea cross-window emits BadImplementation today (2146 — honest), which is
the right shape (BadImplementation is the spec-blessed "we don't do that" escape
valve). GetImage is just absent from the dispatch — currently opcode→unknown →
BadRequest, which is acceptable but technically wrong (should be
BadImplementation for a defined-but-unsupported core opcode). Same for
CopyPlane, GetMotionEvents, CreateColormap, etc. Trigger: any Motif menu
screenshot path, any xv-style "grab my window's pixels" behavior. Fix shape:
route core-opcode-not-implemented through `emitError(.implementation, ...)`
rather than the unknown-opcode → BadRequest fallback. Honest semantics, same
robustness.

### B2.3 ChangeProperty mode/type/format BadValue gaps. Trigger: a client passing format other than 8/16/32.
ChangeProperty (2923-2984) validates the window and the property/type atoms but
does NOT validate `format` ∈ {8,16,32} or `mode` ∈ {Replace, Prepend, Append}.
Both should be BadValue per spec. Today an invalid format goes into the property
table and corrupts the read-back. Trigger: a buggy client setting format=0 or 7
(rare but legal-looking on the wire). Fix shape: enum-validate before storing.

### B2.4 GrabPointer/GrabKeyboard return GrabSuccess unconditionally. Trigger: client expects GrabFrozen/AlreadyGrabbed/InvalidTime.
GrabPointer/GrabKeyboard each have a reply, not just an error. The reply
contains a `status` enum — Success, AlreadyGrabbed, InvalidTime, NotViewable,
Frozen. swift-x's grabs return Success unconditionally (handler in
handleGrabPointer/handleGrabKeyboard — both called from
ServerSession.swift:3230-3270, body lives lower in the file). When two clients
race for a passive grab (multi-client future), or when a client tries to grab a
not-yet-viewable window, the spec status codes matter. Not exactly an XError,
but in the same "lying on the wire" family.

### B2.5 No BadMatch on InputOnly window used as drawable. Trigger: a client tries to draw into an InputOnly child window.
`validateDrawTarget` (1624-1634) accepts any known window. The spec says
InputOnly used as a drawable → BadMatch. We track windowClass on the WindowEntry
(.inputOnly is in the enum, used in GetWindowAttributes:3694) but never gate
drawing on it. Trigger: an Xt application creating an InputOnly child for
event-only-area capture and a sibling client mistakenly drawing into it. Rare in
practice but a real spec violation. Fix shape: in `validateDrawTarget`, check
`windowClass != .inputOnly` and emit BadMatch otherwise.

## Bucket 3 — theoretical / spec-only

### B3.1 `minorOpcode` field is always zero. Severity: cosmetic until extensions land.
`emitError` accepts a `minorOpcode` parameter (defaulted to 0) but no caller
passes it. That's fine for now because swift-x implements no extensions, so
"minor opcode = 0" is the correct value for every core request. The day we add
SHAPE or BIG-REQUESTS, every extension error will need to carry the minor.
xorg's dispatcher captures this in `client->minorOp` per request
(`dix/dispatch.c:524-530`). Fix shape: when extension dispatch goes in, plumb
the minor-opcode through the request struct and pass it to `emitError`.

### B3.2 BadValue's "failing value" field is overloaded with `badResourceId`. Severity: cosmetic.
The framer's `XError.encode` takes one `badResourceId` field that the spec says
contains either the failing resource ID, the failing atom, or the failing value
depending on the error code. The encoder is fine with this — it just writes 32
bits at offset 4. But the parameter name in `emitError` leans toward
"resourceId," which is misleading for BadValue. We emit BadValue from nowhere
today so it doesn't matter, but when CreateWindow starts checking width=0 etc.
the callsite has to remember to pass the offending uint32 in the "badResourceId"
slot. Worth a comment update or a typed wrapper
(`badId(.value(failingNumber))`).

### B3.3 No `errorsEmitted` counter exposed. Severity: cosmetic.
ServerSession tracks `errorsEmitted` (2233) but it's only logged. Useful to
expose for the milestone-review subagent's audit pass: an honest server shipping
zero errors during a captured corpus replay would be suspicious (real X traffic
includes BadWindow on every WM probe). Not a correctness issue.

### B3.4 No `BadAlloc` ever emitted. Severity: theoretical.
Swift won't malloc-fail the way C does; the runtime will crash. Spec allows
BadAlloc on any request, and clients are required to handle it. The right place
to emit it is at resource-cap policies (max windows, max pixmaps) which we don't
enforce today, so it's a deferred concern.

## Summary

Codes with at least one honest emission site: BadWindow, BadAtom, BadGC,
BadDrawable, BadFont, BadCursor, BadPixmap, BadImplementation, BadRequest. Codes
never emitted: **BadValue, BadMatch, BadAccess, BadAlloc, BadColor, BadIDChoice,
BadName, BadLength**. That's 8 of 17. Three of those eight (BadValue, BadMatch,
BadIDChoice) are bleeding actively per Bucket 1.
