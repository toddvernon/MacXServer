# Risk register: connection setup + auth

Three buckets by severity: actively bleeding now, will bleed when X happens, and
theoretical / spec-only. Each entry names the issue, severity, what's missing,
what triggers it, and the rough shape of a fix. Read with
`comparison_connection_setup.md` open if you want the file/line provenance.

## Actively bleeding now

### R1. Stale handler list on bridge accumulates dead-session closures
**Severity:** medium. Slow leak, behaviourally subtle.

`CocoaWindowBridge` stores AppKit-event handlers as ten growing `[@Sendable …]`
lists (`resizeHandlers`, `keyHandlers`, etc.). Each `ServerSession.init` appends
ten closures via `setOnKey` / `setOnMouse` / …. Nothing ever removes them.
Disconnect path (`Listener.runConnection`'s cancel handler →
`ServerSession.cleanupOnDisconnect`) clears top-levels from the windows table
but does not call back into the bridge to drop handlers, and the closures retain
`self` (the session). Net effect: after N accepts the bridge dispatches every
event N times; N−1 of those dispatches no-op because the session's windows table
is empty after teardown, but the session object stays alive forever via the
bridge's retain. Triggers on the second-or-later disconnect — i.e. routine "user
closes xterm, opens another."

**Fix shape:** session registration returns a token (or the session keeps its
own handler IDs); `cleanupOnDisconnect` unregisters via
`bridge.unregister(handlers)`. Make the handler storage a `[UInt: closure]`
keyed by session id, not a `[closure]`.

### R2. `KillClient`, `SetCloseDownMode`, `NoOperation` all return BadRequest
**Severity:** medium for `NoOperation` (XSync polling), high for any future WM
scenario that wants to kick stuck clients.

`Sources/Framer/OpcodeNames.swift:115/122/114` names them but
`Sources/Framer/Requests/Request.swift` has no decode case, so `Request.decode`
returns `.unknown(op, bytes)`. `ServerSession.dispatch` then calls
`emitError(.request, majorOpcode: op)` (line 3928). `NoOperation` (127) is what
`XSync` and most app inits trail with; getting `BadRequest` on every `NoOp`
causes Xt-based clients to log loud warnings on stderr. `SetCloseDownMode`
matters when a session manager wants `RetainPermanent` for stub-clients — CDE's
dtsession does this; missing it means closing dtsession also destroys all its
child windows. `KillClient` matters for any WM that wants to forcibly close a
hung client (`xkill`). Trigger: any client built with libXt that calls `XNoOp()`
during connection-validity probes.

**Fix shape:** add three trivial decodes to `Request.swift`, dispatch
`NoOperation` to a no-op handler, `SetCloseDownMode` to a stub that records the
mode but always honors DestroyAll (already in `SHORTCUTS.md` policy),
`KillClient` to lookup the resource-owning session and call its disconnect path
through the coordinator. Coordinator currently has no session registry — see R4.

### R3. Garbled byte-order byte silently hangs the client
**Severity:** low (real Suns send valid bytes), but a debugging-time-waster.

`ServerSession.trySetup` (line 2341–2347) returns `nil` on any byte that isn't
`0x42` or `0x6C`, which doesn't release the bytes from `inbound` and doesn't
write any response. The TCP read source keeps spinning; the client blocks on
`read()` of the connection-info reply forever. Real X11 servers
(`xc/programs/Xserver/dix/dispatch.c:3562` in R6, `os/connection.c:ErrorConnMax`
style in xorg) write a `Failed` reply with reason "Invalid byte-order" then
close the fd. Triggers if anything sits between client and server that corrupts
the first byte (e.g. an HTTP probe to port 6000), or if a client really does
send garbage.

**Fix shape:** emit `SetupReply.refused(SetupRefused(major: 11, minor: 0,
reason: "Invalid byte-order byte: 0x...".bytes))` in the framer (already
implemented!) and close the fd. About 8 lines.

### R4. Resource-ID base allocation has no coordinator-side bookkeeping
**Severity:** medium.

`ServerCoordinator.allocateClientResourceIdBase` (line 45) bumps a counter and
computes `templateBase + (n−1) * (mask+1)`, so client 1 gets `0x04400000`,
client 2 gets `0x04600000`, client 3 gets `0x04800000`, etc. The counter never
decrements on disconnect — after 256 accept/close cycles (which happens fast in
a CDE login since dt-apps churn) the next base overflows into ranges that
overlap predefined-atom space. Nothing crashes immediately, but if the
wrap-around base happens to OR with mask values a client picks, it can collide
with the rootWindowId 0x28 or the defaultColormapId 0x21 ServerConfig hardcodes.
Spec (`x11protocol.html#resource-id-mask`) requires 18+ contiguous bits in the
mask and that "Resource IDs never have the top three bits set" — our 21-bit mask
+ stride strategy fits, but only because we don't recycle dead client IDs.

**Fix shape:** maintain a free-list of base values in the coordinator; on
`cleanupOnDisconnect`, push the session's base back. Plus a guard that the next
base never goes past `0x1FFF_FFFF`.

### R5. Auth name + data are read off the wire and discarded
**Severity:** low for the use case Todd has (LAN, Suns, no auth in practice),
high for the "publish on GitHub" success criterion.

`ServerSession.trySetup:2363` decodes `SetupRequest` (which parses the auth
fields) but doesn't even pass it back — the `_ = try …` throws away the result.
The server ALWAYS accepts. Anyone on the LAN can connect, claim any X-id range,
and start mapping windows. Triggers: someone else on Todd's LAN runs `xterm
-display todd-mac:0`. Aggravated by `--host 0.0.0.0` being the default in
`main.swift:49`.

**Fix shape:** at minimum, default-bind to `127.0.0.1` and require `--host
0.0.0.0` to be explicit. Real fix: implement `MIT-MAGIC-COOKIE-1` (the auth file
living in `~/.Xauthority` is already what Xlib clients consult; we just need to
check it server-side). The framer's `SetupAuthenticate` reply type exists but is
unused.

## Will bleed when X happens

### R6. Multi-client integration test does not exist
**Severity:** medium when CDE testing returns; currently parked.

`Tests/SwiftXServerCoreTests/` has one selection-conversion test that touches
the coordinator, but no test runs `runAccepting` with two simulated client
sockets. The first time we'll learn the multi-client path actually works in CI
is when something breaks it. Listener has `runOne` for tests, no equivalent
`runTwo`. CDE dt-apps already exercise this — dtsession spawns dtwm + dtcalc +
dthelpview + … = 4-6 simultaneous clients — but those are only validated by eye
against running u5.

**Trigger:** anyone refactoring `ServerCoordinator` or the bridge handler-list
logic. Tests don't catch a regression.

**Fix shape:** add a `runAccepting` integration test that opens two TCP
connections to the same listener, drives both through setup, has each create a
window, asserts non-overlapping resource-id ranges and that mouse events on
window-A only fire session-A's handler. About 60 lines.

### R7. Bad `maximum-request-length` for any non-trivial PutImage
**Severity:** low. Won't bleed for xterm/xcalc; will bleed for any client doing
image transfers.

We advertise `65535` (4-byte units), which means 262140 bytes max per request. A
typical 100×100×4-byte PutImage of a CDE icon is fine; a 1024×768 background
pixmap is 3 MB and requires BIG-REQUESTS. We don't advertise BIG-REQUESTS, so
any well-behaved client will chop into 256K chunks (fine). A misbehaving client
(or one assuming BIG-REQUESTS-is-always-there) will get truncated requests that
we then try to decode, fail, and silently log via `tryRequest`'s decode-error
path (line 2402–2406) — the per-CLAUDE.md "M1 trusted decode" comment.

**Trigger:** any GTK1/Motif app that uses XPutImage on a large pixmap. Likely
Motif "dthelpview" with its image-rich help pages.

**Fix shape:** enable BIG-REQUESTS (separate fork covers the extension; this
fork just records the dependency).

### R8. Single static `currentInputMasks: 0` in setup reply
**Severity:** low.

`ServerConfig.swift:114` hardcodes the root's `currentInputMasks` to 0 in the
connection-info reply. The spec (8.4) says this is "what `GetWindowAttributes`
would return for the all-event-masks for the root." A WM that reads the
setup-reply root mask to decide if it's the only WM on the display will get 0
and think it's clear-coast — which we are right now (we don't run a WM), but if
a real WM ever connects via this server, two WMs both seeing 0 would both call
`ChangeWindowAttributes(root, SubstructureRedirect)` and one would get
BadAccess. Honest, but the WM that lost the race might handle that poorly.

**Trigger:** running twm or fvwm through swift-x while a CDE login already has
dtwm connected.

**Fix shape:** fill `currentInputMasks` from the `rootEventMask` field on the
session that's about to be sent the reply. Trivial.

### R9. Connection teardown does not flush outstanding outbound bytes
**Severity:** low.

`Listener.runConnection`'s cancel handler calls `session.cleanupOnDisconnect`
then `Darwin.close(clientFd)`. `cleanupOnDisconnect` calls
`bridge.destroyTopLevel` which posts `DestroyNotify` events into `outbound`, but
nothing then drains `outbound` to the wire before the fd closes. The client
never sees its own DestroyNotify events. Doesn't matter on disconnect (client is
gone), but bothers any "before-I-die" diagnostic capture.

**Trigger:** packet captures across disconnect look wrong; doesn't affect live
behaviour.

**Fix shape:** `flushOutbound()` before `Darwin.close(clientFd)` in
`Listener.runConnection:222–223`.

## Theoretical / spec-only

### R10. We never refuse a protocol-version mismatch
**Severity:** spec-purist.

`trySetup` (2335) never inspects `protocolMajor` / `protocolMinor`. Spec 8.1
("Server Information") says the server "can (but need not) refuse connections
from clients that offer a different version than the server supports" — i.e.
we're spec-compliant by virtue of the "need not." But we don't even log when a
client sent something other than 11.0, which would be useful breadcrumbs in a
SHARP debug session. xorg's `dispatch.c:3678` does the comparison and refuses
with "Protocol version mismatch."

**Trigger:** none in the wild; X11R5 and R6 both send 11.0.

**Fix shape:** log only; refusing is optional.

### R11. `motion-buffer-size` is reported as 256 but no motion-buffer exists
**Severity:** spec-purist.

`ServerConfig.swift:136` advertises 256 motion-history entries.
`GetMotionEvents` (opcode 39) is not implemented (will get `.unknown` →
`BadRequest`). The setup-reply value is supposed to be "approximate maximum";
advertising 256 and serving 0 is misleading but spec-tolerated by the
"approximate" weasel-word.

**Trigger:** clients that read `XDisplayMotionBufferSize(dpy)` and decide to
call `XGetMotionEvents` based on > 0.

**Fix shape:** advertise 0 OR implement a ring buffer of motion events on
`MotionNotify` synthesis. Tight ringbuffer ≈ 40 lines.

### R12. PixmapFormat list has one entry; we claim depth-1 pixmaps without a format
**Severity:** spec-correctness.

`ServerConfig.swift:128` only emits one `PixmapFormat`: depth=8 / bitsPerPixel=8
/ scanlinePad=32. Spec 8.4 ("Server Information"): "Pixmap-formats contains one
entry for each depth value. […] An entry for a depth is included if any screen
supports that depth, and all screens supporting that depth must support only
that Z format for that depth." Spec also says "A pixmap depth of one is always
supported and listed." We omit it. Clients that try `XCreatePixmap(dpy, root, w,
h, 1)` for a stipple-bitmap will (correctly) get BadValue from xlib BEFORE the
wire request lands — xlib filters based on pixmap-formats and the depth-1 pixmap
isn't listed.

**Trigger:** any Motif app that creates a stipple bitmap (most do, for shadow
rendering — which is why dt-apps don't render PushButton chrome, per
`INVESTIGATION_MOTIF_INPUT.md`).

**Fix shape:** add `PixmapFormat(depth: 1, bitsPerPixel: 1, scanlinePad: 32)` to
the formats list. Note: actually rendering depth-1 pixmaps is a separate fork's
problem; advertising them is just bytes in the setup reply.

### R13. `min-installed-maps` / `max-installed-maps` both = 1
**Severity:** none in practice.

R6/xorg use this for hardware-colormap arbitration on slot-limited DDX. We have
one PseudoColor visual and effectively a fake colormap, so `(1,1)` is correct.

### R14. `Failed` setup-reply path completely untested
**Severity:** test-purist.

`SetupReply.refused` and `SetupReply.authenticate` round-trip through the framer
(covered in `SetupReplyTests.swift`) but neither is ever produced by the server.
The encode-path is therefore validated only by unit tests, not by anything that
runs end-to-end.

**Trigger:** the day we implement R3 or R5 properly, we'll find out if the
encode is right.

**Fix shape:** roll into R3.
