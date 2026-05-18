# Errors on the wire: spec / X11R6 / xorg+XQuartz / swift-x

Three-way comparison of how X11 protocol errors get emitted. Reference order is
spec > X11R6 > xorg/XQuartz > swift-x.

## Spec (x11-protocol-spec/x11protocol.html, "Error Format" + chapter 4)

Errors are 32 bytes. Layout:

```
byte 0:     0 (error marker)
byte 1:     error code (1..17 core, 128..255 extension)
bytes 2..3: sequence number (low 16 bits of failing request)
bytes 4..7: failing resource ID, failing atom, or failing value
            (zero for codes that have no extra data — Access, Alloc,
            Implementation, Length, Match, Name, Request)
bytes 8..9: minor opcode (zero for core requests; non-zero only for
            extension requests)
byte 10:    major opcode of failing request
bytes 11..31: unused, not guaranteed zero
```

Section 4 lists 17 core codes: Request, Value, Window, Pixmap, Atom, Cursor,
Font, Match, Drawable, Access, Alloc, Colormap, GContext, IDChoice, Name,
Length, Implementation. Each request's spec section ends with an "Errors:" line
enumerating which codes that request can emit. CreateWindow can emit Alloc,
Colormap, Cursor, IDChoice, Match, Pixmap, Value, Window. ChangeWindowAttributes
can emit Access, Colormap, Cursor, Match, Pixmap, Value, Window. And so on for
every request.

Important nuance from chapter 4 prologue: "when a request terminates with an
error, the request has no side effects (that is, there is no partial
execution)." The seven exceptions are listed explicitly: ChangeWindowAttributes,
ChangeGC, PolyText8, PolyText16, FreeColors, StoreColors, ChangeKeyboardControl.

BadImplementation is specifically called out as something a server *should* emit
when a core feature isn't implemented, even though it's not listed under any
specific request: "this error is not listed for any of the requests, but clients
should be prepared to receive such errors and handle or discard them."

## X11R6 (reference/X11R6/xc/programs/Xserver/dix/dispatch.c)

R6 uses a dispatcher-driven pattern. Every Proc function returns a status code
(`Success`, `BadWindow`, etc.). The dispatch loop at lines 285-317 calls
`(*client->requestVector[MAJOROP])(client)` and if the result is non-Success,
calls `SendErrorToClient(client, MAJOROP, MinorOpcodeOfRequest(client),
client->errorValue, result)`.

`SendErrorToClient` at `dix/dispatch.c:3700-3718` is 18 lines. It builds an
`xError` struct, stamps `client->sequence`, and emits via `WriteEventsToClient`.
The `client->errorValue` is a per-client scratch slot that handlers set before
returning BadValue, so the dispatcher can include it as the `resourceID` field
on the wire.

Handler pattern (ProcCreateWindow at dispatch.c:337-378 is canonical):

```c
REQUEST_AT_LEAST_SIZE(xCreateWindowReq);   // emits BadLength
LEGAL_NEW_RESOURCE(stuff->wid, client);    // emits BadIDChoice
if (!(pParent = (WindowPtr)LookupWindow(stuff->parent, client)))
    return BadWindow;
if (Ones(stuff->mask) != len)
    return BadLength;
if (!stuff->width || !stuff->height) {
    client->errorValue = 0;
    return BadValue;
}
// ... do work ...
if (!AddResource(stuff->wid, RT_WINDOW, (pointer)pWin))
    return BadAlloc;
```

Every preflight check returns an error code; the dispatcher emits.

The size macros are in `include/dix.h:65-86`: `REQUEST_SIZE_MATCH`,
`REQUEST_AT_LEAST_SIZE`, `REQUEST_AT_LEAST_EXTRA_SIZE`, `REQUEST_FIXED_SIZE`.
All return BadLength on mismatch. Every Proc starts with one of these.

R6 connection setup: bad protocol version, bad auth, bad byte-order at setup go
through `SendConnSetup(client, reason)` which writes a SetupRefused with
`success=xFalse` and the reason string.

## xorg + XQuartz (reference/xquartz-xserver/dix/dispatch.c)

Identical model to R6. `SendErrorToClient` (dispatch.c:3797-3810) is the same
function plus designated initializers. The dispatch loop (dispatch.c:540-569)
captures both `client->majorOp` and `client->minorOp` (line 524-530, by calling
the extension's `MinorOpcode` callback when major ≥ EXTENSION_BASE), so error
replies for extension requests carry the right minor opcode automatically. Core
requests stamp minorOp=0.

XQuartz-specific divergence: I grepped `reference/xquartz-xserver/hw/xquartz/`
for error emission and found none. XQuartz's DDX layer (Quartz integration) goes
through the same `dix/` error path; allocation failures on the Mac side surface
as BadAlloc through the standard `AddResource` chain in dix. This is the
expected outcome — error semantics are defined by the protocol, not the
platform.

The xorg dispatcher also handles `result > (maxBigRequestSize << 2)` → `result =
BadLength` before dispatch (dispatch.c:539-540), so an over-length BIG-REQUESTS
request gets BadLength without the handler having to think about it.

XQuartz-noteworthy: on a Mac-side allocation failure (CGImage / NSWindow /
buffer alloc returning nil), the rendering path returns gracefully and a
BadAlloc would be the expected wire response if that propagates back to dix. In
practice the Mac allocators rarely fail and most paths just no-op.

## swift-x (Sources/SwiftXServerCore/ServerSession.swift,
Sources/Framer/ServerMessage.swift)

### Wire format

The framer's `XError.encode` (Framer/ServerMessage.swift:135-151) gets the
layout right. Both `lsbFirst` and `msbFirst` byte orders are handled by
`writeUInt16` / `writeUInt32` at lines 163-187. Sequence number is wired into
bytes 2-3, bad-resource-id into 4-7, minor opcode into 8-9, major opcode into
byte 10. Bytes 11-31 stay zero (not strictly required per spec "not guaranteed
zero" but harmless). This part is solid.

The enum `XErrorCode` (Framer/ServerMessage.swift:85-103) has all 17 core codes
mapped to their wire values. `case color = 12` is what the spec calls
`BadColormap`; `case gc = 13` is what the spec calls `BadGContext`. The names
match the framer convention but a reader cross-referencing the spec should
mentally translate.

### Emission policy (the interesting part)

ServerSession.swift:2210-2236 implements `emitError`. The function
unconditionally bumps an `errorsEmitted` counter, logs with the `[XERROR]`
prefix, and appends the encoded bytes to outbound. A `byteOrder` guard at 2223
makes pre-handshake emission a no-op (correct — pre-handshake errors must travel
through SetupRefused, not XError).

The "XError honesty policy" referenced in the comments at 2210-2216 (CLAUDE.md
Working conventions) is partially shipped. Call sites that emit errors today
(with file:line and the trigger):

| Site | Opcode | Code | Trigger |
|---|---|---|---|
| ServerSession.swift:1571 | many (via validateWindow) | BadWindow | unknown window arg |
| 1586 | many (via validateWindowOrRoot) | BadWindow | unknown window+not-root |
| 1598 | many (via validateAtom) | BadAtom | unknown atom |
| 1611 | many (via validateGC) | BadGC | unknown GC |
| 1626 | drawing ops (via validateDrawTarget) | BadDrawable | unknown drawable |
| 2132, 2136 | CopyArea | BadDrawable | unknown src/dst |
| 2146 | CopyArea | BadImplementation | cross-window or pixmap |
| 3040 | CloseFont | BadFont | unknown font |
| 3053 | QueryFont | BadFont | unknown font |
| 3064 | FreePixmap | BadPixmap | unknown pixmap |
| 3193, 3197 | CreateGlyphCursor | BadFont | unknown source/mask font |
| 3207 | FreeCursor | BadCursor | unknown cursor |
| 3314 | PutImage | BadDrawable | unknown drawable |
| 3543 | RecolorCursor | BadCursor | unknown cursor |
| 3742 | GetGeometry | BadDrawable | unknown drawable |
| 3751 | QueryBestSize | BadDrawable | unknown drawable |
| 3849 | GetAtomName | BadAtom | atom=0 or unknown |
| 3928 | dispatch fallback | BadRequest | unknown opcode |

The handler validators are wired through small typed helpers (`validateWindow`,
`validateWindowOrRoot`, `validateAtom`, `validateGC`, `validateDrawTarget`) at
ServerSession.swift:1563-1634. That's a cleaner factoring than R6's per-handler
`if (!LookupWindow(...)) return BadWindow;` boilerplate.

### What's not emitted

Every spec-listed error condition NOT in the table above is silently
faked-success today. The big-ticket gaps (with file:line evidence):

- **CreateWindow** (2416-2476): zero validation. Spec says CreateWindow can emit
  Alloc, Colormap, Cursor, IDChoice, Match, Pixmap, Value, Window — we emit
  none.
- **ConfigureWindow** (2811-2915): emits BadWindow but not BadMatch on
  stack-mode/sibling mismatch, not BadValue on enum out-of-range. Spec: Match,
  Value, Window.
- **OpenFont, CreateGC, CreatePixmap** (3029-3036, 3069-3070, 3059-3060):
  one-liners. No IDChoice, no BadDrawable, no BadAlloc.
- **AllocColor, AllocNamedColor, LookupColor** (3080-3131): no BadColor on the
  colormap argument. AllocNamedColor falls back to black on unknown name with
  explicit comment "we don't emit XErrors yet (per SHORTCUTS)" — exactly the
  ledgered-lie pattern the policy permits, with a logged message and a SHORTCUTS
  entry pointing to it.
- **ChangeProperty** (2923-2984): validates window and atoms but not the
  `format` or `mode` enum values.
- **Request decode** (2380-2408): "M1: don't synthesize XError for decode
  failures yet — for our capture corpus, decode is trusted." Live clients get a
  silent drop where xorg would emit BadLength.
- **Setup handshake** (2340-2347): bad byte-order marker returns nil silently;
  no SetupRefused emitted. The framer has the encoder ready (`SetupRefused` in
  Framer/Setup/SetupReply.swift:27-64), nobody calls it.
- **InputOnly used as drawable**: not gated. `validateDrawTarget` accepts any
  known window class.

Codes that have never been emitted from anywhere in the codebase: **BadValue,
BadMatch, BadAccess, BadAlloc, BadColor, BadIDChoice, BadName, BadLength**.

### Tests

`Tests/SwiftXServerCoreTests/XErrorEmissionTests.swift` exists and covers the
emission paths that *are* wired up: BadDrawable from CopyArea/PutImage/
PolyFillRectangle/GetGeometry/QueryBestSize, BadWindow from ClearArea/
DestroyWindow/MapWindow/GetProperty, BadGC from PolyFillRectangle/FreeGC,
BadAtom from GetAtomName, BadFont from CloseFont/QueryFont/CreateGlyphCursor,
BadPixmap from FreePixmap, BadRequest from unknown opcode. The wire format is
independently tested by `Tests/FramerTests/ServerMessageTests.swift`. So the
code paths that exist are well-tested; the problem is the missing paths.

## Surprises and divergences

**The wire format is correct but the policy is dishonest.** swift-x has a
working `emitError` and a clean validator-helper layer, but only roughly half
the spec-listed error conditions are detected. The comments in
ServerSession.swift make this explicit (`SHORTCUTS.md`, "we don't emit XErrors
yet"), which means it's deliberate tech debt rather than missed spec compliance.
The XError-honesty policy in CLAUDE.md (dated 2026-05-14, also referenced in
DECISIONS.md per the comment at 2211) is the explicit recognition that this
trade has flipped — "hidden lies now cost more debugging time than they save in
velocity."

**Resource validators are factored better than R6.** R6 inlines
`LookupWindow(...)` in every handler. swift-x's `validateWindow` /
`validateAtom` / `validateGC` / `validateDrawTarget` helpers (1563-1634)
encapsulate the "look up, emit XError on miss, return optional" pattern in one
place per resource type. When the next batch of "what should be checked" gets
written, the per-handler addition is one `guard let ... else { break }` line. R6
would have rejected this kind of factoring as too much abstraction.

**xorg's dispatcher does length-check before handler dispatch.** Line 539-540 of
xquartz-xserver/dix/dispatch.c: `if (result > (maxBigRequestSize << 2)) result =
BadLength` *before* calling the handler. swift-x's dispatcher (2380-2408) trusts
the framer's decode for length and lacks this preflight. Net: we ignore
over-length BIG-REQUESTS payloads silently where xorg emits BadLength
explicitly. Not a current problem (no BIG-REQUESTS yet), but a structural
divergence.

**Minor opcode is plumbed in the framer but never set at the call site.** Every
`emitError` call uses the default `minorOpcode: 0`. For core requests this is
correct. When extensions land, every extension request handler will need to
thread the request's minor opcode through. xorg captures `client->minorOp` in
dispatch (524-530); swift-x has no equivalent yet. File this as cosmetic for now
and load-bearing later.

**xorg emits BadAlloc on Mac-side resource failures, swift-x crashes.** Swift's
runtime semantics for allocation failure are "abort," not "return null and let
the caller decide." If `NSWindow(contentRect:...)` ever fails mid-session, we'll
crash rather than emit BadAlloc and let the client retry. The XQuartz analog
would propagate a `BadAlloc` through the standard AddResource chain. This is
partly a language-runtime mismatch — Swift optionals would let us wrap
allocators, but the Mac toolkit APIs don't really fail in normal operation.
Probably leave alone unless it bites us.

**"BadAtom on atom=0" is wrong per spec.** swift-x's GetAtomName at 3848 emits
BadAtom when `r.atom == 0`. Atom 0 is the spec sentinel `None`, which *can*
trigger BadAtom on GetAtomName specifically (since 0 is not a valid atom name to
look up — spec section "GetAtomName" lists BadAtom in Errors). So this happens
to be correct, but the reasoning at the call site ("(or atom=0 which is the spec
sentinel None)") conflates "sentinel" with "invalid for this request." It's
right by accident on GetAtomName and wrong on requests like ChangeProperty where
atom=0 in the `type` argument is a documented escape (which we do honor at line
2931-2933).

## Blog hooks

**1. "Half the BadCodes never make it onto the wire."** Concrete count: 8 of 17
core error codes are never emitted by swift-x (BadValue, BadMatch, BadAccess,
BadAlloc, BadColor, BadIDChoice, BadName, BadLength). That's a shockingly clean
stat to lead with — most readers' priors are that an X server emits every error
code somewhere. The framing: "for the first year of swift-x, eight of the 17
errors in the protocol were defined-only, never observed. Here's what changed
and why every silent-success was a debugging tax."

**2. "The encoder was ready, the call sites were missing."** Story arc: framer
has a perfect `XError.encode`, even ships the unused `minorOpcode` field. The
work in moving from "fake success" to honest XError is *entirely* at the
dispatch-handler level — validate inputs, return early with `emitError`. A clean
walk through CreateWindow's spec-listed errors, the R6 enforcement, the current
swift-x one-liner, and the diff to make it spec-honest. Easy 800-word piece with
code blocks side-by-side.

**3. "When a 'forgiving stub' becomes a bug."** The phrase from CLAUDE.md. The
forgiving-stub pattern that got M1-M3 across the line — accept the request, log,
return success — was the right call when our framer might have decoded something
wrong and we couldn't tell a real client bug from a parser bug. Once M3 closed
and live clients started connecting, the same pattern flipped from "tolerant" to
"deceitful." Real clients handle BadWindow on a race routinely (Xt's
destroy-callback chain literally has "if BadWindow, the window is already gone,
that's fine" branches). The debugging cost of "client did X, server lied about
Y, six hours later we figure out the lie was structural" is much higher than the
cost of "client saw BadWindow, retried, fine." Frame as a project-management
lesson: **ledgered exceptions need exit plans, and the exit-plan field gets
honored or the ledger becomes a graveyard**.

---

## Concrete file references

- Framer encoder: `Sources/Framer/ServerMessage.swift:85-152`
- Server emitError: `Sources/SwiftXServerCore/ServerSession.swift:2210-2236`
- Validators: `Sources/SwiftXServerCore/ServerSession.swift:1546-1634`
- Dispatch loop: `Sources/SwiftXServerCore/ServerSession.swift:2378-2408`
- Setup handler: `Sources/SwiftXServerCore/ServerSession.swift:2310-2376`
- CreateWindow handler (no validation): `:2416-2476`
- ConfigureWindow (partial validation): `:2811-2915`
- Unknown-opcode → BadRequest: `:3918-3928`
- Test coverage: `Tests/SwiftXServerCoreTests/XErrorEmissionTests.swift`
- R6 dispatch + SendErrorToClient:
  `reference/X11R6/xc/programs/Xserver/dix/dispatch.c:285-317, 3700-3718`
- R6 ProcCreateWindow (canonical pattern):
  `reference/X11R6/xc/programs/Xserver/dix/dispatch.c:337-378`
- xorg/XQuartz SendErrorToClient:
  `reference/xquartz-xserver/dix/dispatch.c:3797-3810`
- xorg dispatch (minor opcode capture):
  `reference/xquartz-xserver/dix/dispatch.c:520-569`
- xorg REQUEST_*_SIZE macros: `reference/xquartz-xserver/include/dix.h:65-86`
- Spec error format: `reference/x11-protocol-spec/x11protocol.html` "Error
  Format" section
- Spec error catalog: `reference/x11-protocol-spec/x11protocol.html` chapter 4
  "Errors"
