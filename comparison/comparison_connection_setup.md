# Connection setup + auth: spec vs X11R6 vs xorg/XQuartz vs swift-x

How each implementation handles the initial 12-byte client prefix, the
connection-info reply, byte-order, auth, and multi-client resource-id
allocation. Cut for the blog: swift-x's "build the reply in the client's byte
order from scratch" is the cleanest version of byte-swap I've seen in any X
server, and the reason it's clean is that the rest of swift-x doesn't have a
1990s-style in-place struct memory layout to preserve.

## Spec (authority)

`reference/x11-protocol-spec/x11protocol.html` chapter 8.

The client sends a 12-byte fixed header followed by two padded variable-length
strings:

```
byteOrder    : CARD8     # 0x42 'B' = MSBFirst, 0x6C 'l' = LSBFirst
pad          : 1
majorVersion : CARD16
minorVersion : CARD16
nameLen      : CARD16    # bytes of authorization-protocol-name
dataLen      : CARD16    # bytes of authorization-protocol-data
pad          : 2
name         : STRING8 + pad
data         : STRING8 + pad
```

All 16/32-bit fields from this header onward (in both directions) are
interpreted under the byte order the client picked in that first byte. The spec
is emphatic: "Except where explicitly noted in the protocol, all 16-bit and
32-bit quantities sent by the client must be transmitted with this byte order,
and all 16-bit and 32-bit quantities returned by the server will be transmitted
with this byte order." (lines 968–972). The two exceptions are PutImage/GetImage
data, which always go in the server's `image-byte-order`, and bitmap-bit-order,
which is fixed by the server.

The server responds with one of three reply variants, distinguished by the first
byte:

- `0 = Failed`  followed by `majorVersion / minorVersion / reason: STRING8`
- `1 = Success` followed by the big connection-info block (vendor,
  release-number, resource-id-base/mask, motion-buffer-size, max-request-length,
  image-byte-order, bitmap formats, list of FORMAT, list of
  SCREEN-with-DEPTH-with-VISUAL)
- `2 = Authenticate` followed by `reason: STRING8` (and further negotiation, the
  contents of which are auth-protocol-specific)

Auth specifics are **explicitly out of the core protocol**: "Specification of
valid authorization mechanisms is not part of the core X protocol. A server that
does not implement the protocol the client expects or that only implements the
host-based mechanism may simply ignore this information." (lines 992–996). The
spec describes the field encoding only — what to do with the bytes is the
implementation's call.

Resource-id rules from §8.4: mask must have "a single contiguous set of bits (at
least 18)"; resource IDs never have the top three bits set; clients OR a
mask-subset value with the base to form an ID.

`maximum-request-length` is in 4-byte units, so spec-max is `65535 * 4 = 262140`
bytes per request. BIG-REQUESTS extends this to 32-bit length-in-4 but is a
separate extension.

`min-installed-maps` and `max-installed-maps` are hardware-colormap arbitration
knobs — meaningful on slot-limited PseudoColor hardware, vestigial on TrueColor.

## X11R6 (`reference/X11R6/xc/programs/Xserver/`)

The reference implementation. Three files matter here.

### `os/connection.c:EstablishNewConnections` (line 636)

The accept loop. Called from the main `Dispatch` loop when one of the listening
sockets is readable. Calls `_XSERVTransAccept`, allocates an `OsCommRec`
(per-client OS state), wires it into the `clients[]` array via
`NextAvailableClient`, sets `BITSET(AllClients, newconn)` so the next select()
includes the new fd.

Important detail: on accept the server doesn't yet read the 12-byte prefix. It
seeds the new client with a fake `xReq` whose `reqType=1` and length covers the
connection prefix (`NextAvailableClient`, line 3536–3538). The first thing the
client sends — its prefix — is then consumed by `ProcInitialConnection` (the
dispatcher routes opcode 1 to it because `client->requestVector = InitialVector`
at this point, line 3456).

This indirection lets R6 reuse its normal dispatch infrastructure for connection
setup. swift-x doesn't bother with this trick and runs a dedicated `Phase` state
machine in the session — cleaner for Swift, but the R6 approach is what made it
possible to bolt on Kerberos as just-another-request-handler.

### `dix/dispatch.c:ProcInitialConnection` (line 3553)

Consumes the prefix. Three things happen:

1. Validate byte-order byte (0x42 or 0x6C). On garbage, sets
   `client->noClientException = -1`, which the dispatch loop reads on the next
   iteration and closes the connection.
2. Compare the byte-order byte against the server's own byte-order (`whichbyte =
   1` trick at line 3559–3565). If they differ, set `client->swapped = TRUE` and
   `SwapConnClientPrefix(prefix)`. This is the only place the SWAP decision is
   taken.
3. Re-stamp the request's `reqType` from 1 to 2 and bump its length to cover the
   now-buffered auth proto and string. This makes the dispatcher route the very
   same buffer through `ProcEstablishConnection` on the next pass.

### `dix/dispatch.c:ProcEstablishConnection` + `SendConnSetup` (lines 3667 and 3589)

`ProcEstablishConnection` calls `ClientAuthorized` (in `os/connection.c:444`),
which calls `CheckAuthorization` in `os/auth.c:181`. The auth table
(`os/auth.c:88`) is statically compiled:

```
MIT-MAGIC-COOKIE-1  -> mitauth.c
XDM-AUTHORIZATION-1 -> xdmauth.c     (if HASXDMAUTH)
SUN-DES-1           -> rpcauth.c     (if SECURE_RPC)
MIT-KERBEROS-5      -> k5auth.c      (if K5AUTH)
```

`CheckAuthorization` matches the auth name against the table; missing match
returns `(XID)~0L` (rejection), which `ClientAuthorized` cross-checks against
the host-based access list (`InvalidHost` in `os/access.c:1071`). The Sun-era
default for `xhost +` was a security hole that everybody used anyway.

`SendConnSetup` writes the reply. The clever part: the static `ConnectionInfo`
block is built once at server start by `CreateConnectionBlock`
(`dix/main.c:367`) in **server-native byte order**, and held in
`ConnectionInfo`. On every accept it gets patched in place (rid base/mask,
current input mask) and written. For a swapped client, R6 does NOT byte-swap in
place — instead it dispatches through `WriteSConnSetupPrefix` /
`WriteSConnectionInfo` which **copy** the block into a per-client temp buffer
with swapping along the way (`dix/swaprep.c:SwapConnSetupInfo`, line 1088, in
the xorg tree which inherited this verbatim from R6).

After this point, every subsequent request the client sends gets routed through
`SwappedProcVector` instead of `ProcVector` (line 3625). The swap table is
`dix/swapreq.c`; every request that has multi-byte fields has a `SProcFoo` shim
that byte-swaps in place before calling `ProcFoo`. Every reply that has
multi-byte fields is written through a `WriteSwappedReply` path. swift-x's
approach is qualitatively different — see below.

### `os/connection.c:CloseDownFileDescriptor` + `dix/dispatch.c:CloseDownClient`

On disconnect: free the OsCommRec, clear all the bitmask bookkeeping, then
`dix/dixutils.c:CloseDownClient` (called from elsewhere) walks the client's
resource trees per resource type and frees each. The close-down mode (`Destroy`,
`RetainPermanent`, `RetainTemporary` per `SetCloseDownMode`) decides whether
resources die or persist as orphans owned by `clientGone`. The save-set is
reparented to root.

## xorg / XQuartz (`reference/xquartz-xserver/`)

Inherits 95% of the above from R6 verbatim. Important deltas:

### Launchd socket (XQuartz-specific)

`hw/xquartz/mach-startup/launchd_fd.c:launchd_display_fd` is called from xquartz
startup. It does a `launch_data_new_string(LAUNCH_KEY_CHECKIN)` to ask launchd
"what sockets did you reserve for me," extracts the pre-bound listen fd, and
hands it to `os/connection.c:ListenOnOpenFD` (line 992). That function then does
`_XSERVTransReopenCOTSServer` to wrap the launchd-provided fd in the xtrans
transport machinery, and tags it with `TRANS_NOXAUTH` (line 1036/1069). When
that listener's accept fires, `_XSERVTransAccept` copies the flag to the
per-connection `trans_conn->flags` (`os/connection.c:689–690`).

`os/connection.c:ClientAuthorized` (line 510) checks `trans_conn->flags &
TRANS_NOXAUTH` *before* calling `CheckAuthorization`. If set, auth succeeds
without any cookie check (line 527: "Allow any client to connect without
authorization on a launchd socket, because it is securely created — this
prevents a race condition on launch"). The "securely created" part is launchd's
job: it bound the socket with proper permissions on Mac filesystem
(`/private/tmp/com.apple.launchd.XXXX/`), so only the right uid can connect.

This is the same trust pattern X always used over Unix sockets but with launchd
as the verifier, dodging the "where did the Xauthority cookie go?"
Mac-multi-user mess.

### Connection-info struct swap

`dix/swaprep.c:1036–1085` — same code path as R6, function names unchanged,
broken out into `SwapConnSetup` / `SwapWinRoot` / `SwapVisual` /
`SwapConnSetupInfo` / `SwapConnSetupPrefix`. All `cpswapl` / `cpswaps`
(byte-reverse a 4 / 2-byte field across two pointers). Reads from `pInfo`,
writes to `pInfoT` (per-client temp).

### Auth tables

Same `os/auth.c` shape, same conditional protocols. MIT-MAGIC-COOKIE-1 is the
default; everything else needs build-time flags. The reset-on-server-reset
behavior (`MitResetCookie`) regenerates a fresh cookie every server restart,
which is why XQuartz writes `~/.Xauthority` on launch and clients sourced before
launch see stale cookies.

## swift-x (`Sources/`)

### Where the bytes are read

`Sources/SwiftXServerCore/Listener.swift:runAccepting` (line 101) is what
`Sources/SwiftXServer/main.swift:134` actually calls in production. `runOne`
(line 65) is for tests.

`runAccepting` loops on `accept()`, then for each new fd:
1. Calls `makeSession`, which calls `coordinator.allocateClientResourceIdBase`
   and stamps the resulting base/mask into a fresh `ServerConfig` for this
   session.
2. Builds a `ServerSession` against that config, sharing the same `coordinator`
   (atoms + selection state are server-global, per spec).
3. Calls `runConnection`, which installs a `DispatchSourceRead` on the fd
   targeting the session's `protocolQueue`.

The `protocolQueue` is a per-session serial dispatch queue. Every read event,
every AppKit-side callback (key, mouse, focus), and every reply emission runs on
this queue — no locks inside the session. This is the swift-x answer to R6's
single-threaded `Dispatch()` loop, scaled per client.

### The Phase state machine

`Sources/SwiftXServerCore/ServerSession.swift:14`:

```swift
private enum Phase {
    case awaitingSetup
    case running(byteOrder: ByteOrder)
}
```

`feed(_ bytes:)` (line 2317) appends bytes to `inbound` and loops: while there's
enough to decode, decode and consume. `trySetup` (line 2335) handles the
connection prefix; `tryRequest` (line 2380) handles every other request.

`trySetup` is 40 lines:
1. Peek byte 0, decide byte order (or return `nil` and stall — see R3 in the
   risk register).
2. Peek bytes 6–9 for `authNameLen` and `authDataLen` under that byte order,
   compute total size, return `nil` if not enough bytes yet.
3. Call `SetupRequest.decode` on the slice
   (`Sources/Framer/Setup/SetupRequest.swift:38`). This returns a `SetupRequest`
   containing the auth fields — which the server immediately discards (`_ = try
   ...`). Protocol version isn't checked.
4. Build `SetupAccepted` from `ServerConfig.makeSetupAccepted()`
   (`ServerConfig.swift:97`).
5. Call `SetupReply.accepted(accepted).encode(byteOrder: order)` — this is where
   the magic happens — and queue the bytes for output.
6. Transition to `.running(byteOrder: order)`.

### The byte-order swap, swift-x edition

Here's the bit worth a blog post.

R6 and xorg both keep the connection-info block in a server-native struct
(`xConnSetup`, `xWindowRoot`, etc., from `Xproto.h`) and either pass-through or
run a memcpy-with-swap as needed. The setup reply has nine multi-byte fields in
the prefix alone, plus ~10 per SCREEN, plus 7 per VISUAL. The R6 / xorg code is
two hundred lines of `cpswapl(src->field, dest->field)` boilerplate. swift-x
does not have that.

The framer's `SetupAccepted.encode(byteOrder:)`
(`Sources/Framer/Setup/SetupAccepted.swift:65`) builds the reply bytes from
scratch, using a `ByteWriter` that's been initialized with the target byte
order. Every `writeUInt16` / `writeUInt32` consults the writer's byte-order
field and emits bytes in the right order. The 200 lines of in-place swap helpers
in xorg become a single parameter passed once into `encode`. Same for every
reply, error, and event in the framer — they all encode under the byte order
they were given.

That parameter then threads through `tryRequest`, which decodes each request
body under the client's byte order (`Request.decode(from:byteOrder:)` at
`Sources/Framer/Requests/Request.swift:163`). `ByteReader`
(`Sources/Framer/Wire/ByteReader.swift`) does the inverse: every multi-byte read
consults its byte-order field. Result: there is no concept of "swapped client"
in swift-x's dispatch logic. There's no `SwappedProcVector`. Every handler
receives values in host-Swift-native CPU-correct order regardless of what the
client sent.

Why does this work for swift-x and not for xorg? Because xorg's request handlers
cast the request buffer directly to a `xCreateWindowReq*` struct pointer and
read fields off it. For that to give correct values on a swapped client, the
buffer must be swapped in place first. swift-x decodes once into a Swift
`struct` whose fields are already CPU-native scalars; the decode function does
the byte order work, and downstream handlers can't even see the raw bytes.
Different memory model, much smaller swap surface.

Big-endian Sun (`.msbFirst`) → little-endian Mac (`.lsbFirst`) is therefore not
even a code path. It's just "the byte order this session uses is `.msbFirst`"
carried as one value through the session lifetime. There's no
swapped/non-swapped fork.

### Multi-client coordinator

`Sources/SwiftXServerCore/ServerCoordinator.swift` holds three things:
- `atoms: AtomTable` — shared atom IDs across clients (xterm interns WM_CLASS
  first, gets 69; xcalc later gets the same 69).
- `selectionOwners: [UInt32: SelectionState]` — selection ownership is
  server-global per spec; lock-protected.
- `nextClientNumber: UInt32` — counter for resource-id base allocation. See R4 —
  this never recycles on disconnect.

`allocateClientResourceIdBase` (line 45) computes `templateBase + (n-1) *
(mask+1)`. With the defaults `base = 0x04400000` and `mask = 0x001FFFFF`, the
stride is `0x00200000`. Client 1 uses `0x04400000–0x045FFFFF`, client 2
`0x04600000–0x047FFFFF`, etc. Plenty of room for the typical CDE workload of 4-6
simultaneous clients.

### Connection teardown

`Listener.runConnection`'s `setCancelHandler` (line 213) fires on EOF / read
error and calls `session.cleanupOnDisconnect` (line 222), then
`Darwin.close(clientFd)`. `cleanupOnDisconnect` (`ServerSession.swift:2246`)
snapshots top-level window IDs (children of root) and asks the bridge to destroy
each NSWindow. The X-windows table is cleared.

Spec close-down: default mode is `Destroy`, which swift-x always implements;
`RetainPermanent` and `RetainTemporary` are not handled (`SetCloseDownMode`
opcode 112 isn't implemented — see R2). For Todd's use case this only matters if
a session-manager wants permanent stub-clients.

### What's missing relative to spec

A grep of the full source tree gives the empty set for:
- `MIT-MAGIC-COOKIE` — no auth check
- `SetCloseDownMode` — opcode 112 not decoded (only named in
  `OpcodeNames.swift:114`)
- `KillClient` — opcode 113 not decoded (only named)
- `NoOperation` — opcode 127 not decoded (only named)
- `ChangeHosts` / `ListHosts` / `SetAccessControl` — opcodes 109–111 not decoded
  (only named)
- `BIG-REQUESTS` — never advertised in `QueryExtension`

All of these end up in `Request.unknown` and per the post-2026-05-14 honesty
policy emit `BadRequest`. NoOperation getting BadRequest is the most
user-visible — Xt clients sprinkle `XNoOp` calls during connection probes.

### Single-client warning in CLAUDE.md is out of date

CLAUDE.md auto-load says "single-client only" but the code already supports
multi-client end-to-end via `runAccepting`. The remaining single-client residue
is in the test suite (`runOne` is the only path exercised by tests). When two
clients are running, the bridge fans every AppKit event to every registered
session-handler, and each session filters by "do I own this window?" That's
working today for CDE; the gap is test coverage (see R6).

## Surprises and divergences

1. **xorg keeps the connection-info block in server-native byte order and swaps
   on write per client.** swift-x builds it in client byte order on every accept
   from scratch. Both correct; swift-x's is 10× less code and avoids a class of
   cast-related bugs that xorg has plenty of historical CVEs around.

2. **R6 routes connection setup through the same dispatch table as every other
   request**, by faking a `reqType=1` request on accept. swift-x has a discrete
   two-state Phase enum that the read loop consults. The R6 version is clever
   and uniform; the swift-x version is half the code and easier to reason about.

3. **XQuartz delegates auth to filesystem permissions on the launchd-bound
   socket.** It still implements MIT-MAGIC-COOKIE-1 for non-launchd cases (e.g.
   when XQuartz is being run as someone's pure xorg-on-Mac through `Xquartz
   :0`), but in practice everyone goes through launchd and `TRANS_NOXAUTH`
   short-circuits the check. swift-x has the option to do the same — bind a
   socket somewhere only-Todd can read — but currently binds 0.0.0.0:6000 with
   no auth at all, which is reasonable for LAN-Sun-only usage and dangerous for
   the "GitHub-publish" success criterion.

4. **swift-x's resource-id allocator never reclaims IDs from disconnected
   clients** (R4). xorg / R6's `clients[]` array has a `nextFreeClientID`
   counter that scans the array for holes (`dix/dispatch.c:NextAvailableClient`,
   line 3516). swift-x's coordinator monotonically increments. CDE login churn
   over a long session will eventually exhaust ranges.

5. **swift-x is missing both `KillClient` and `NoOperation`.** R6 has both.
   `NoOperation` is the more surprising omission because it's how Xlib pads sync
   points. The fix is trivial (no-op handler that decodes the length and
   discards) but it's not there.

6. **`SetupRefused` and `SetupAuthenticate` reply variants exist in the framer
   but are never produced by the server.** Their encode/decode is tested by
   `SetupReplyTests.swift` round-trips only. The implication: if we ever do want
   to refuse a connection, the framer is ready, but we don't yet exercise the
   "close the socket cleanly after writing Failed" code path.

## Blog hooks

1. **"Two ways to byte-swap an X server."** Walk through how xorg keeps the
   connection-info struct in native byte order and runs a 200-line family of
   `Swap*` functions on write, versus swift-x's "build the bytes in the client's
   byte order from scratch" via a parametric `ByteWriter`. Use the actual R6
   `SwapConnSetupInfo` (`dix/swaprep.c:1088`) next to swift-x's
   `SetupAccepted.encode` (`Setup/SetupAccepted.swift:65`). Punch line: the
   elegance comes from Swift's value-type framer eating the same parameter at
   decode time, so no handler in the server has to know what byte order the
   client picked. The whole "swap a struct" surface area xorg accrued over 30
   years just doesn't exist.

2. **"Launchd as auth provider."** XQuartz's `TRANS_NOXAUTH` trick: instead of
   negotiating MIT-MAGIC-COOKIE, lean on the OS to bind a socket only the right
   uid can connect to. Show the launchd plist that reserves the socket, the
   `launch_data_get_fd` call that fetches it, the `os/connection.c` line that
   flags the connection no-auth, and the line in `ClientAuthorized` that
   short-circuits on the flag. Contrast with our 0.0.0.0:6000 default and why
   that's fine on a private LAN with vintage Suns but not fine for a published
   binary.

3. **"What happens when a Sun talks to a Mac."** The big-endian Sun sends `0x42`
   as its byte-order byte. The Mac swift-x server stamps `.msbFirst` on the
   session and from that moment on every UInt16/UInt32 in either direction goes
   through code that reads/writes in MSB-first regardless of the Mac's native
   byte order. Compare to the days of `htonl`-everywhere C code: in Swift, the
   wire encoder is a single ~30-line struct (`ByteWriter`) that takes byte order
   as a constructor parameter and does the right thing without any caller-side
   intervention. Use the wire trace of a real `xterm -display mac:0` against a
   real SS2 to show the bytes flowing.
