# Risk register: SHM / transport / large requests

Scope: listening sockets, MIT-SHM, BIG-REQUESTS, write buffering, read
fragmentation, accept lifecycle.

Authority order: spec > X11R6 > xorg+XQuartz > swift-x. swift-x source is at
`Sources/SwiftXServerCore/{Listener.swift, ServerSession.swift,
ServerConfig.swift, OutboundQueue.swift}`.

---

## Actively bleeding now

### B1. A single slow / wedged client stalls all output (blocking writes, no select-for-write)

`Sources/SwiftXServerCore/Listener.swift:244` `writeAllToSocket` calls
`Darwin.write` on a socket that nobody set `O_NONBLOCK` on (no `fcntl` or
`F_SETFL` anywhere under `Sources/` — grep returns nothing). It loops while
`written < bytes.count` and bails silently on `w <= 0`. With a blocking socket,
if the client TCP receive buffer fills up (slow client, network hiccup, debugger
pause), `write` blocks. Because `writeAllToSocket` is called on the session's
`protocolQueue` — the same queue that owns the read source's event handler — a
stalled write freezes that session's *reads* too, including any pending
AppKit-side callbacks that hop onto `protocolQueue` (mouse, key, focus, resize:
ServerSession.swift:237-306). In a multi-client server this is per-session, so
other sessions still run, but the misbehaving session looks dead and the user's
window goes unresponsive.

xorg solves this in `os/io.c:FlushClient`
(`reference/xquartz-xserver/os/io.c:825`): writev with iovec, `ETEST(errno)`
detects `EAGAIN`, the unsent tail gets memmoved into the per-client output
buffer (`oco->buf`, growable to `INT_MAX`), the client's fd gets added to
`ClientsWriteBlocked`, and the main `select` loop watches for write-readiness
before retrying. swift-x has none of that: no output buffer the wire layer owns
(`OutboundQueue` only collects bytes the dispatch handler produces before the
single `flushOutbound` at the end of the handler — line 2266-2272), no
write-readiness wait, no notion of a write-blocked client.

- Severity: high (it's the kind of bug that doesn't show up until network
  conditions are bad, then the server looks "frozen").
- Missing: nonblocking writes, per-session output backlog buffer,
  write-readiness wakeup.
- Trigger: any client that doesn't read promptly. xterm running pages of fast
  output where the user has the terminal scrolled back. SSH-tunneled connection
  where the tunnel buffers. A debugger paused on the client.
- Fix-shape: set `O_NONBLOCK` on the accepted fd; on partial write, move the
  tail to a session-owned backlog `[UInt8]`; register a
  `DispatchSource.makeWriteSource` keyed to `clientFd` on `protocolQueue` that
  drains the backlog when the kernel signals writable; clear it on drain.

### B2. No XError on oversize request — bogus length silently drops the connection

`Sources/SwiftXServerCore/ServerSession.swift:2380` `tryRequest`: reads the
16-bit `length` field, multiplies by 4 to get `totalSize`. There's no
upper-bound check against the advertised `maximumRequestLength = 65535`
(`ServerConfig.swift:137`) or anything else. If the value is small-but-bogus (<
4) we just `return nil` and the connection idles forever ("bogus length —
closing" is logged but `feed` actually returns `outbound.drain()` and the read
source keeps running). If it's huge-but-legal-looking (length=65535, totalSize =
262140 bytes) we'll just wait for that many bytes to arrive before even
attempting to decode. The spec is clear: a request that exceeds
`maximum-request-length` should produce `BadLength`. R6 enforces in
`os/io.c:280-287` (`if (needed > MAXBUFSIZE) YieldControlDeath(); return -1;`).
xorg same idea at `os/io.c:227+`.

- Severity: medium (denial of service / silent hang, not corruption).
- Missing: explicit length-check against the advertised limit, `BadLength`
  emission.
- Trigger: a buggy client sends a request with length=0, or a malicious client
  sends 65535 with no follow-up bytes. Not in the wild for Sun clients but
  trivial for a fuzzer.
- Fix-shape: in `tryRequest`, if `lenIn4 == 0 || lenIn4 >
  config.maxRequestLength` emit BadLength via `emitError` and abandon the
  connection (or skip the bogus request — spec lets us close).

### B3. Read loop assumes one `read()` returns one full chunk; partial requests work but oversized chunks don't bound the in-buffer

`Sources/SwiftXServerCore/Listener.swift:192` allocates a fixed 65536-byte stack
buffer per `read()`. That's fine — partial requests accumulate in
`ServerSession.inbound` (line 2318). The actual problem isn't read fragmentation
(that works), it's the absence of any cap on `inbound.count`. If a client sends
a header claiming length=65535 (262140 bytes) and then trickles bytes, `inbound`
grows unbounded across reads. R6 caps the input buffer at `MAXBUFSIZE` (which is
`MAX_REQUEST_SIZE * 4 + 8` ≈ 256KB pre-BIG-REQUESTS; xorg `include/os.h:70-73`).
swift-x has no cap and no shrink — `inbound.removeFirst(consumed)` on every
successful parse, but a stalled half-request just sits.

- Severity: low-medium (resource consumption per session, no crash).
- Missing: input-buffer ceiling, shrink-after-large.
- Trigger: malicious or buggy client.
- Fix-shape: bound `inbound.count` at `4 * config.maxRequestLength + slop`; emit
  BadLength + close if exceeded.

---

## Will bleed when X happens

### W1. No Unix-domain socket → no DISPLAY=:0 from local clients, no XQuartz-compat behavior

`Sources/SwiftXServerCore/Listener.swift:258` opens an `AF_INET` socket only.
There is no `AF_UNIX` listener and no `/tmp/.X11-unix/X0` socket creation (grep
for `AF_UNIX`, `sockaddr_un`, `.X11-unix` in `Sources/` returns nothing).
DISPLAY=:0 on local clients ordinarily resolves to `/tmp/.X11-unix/X0`; libX11
falls back to `127.0.0.1:6000` only when the Unix socket isn't there, *and* only
for some hostnames — the literal `:0` form on some Xlibs will try unix-first and
fail without falling back. XQuartz publishes both: a launchd-managed Unix socket
via `hw/xquartz/mach-startup/launchd_fd.c:42` (`launchd_display_fd`), then a TCP
listener too (gated by `nolisten tcp` defaults but available).

Won't bleed for Sun clients on the LAN — they're remote, they use TCP. Will
bleed the instant Todd tries running a Mac-side X client (e.g. an x11-compiled
tool installed via Homebrew) against swift-x. The hostname `:0` will work for
some Xlibs (those that try TCP first) and fail for others (Xlib on Linux
defaults to Unix-first since forever).

- Severity: medium (works for Sun on LAN; latent for any same-host client).
- Missing: AF_UNIX listener at `/tmp/.X11-unix/X<n>`.
- Trigger: Todd runs a Mac-native X client against swift-x. Or wants to use
  `xdpyinfo` from Homebrew to introspect.
- Fix-shape: second `Listener`-shaped path that binds `AF_UNIX` at
  `/tmp/.X11-unix/X<port-6000>`, accepts, and dispatches into the same
  `runConnection` path. Unix sockets give us bytewise the same protocol so no
  parser change is needed. Era-correct (R6 had it via
  `_XSERVTransMakeAllCOTSServerListeners` —
  `reference/X11R6/xc/programs/Xserver/os/connection.c:256`).

### W2. No BIG-REQUESTS extension — and the project plan calls for it (PROJECT.md:111)

`PROJECT.md:111` lists "SHAPE and BIG-REQUESTS extensions" as a Product 2
deliverable. swift-x advertises `maximumRequestLength = 65535` in SetupAccepted
(`ServerConfig.swift:137`) — the era-correct base value — and `QueryExtension`
returns `present=false` unconditionally (`ServerSession.swift:3151-3156`);
`ListExtensions` returns empty (`:3897-3902`). BIG-REQUESTS doesn't appear
anywhere (`grep -r bigreq Sources/` returns nothing).

Without BIG-REQUESTS a single request is capped at 256140 bytes (65535 × 4).
Real triggers:
- `PolyLine` / `PolyArc` / `PutImage` of a single drawable larger than ~256KB.
  Spec discussion: `reference/xproto/specs/bigreqsproto/bigreq.xml:43` ("This is
  a problem in the core protocol when joining large numbers of lines or arcs,
  since these requests cannot be broken up").
- Toolkits that bulk-upload geometry. Motif's `XmListAddItems` for very long
  lists, `XmText` setting large strings, calculator history. Xt-based code
  generally chunks, but Motif occasionally doesn't.

Sun R6 clients have `client->big_requests = TRUE` available in `os/io.c:265+` so
they're prepared to use it; whether they negotiate it depends on Xlib version.
Recent Xlib does, by default — it calls `XBigReqEnable` during initial
connection prep if the server advertises the extension.

The hidden-gotcha: swift-x advertises 65535 truthfully. The protocol is honest.
The risk isn't lying; it's that a client expecting BIG-REQUESTS may build a
request > 65535 and submit it. R6 readers will reject it at `os/io.c:283-286`.
swift-x will do … something undefined, because the length field will be zero
(BIG-REQUESTS encoding) and `tryRequest` will see `lenIn4 = 0`, compute
`totalSize = 0`, hit the `totalSize >= 4` guard, and log "bogus length —
closing" without actually closing.

- Severity: medium (project plan calls for it; until then, a client emitting
  BIG-REQUESTS form wedges the parser).
- Missing: the extension entirely. Plus a parser branch that recognizes length=0
  → length-in-next-4-bytes form only when the extension is enabled.
- Trigger: any client that calls `XExtendedMaxRequestSize` and gets back >
  65535. Most likely once we run modern X clients against swift-x.
- Fix-shape: implement the BIG-REQUESTS extension (one opcode: `X_BigReqEnable`
  returns `MAX_BIG_REQUEST_SIZE`). On a client-side flip, the dispatcher learns
  to read the extended length. R6 reference:
  `reference/X11R6/xc/programs/Xserver/Xext/bigreq.c:62` (`ProcBigReqDispatch`,
  24 lines of logic). xorg version is functionally identical
  (`reference/xquartz-xserver/Xext/bigreq.c`).

### W3. Single accept-loop thread → SIGPIPE on a peer reset kills the server process

`Listener.swift:309` `acceptConnection` and `:194` `Darwin.read` / `:250`
`Darwin.write` — none of them block SIGPIPE. macOS `write()` on a closed socket
raises SIGPIPE by default, terminating the process unless ignored. R6 explicitly
does `OsSignal(SIGPIPE, SIG_IGN)` in `os/connection.c:286`. swift-x's
`main.swift` doesn't.

- Severity: medium (process death on client misbehavior).
- Missing: `signal(SIGPIPE, SIG_IGN)` at startup; or `MSG_NOSIGNAL` (Linux) /
  `SO_NOSIGPIPE` socket option (macOS — `setsockopt(fd, SOL_SOCKET,
  SO_NOSIGPIPE, ...)`).
- Trigger: client crashes / disappears between `read()` returning bytes and the
  server's reply going out. xterm killed with kill -9 while the server is
  mid-reply.
- Fix-shape: one-line `setsockopt(SOL_SOCKET, SO_NOSIGPIPE)` on each accepted fd
  inside `setNoDelay`, or `signal(SIGPIPE, SIG_IGN)` once at process start.
  macOS supports both.

### W4. `accept` returns; we ignore peer address; no `MaxClients`-style cap

`Listener.swift:309-314` `acceptConnection`: gets `cfd`, returns it. We never
inspect `sockaddr` to log who connected, never apply any access control, and
there's no cap on concurrent sessions. Coordinator hands out resource-id ranges
via 21-bit slices off the same base; that gives roughly 2048 sessions before
wrap (`ServerCoordinator.swift:50-53`). That's fine numerically but a
stuck/zombie session never gets evicted — disconnect is purely client-driven via
EOF.

- Severity: low (project goals don't include hostile-network operation).
- Missing: peer logging, optional access-control hook, idle-timeout.
- Trigger: leaving the server listening on the public internet would be unwise;
  on a LAN it's fine.
- Fix-shape: accept-with-`sockaddr_in` (already declared at `:310`), pull
  `sin_addr` for log, optional reject hook before `runConnection`.

---

## Theoretical / spec-only

### T1. MIT-SHM not implemented — definitively the right call

Confirmed by reading `reference/xproto/specs/xextproto/shm.xml:64-117`: the SHM
extension is for shared memory between client and server *on the same host*. The
XID identifying the segment is an X resource referring to a `shmget()`-allocated
SysV segment — see `reference/X11R6/xc/programs/Xserver/Xext/shm.c:32-50`.
XQuartz still ships the extension but gates it on a SIGSYS probe
(`reference/xquartz-xserver/Xext/shm.c:168` `CheckForShmSyscall` does a trial
`shmget(IPC_PRIVATE, 4096, IPC_CREAT)` and falls back with "MIT-SHM extension
disabled due to lack of kernel support" if SIGSYS fires).

Sun u5 / SS2 clients are remote-only relative to the Mac. They will never call
`XShmAttach` against swift-x because their X libs detect remoteness and don't
try. Even if they did, the shmid would refer to a Sun-side segment that the Mac
can't `shmat`.

- Severity: zero (correct to omit).
- Missing: nothing. The empty `ListExtensions` + false `QueryExtension`
  (`ServerSession.swift:3151-3156, 3897-3902`) is exactly the spec-correct
  answer: not present, clients fall back to `PutImage`. Document the choice and
  move on. No SHORTCUT, no exit plan needed.

### T2. Multi-screen / abstract-Linux-socket / IPv6 absences

Abstract Linux sockets (`@/tmp/.X11-unix/X0` namespace) are Linux-only and not
applicable on macOS. IPv6 listener: swift-x binds `AF_INET` only — IPv6 X
clients can't connect. R6 had IPv6 via Xtrans abstraction; xorg has IPv6
listeners by default. Not bleeding given target population (Sun workstations are
IPv4-only).

- Severity: zero in current scope.
- Missing: IPv6 listener.
- Trigger: only if Todd ever wants to talk to a modern v6-only host.
- Fix-shape: second `AF_INET6` listener; trivial.

### T3. TCP_NODELAY is set but SO_KEEPALIVE isn't

`Listener.swift:317` `setNoDelay` sets `TCP_NODELAY`. Reasonable: X is
request-reply and Nagle hurts interactivity. But no `SO_KEEPALIVE`, so a dead
client (Sun unplugged from LAN) leaves the connection in `ESTABLISHED`
indefinitely. R6 sets `SO_KEEPALIVE` in `os/connection.c` (via Xtrans). XQuartz
inherits that.

- Severity: low.
- Missing: `setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, ...)`.
- Trigger: physical disconnect of a remote Sun client. Today this leaks one
  session per disconnect until the server is restarted.
- Fix-shape: one-liner in `setNoDelay`.

### T4. `listen(fd, 8)` backlog of 8 is fine until it isn't

`Listener.swift:289` uses 8. xorg defaults are typically 128. Not a real risk
for a multi-client server with single-digit clients. Listed only for
completeness.

- Severity: trivial.

---

## Cross-cutting note on architecture

The current `Listener.swift` header comment (lines 16-24) describes a
one-thread-per-session model: each session has a `protocolQueue`
(`ServerSession.swift:56, 229`) that serializes reads, writes, and
AppKit-callback-driven event synthesis. That's a clean concurrency model — much
cleaner than R6/xorg's single-threaded `Dispatch()`+`select()` with manual
fairness counters (R6 `os/io.c:185-191`
`YieldControl`/`YieldControlNoInput`/`YieldControlDeath`, xorg's
`ClientsWithInput` and `IgnoredClientsWithInput` masks). The price is paid in
B1: because there's only one queue per session and writes are blocking, a wedged
write also wedges reads.

Blog-worthy: swift-x's per-session GCD queue is what R6 wanted to be but
couldn't (R6's `workInProgress/MTXserver/` is the abandoned multi-threaded
server attempt — present in the tree but never shipped, see
`reference/X11R6/xc/workInProgress/MTXserver/os/connection.c`). Modern xorg
ended up with a hybrid: an `input_thread` for hotplug-able input devices
(`reference/xquartz-xserver/os/inputthread.c:44`) but the main client-IO loop is
still single-threaded select-based.
