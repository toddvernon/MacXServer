# SHM / transport / large requests: three-way comparison

Three columns of how the same surface area is handled: listening sockets, large
requests, write buffering, read fragmentation, MIT-SHM. The interesting bit
isn't presence/absence (swift-x is younger, of course it's missing things), it's
*what* it's missing and what the era-correct + modern shape of each answer looks
like.

## Spec + extension specs

### Core protocol (`reference/x11-protocol-spec/x11protocol.html`)

The base protocol uses a 16-bit `length` field in 4-byte units, so a single core
request maxes at 65535 × 4 = 262140 bytes. The setup-accepted reply carries
`maximum-request-length` (CARD16) for the client to consult. Requests over this
limit produce `BadLength`. There is no provision in core for partial requests; a
server must read a whole request before dispatching.

There is no provision in core for shared-memory image transfer. `PutImage`
carries pixels inline in the request body, bound by `maximum-request-length`
minus header. `GetImage` carries them in the reply, bound by the same.

### BIG-REQUESTS (`reference/xproto/specs/bigreqsproto/bigreq.xml`)

Single opcode, single round-trip: `BigReqEnable`. Reply carries a new 32-bit
max. When the extension is enabled on a client, requests with `length == 0` in
the 16-bit field are interpreted as having an additional 32-bit length field
immediately after, in 4-byte units (spec line 45: "If the normal 16-bit length
field of the protocol request is zero, then an additional 32-bit field
containing the actual length (in 4-byte units) is inserted into the request").

Spec is short and unambiguous. The whole extension is one server-side opcode + a
length-field rule in the parser. Modern xorg caps the new max at
`MAX_BIG_REQUEST_SIZE = 4194303` (16 MB, 4-byte units —
`reference/xquartz-xserver/include/os.h:73`).

### MIT-SHM (`reference/xproto/specs/xextproto/shm.xml`)

Same-host shared memory. Sequence: client calls `shmget` + `shmat`, then
`XShmAttach` to pass the shmid to the server which `shmat`s the same segment.
Then `XShmPutImage` references the segment + offset instead of copying pixels
through the socket. Spec lines 64-117 spell out the same-host-only nature: "is
stored in a shared memory segment, and thus need not be moved through" the wire.

Has explicit "is supported?" round-trip (`XShmQueryVersion`,
`XShmQueryExtension`) so clients fall back to ordinary `PutImage` gracefully if
the server doesn't have it.

## X11R6

### Connection setup (`os/connection.c`)

`CreateWellKnownSockets()` at line 220 is the entry point. It clears socket
bitmasks, queries `sysconf(_SC_OPEN_MAX)` for `lastfdesc`, capped at `MAXSOCKS`.
Then `_XSERVTransMakeAllCOTSServerListeners` at line 256 — the Xtrans library
opens all listening sockets the build was configured for. On a typical Unix
build that's two: an `AF_UNIX` socket at `/tmp/.X11-unix/X<n>` plus an `AF_INET`
socket at port 6000+n. `WellKnownConnections` is a fd bitmask.

Then `OsSignal(SIGPIPE, SIG_IGN)` at line 286 (relevant later — swift-x doesn't
do this). `SIGHUP` triggers `AutoResetServer`, `SIGINT`/`SIGTERM` trigger
`GiveUp`. The `RunFromSmartParent` business with `SIGUSR1` is how `startx` knows
the server has bound its sockets and is safe to connect to.

### Accept + dispatch loop

`WaitForSomething` (in `os/WaitFor.c`) is the central scheduler. It select()s on
`AllSockets` (clients + listeners), then for each readable fd either calls
`EstablishNewConnections` (accept) or marks the client as having input. The
selector is fairness-aware: `ClientsWithInput` tracks who already has a full
request buffered, and `timesThisConnection` counts consecutive dispatches to one
client (`io.c:96`) so a chatty xterm can't starve a quiet one.

This is the *intent* swift-x's per-session GCD queue replaces. R6 had one OS
thread doing everything via `select`. Multi-threaded R6 was attempted
(`reference/X11R6/xc/workInProgress/MTXserver/`) and not shipped.

### Read fragmentation (`os/io.c:ReadRequestFromClient`, line 200)

Header comment lines 163-183 explains it well. Each client has an `oci`
(ConnectionInputPtr) with a growable `buffer`. On entry: pick up where last
`ReadRequest` left off, look at first 4 bytes to learn request length, ensure
buffer is big enough, `_XSERVTransRead` more bytes if needed. Then return either
a full request, "not yet" (return 0), or "die" (return -1).

The `gotnow < needed` block (line 280-372) is the partial-read machinery. It can
grow the input buffer up to `MAXBUFSIZE`, shrinks back after a huge request
burst (`oci->size > BUFWATERMARK`). Aggressive fairness: if exactly one client's
worth of data arrived in the buffer, leave the rest for the *next* `select`
round so other clients get a turn (`AvailableInput = oc`, line 410).

BIG-REQUESTS branch (`#ifdef BIGREQS`, lines 264-275): if the 16-bit length is
zero and `client->big_requests` is set, switch to reading the 32-bit field from
`xBigReq`. Identical logic to the modern xorg version.

### Write buffering (`os/io.c:FlushClient`, line 611, and `WriteToClient`, line 872)

`WriteToClient` doesn't write — it appends to the per-client `oco->buf` and sets
`NewOutputPending`. The actual write happens at the bottom of the main loop via
`FlushAllOutput` (line 797), which iterates `OutputPending` clients and calls
`FlushClient`.

`FlushClient` (line 609) is the real machinery. It builds an `iovec` array (the
current `oco->buf` plus the new chunk plus padding), calls `_XSERVTransWritev`,
handles `ETEST(errno)` (EAGAIN/EWOULDBLOCK) by stashing the unwritten tail back
into `oco->buf` (growing the buffer up to `MAXBUFSIZE`), marks the client
write-blocked (`AnyClientsWriteBlocked = TRUE`), and bails. The main loop's next
`select` will watch the client fd for writability and re-flush.

This is what swift-x doesn't have. The R6 `oco->buf` is the missing piece.

### BIG-REQUESTS server (`Xext/bigreq.c`)

24 lines of useful logic (entire file is 87 lines, mostly license).
`BigReqExtensionInit` (line 45) calls `AddExtension` to register
`XBigReqExtensionName`. `ProcBigReqDispatch` (line 63) is the only handler:
verify it's `X_BigReqEnable`, set `client->big_requests = TRUE`, reply with
`MAX_BIG_REQUEST_SIZE`. The parser-side branch in `io.c` does the actual
length-extension work.

### MIT-SHM server (`Xext/shm.c`)

Allocates `ShmDescRec` structs (line 53) tracking shmid + size + addr.
`ShmAttach` does `shmat(shmid, ...)` to map the client's segment. `ShmPutImage`
uses the mapped pointer instead of reading bytes from the socket. Full
implementation is ~800 lines because it also has to interlock with the screen's
pixmap-create path for shared pixmaps (line 88, `pixmapFormat`,
`shmPixFormat[]`).

R6's `shm.c` doesn't probe at init — it assumes SysV SHM works. The probe at
startup (`CheckForShmSyscall`) is a modern xorg addition.

## xorg + XQuartz today

Most of the os/ layer in `reference/xquartz-xserver/os/` is a direct descendant
of R6's `os/` with iterations: Xtrans absorbed, the fairness counters slightly
rewritten, an optional `input_thread` for hotplug-able input devices (XQuartz's
HID layer). The dispatch model is still single-threaded select-based at heart
(`os/WaitFor.c`).

### XQuartz-specific: launchd-passed FDs (`hw/xquartz/mach-startup/launchd_fd.c`)

The big XQuartz override. XQuartz on macOS doesn't bind its own Unix socket.
Instead, `launchd_display_fd` (line 42) does the launchd check-in dance:
`launch_data_new_string(LAUNCH_KEY_CHECKIN)` → `launch_msg` → pull the listening
fd out of the response dict (key `BUNDLE_ID_PREFIX ":0"` or just `":0"`). The fd
is already-bound by launchd before the X server even starts; xorg core then
plugs it in via `ListenOnOpenFD` (`os/connection.c:992`) which calls
`_XSERVTransReopenCOTSServer(5, fd, port)` — type 5 is
`TRANS_SOCKET_LOCAL_INDEX`.

This is why XQuartz starts on-demand. The user runs `xterm`, libX11 connects to
`/tmp/launchd-xxxxx/org.xquartz:0`, launchd accepts on the socket, sees an
inbound connection, fires up XQuartz, hands the bound listening fd plus the
accepted fd to it. XQuartz takes the listening fd via `ListenOnOpenFD`, the
accepted fd via `AddClientOnOpenFD` (`os/connection.c:1057`), and is "started"
before its main loop even runs.

`os/connection.c:998-1019` does the path-massaging: if `DISPLAY` is a path
(which launchd-style sets), it `stat`s it, optionally strips a `.N` screen
suffix, and trusts that as the local socket.

### Write buffering (`os/io.c:FlushClient`, line 825)

Same shape as R6, slightly cleaner. `iovec`-based writev, partial-write handling
with `output_pending_mark(who)` (line 903), buffer realloc up to `INT_MAX` (line
921). `AbortClient` + `MarkClientException` on allocation failure (line 925).
`WriteToClient` (line 681) has a `BUG_RETURN_VAL_MSG(in_input_thread(), 0, ...)`
guard (line 688) — explicitly disallows the input thread from writing replies,
since the main dispatcher owns output buffering. The input thread does input
events only; it pipes into the main thread which then writes.

### Read fragmentation (`os/io.c:ReadRequestFromClient`, line 227)

Functionally identical to R6. Same buffer growth, same `BIG-REQUESTS` branch,
same fairness accounting. The only meaningful change is that the swap and check
macros are inlined out via `padding_for_int32` etc.

### MIT-SHM on macOS (`Xext/shm.c:168 CheckForShmSyscall`)

XQuartz checks SysV SHM availability at extension-init time. macOS has SysV SHM
enabled by default but with a tiny `kern.sysv.shmmax` (4MB on older releases,
~16MB on newer; raisable via sysctl). `CheckForShmSyscall` does a trial
`shmget(IPC_PRIVATE, 4096, IPC_CREAT)` with `SIGSYS` trapped; if `SIGSYS` fires
(kernel without SysV SHM at all, e.g. some embedded BSDs) we get `MIT-SHM
extension disabled due to lack of kernel support` (`shm.c:1538`) and the
extension never registers.

XQuartz does ship MIT-SHM. `darwin.c:70-72` and `darwin.c:254-256` `#ifdef
MITSHM` pull in `shmint.h` and call `ShmRegisterFbFuncs(pScreen)` so
framebuffer-side shared pixmaps work. In practice this matters only for
Mac-native X clients (Homebrew xterm, GIMP-on-X11) talking to XQuartz — Sun
clients are remote, the extension's irrelevant to them.

### BIG-REQUESTS (`Xext/bigreq.c`)

Cosmetically modernized R6 version. Same 24 lines of useful logic.
`maxBigRequestSize` is a `dix/globals.c` long, settable via `-maxbigreqsize`
cmdline.

## swift-x

### Listener (`Sources/SwiftXServerCore/Listener.swift`)

`Listener` (line 35) is one TCP `AF_INET` socket. `createListenSocket` (line
257) does `socket(AF_INET, SOCK_STREAM, 0)`, `SO_REUSEADDR`, bind, `listen(fd,
8)`. No `O_NONBLOCK` set anywhere (grep evidence: zero hits for `O_NONBLOCK` /
`fcntl` / `NONBLOCK` under `Sources/`). No `SO_KEEPALIVE`, no `SO_NOSIGPIPE`.
`TCP_NODELAY` is set in `setNoDelay` (line 317).

Two entry points: `runOne` for one-shot tests (line 65), `runAccepting` for
production multi-client (line 101). The latter is what `main.swift` calls.

Per accept: `acceptConnection` (line 309) gets a client fd. `makeSession` (line
143) builds a `ServerSession` with a coordinator-allocated resource-id range.
Then `runConnection` (line 167) sets up a `DispatchSourceRead` on `clientFd`
targeting `session.protocolQueue`, installs `session.writeCallback = { bytes in
writeAllToSocket(clientFd, bytes) }` (line 179-181), and resumes the source.

The read source's event handler (line 191): stack-allocated 65536-byte buffer,
`Darwin.read`, on `n == 0` cancel the source (EOF), on `n < 0` cancel unless
EAGAIN/EINTR. On success: `session.feed(chunk)` returns bytes to write, and
`writeAllToSocket(clientFd, outBytes)` flushes them inline. The cancel handler
closes the fd and calls `session.cleanupOnDisconnect()` which drops resources
(DestroyAll per X spec default).

The accept loop (`runAccepting`, line 109) blocks on `accept` on the listener
thread, dispatches to GCD per session, loops. No backlog cap on inflight
sessions, no peer logging, no access control.

### Listening on a TCP port only (no Unix-domain socket)

`main.swift:84` constructs `Listener(host: "0.0.0.0", port: 6000)`. There is no
Unix-domain socket at `/tmp/.X11-unix/X0`. Mac-native X clients that resolve
`:0` via `_X11TransSocketUNIXConnect` first will fail to find the unix socket
and may or may not fall back to TCP depending on the libX11 build. Sun clients
explicitly specify `mac.lan:0` and go straight to TCP, so the omission doesn't
bite the primary use case.

### `feed()` parser (`Sources/SwiftXServerCore/ServerSession.swift:2317`)

Bytes-in, reply/event-bytes-out. Accumulates into `inbound` (`[UInt8]`). Loop:
if `awaitingSetup`, try `trySetup` (line 2335); otherwise `tryRequest` (line
2380). Each parser returns the number of consumed bytes or nil if more bytes are
needed. Loop ends when no progress is possible, returns `outbound.drain()`.

`tryRequest` (line 2380): peek the first 4 bytes for length-in-4-byte-units
(lines 2384-2386), compute `totalSize`. If `totalSize >= 4` fails, log "bogus
length — closing" and `return nil`. (Note: the comment says "closing" but
`return nil` doesn't close; the read source keeps running. That's a bug — if the
length is bogus we should emit `BadLength` and shut the connection down. R6
returns -1 from `ReadRequestFromClient` for the same case at `io.c:283-286`.)

No upper-bound check against `config.maxRequestLength`. swift-x advertises 65535
in SetupAccepted (`ServerConfig.swift:137`) but doesn't enforce it. Practical
impact: a request with `length = 65535` will be patiently buffered into
`inbound` (which has no cap) until 262140 bytes arrive. Then decoded normally.
No `BadLength` ever.

No BIG-REQUESTS branch. If a client sends a request with `length=0`, swift-x's
`tryRequest` computes `totalSize = 0`, the `totalSize >= 4` guard returns nil,
and the connection stalls. R6/xorg in the same situation either reject (no
BIG-REQUESTS enabled) or read the 32-bit extended length and proceed.

### Output buffer (`Sources/SwiftXServerCore/OutboundQueue.swift`)

The class is just `var buffer: [UInt8]` plus `append` / `drain`. The file's own
comment (line 6-10) explains: pre-refactor it was a producer/consumer FIFO with
a condition variable; after the single-thread refactor (referenced as
`SERVER_CONCURRENCY.md`), every append + drain happens on
`ServerSession.protocolQueue`, no synchronization needed.

`flushOutbound` (`ServerSession.swift:2266`) drains the queue and hands the
bytes to `writeCallback`. `writeCallback` is the `writeAllToSocket` closure
(`Listener.swift:179-181`).

### `writeAllToSocket` (`Listener.swift:244`)

```
while written < bytes.count {
    let w = Darwin.write(fd, ...)
    if w <= 0 { return }
    written += w
}
```

Loops on partial writes. Critical detail: socket is blocking. So `Darwin.write`
blocks when the kernel send buffer is full. The "partial write" loop is really
only there because POSIX permits short writes even on blocking sockets in some
edge cases (e.g. interrupted by signal). The real failure mode isn't partial
writes, it's the queue's worth of bytes blocking the protocolQueue thread for
arbitrarily long.

There's also no per-session output buffer maintained at the wire layer — if
`write()` did return EAGAIN (which it won't, since we're blocking), the unsent
bytes would just be dropped (`if w <= 0 { return }`).

### MIT-SHM: deliberately absent

`QueryExtension` returns `present: false` unconditionally
(`ServerSession.swift:3151-3156`). `ListExtensions` returns empty (`:3897-3902`)
with a comment that calls this out explicitly: "no XKB, no SHAPE, no MIT-SHM".
This is spec-correct and exactly the right answer.

### BIG-REQUESTS: not yet present, plan calls for it

`PROJECT.md:111` lists "SHAPE and BIG-REQUESTS extensions" as Product 2
deliverables. `grep -r bigreq Sources/` returns nothing. The parser doesn't know
the length=0 form, so even a client that asked-without-checking would wedge the
connection. Until the extension lands, swift-x's 65535-unit ceiling is enforced
de facto by the parser stalling on the malformed request.

## Surprises and divergences

1. **swift-x's read path is more honest than R6/xorg's about fragmentation**,
   accidentally. R6 has elaborate per-client `oci` machinery to handle partial
   requests because the main loop is shared and pre-empts; swift-x's `inbound:
   [UInt8]` is per-session, owned by the session's serial queue, and `feed()`
   just buffers + retries the parser. The R6 fairness counters
   (`ClientsWithInput`, `IgnoredClientsWithInput`, `timesThisConnection`) have
   no analog in swift-x because they aren't needed: GCD's dispatch source per
   session gives fair scheduling for free.

2. **swift-x's write path is less honest than R6/xorg's about backpressure.**
   R6/xorg explicitly handle EAGAIN, buffer the tail, and wait for writability.
   swift-x relies on the kernel buffer + a blocking socket. That works until the
   kernel buffer fills, at which point the protocolQueue thread blocks on
   `write()` and the session stops processing reads. Risk B1.

3. **MIT-SHM on macOS works in XQuartz but is irrelevant to Sun clients.** I
   went in expecting to find that XQuartz drops MIT-SHM entirely; it doesn't. It
   probes at extension-init via `CheckForShmSyscall` (`Xext/shm.c:168`) and
   ships it because macOS does have SysV SHM. But the audience for it on swift-x
   is empty: Sun clients are remote and Xlib won't try `XShmAttach` across the
   network. swift-x skipping it is exactly right.

4. **BIG-REQUESTS is genuinely missing and listed in Product 2 deliverables.**
   The extension is 24 lines of server-side code in R6 (`bigreq.c:62-87`). The
   parser-side support is ~10 lines added to `tryRequest`. Total work probably a
   half-day. The risk isn't malicious clients — it's that the moment swift-x
   serves a modern Xlib client, the client will call `XBigReqEnable` if the
   extension is advertised; if not, the client will respect 65535. So *not*
   advertising it is currently safe (we don't lie), but it's a planned feature,
   not a non-goal.

5. **XQuartz uses launchd to share the listener fd; swift-x reinvents the
   listening loop.** The launchd story is uniquely macOS, and there's a real
   argument for adopting it — it gives you on-demand startup, socket persistence
   across server restarts, and zero `Cannot establish any listening sockets —
   Make sure an X server isn't already running` errors. But it requires a plist
   + a `launch` API dance. Probably not worth it pre-Product-3.

6. **No `/tmp/.X11-unix/X0` is the most user-visible gap in transport.** A Mac
   user expects `DISPLAY=:0` to work. On swift-x today, `DISPLAY=:0` works only
   if Xlib falls back to TCP (some do, some don't). `DISPLAY=localhost:0` works.
   `DISPLAY=mac.lan:0` from a Sun works (the target use case). The cost to add
   Unix-domain support is one extra Listener-shaped path that opens an `AF_UNIX`
   socket; everything downstream is the same.

7. **The "split read/write socket threads" architecture in the project context
   is outdated.** `Listener.swift:24` and `OutboundQueue.swift:6` both note the
   historic split was refactored away — now one `protocolQueue` per session owns
   everything. So the blog-worthy architectural novelty isn't dual-threaded
   sessions; it's per-session GCD queues replacing R6's central select-loop with
   fairness counters.

## Blog hooks

1. **"The R6 X server's fairness counter and what GCD got me for free."** Walk
   through R6's `ClientsWithInput` / `timesThisConnection` machinery in
   `io.c:96, 185-192` and the explicit fairness it has to enforce because one
   `select()` loop services everyone. Then show swift-x's per-session
   `DispatchSourceRead` per `protocolQueue` per session — the fairness fell out
   of the dispatcher. Bonus: point at
   `reference/X11R6/xc/workInProgress/MTXserver/` as evidence that the X
   Consortium tried this in '94 and gave up. The right primitive (per-fd
   dispatch sources backed by a thread pool) didn't exist then.

2. **"Why an X server on macOS doesn't need MIT-SHM but XQuartz still ships
   it."** Reading `Xext/shm.c:168 CheckForShmSyscall` and the `SIGSYS` trap is
   fun. Frame around the question "what's the right thing to do when you control
   both ends of the wire and one end is a Sun on the LAN?" Answer: nothing. The
   extension is dead-on-arrival for the use case. Includes a nice bit about how
   XQuartz's SHM probe exists because BSD/Mach kernels historically didn't
   always have SysV SHM.

3. **"262140 bytes ought to be enough for anybody: living without BIG-REQUESTS
   in 2026."** When does the 65535 × 4 limit actually bite? Walk through the
   era: in 1994 the limit was set deliberately tight because the extension was
   specifically for 3D (PEX) and imaging (XIE), neither of which Sun u5/SS2 era
   apps used. Today, would xterm ever exceed it? No. Would Motif XmTextField?
   No. Would dtcalc? Definitely not. So who *would* hit it? An app rendering a
   large pre-built PolyLine path (a chart, say). Maybe quickplot at extreme
   zoom. Probably nobody in our corpus. End with: the project plan calls for
   BIG-REQUESTS anyway, and it's 24 lines.
