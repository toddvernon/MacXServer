# Architecture: swift-x vs xorg vs XQuartz

Architecture overview fork. What follows characterizes the three servers as
structures, not as feature sets. Where the other ten forks ask "does swift-x get
this opcode right?", this one asks "are these the same kind of program?". Short
answer: no. Long answer below.

## Layering

**xorg (and therefore XQuartz)** splits the source tree along a layering that's
been stable since X11R4 and is still visible in the modern code:

- `dix/`: Device Independent X. The protocol dispatcher, the resource database,
  client connection lifecycle, all the request handlers that manipulate logical
  X objects (`ProcCreateWindow`, `ProcChangeProperty`,
  `ProcSetSelectionOwner`...). Files: `dix/dispatch.c`, `dix/tables.c`,
  `dix/resource.c`, `dix/events.c`, `dix/property.c`, `dix/selection.c`,
  `dix/main.c`.
- `mi/`: Machine Independent. Graphics primitives and event queue logic
  expressed against an abstract screen: software polygons, software text walks,
  software arcs, the event queue, software cursors. Files: `mi/midispcur.c`,
  `mi/mieq.c`, `mi/miarc.c`, `mi/mipoly.c`.
- `fb/` (and the R6-era `cfb/`, `mfb/`): framebuffer-resident rendering. Reads /
  writes pixels in software against a memory buffer the DDX gave it.
  `fb/fbpict.c`, `fb/fbcopy.c`, etc.
- `os/`: operating system glue. `os/connection.c` (listen/accept), `os/io.c`
  (per-client buffered reads/writes), `os/WaitFor.c` (the `select()` over all
  client sockets). This is the layer that knows about file descriptors and
  signals; everything above it talks in terms of `ClientPtr`.
- `hw/<ddx>/`: Device Dependent X (the DDX). One subdir per host environment:
  `hw/xfree86/` for the real-hardware X server, `hw/xwin/` for Cygwin, `hw/vfb/`
  for the headless test server, `hw/xquartz/` for macOS. The DDX owns screen
  init, mouse/keyboard bring-up, the cursor backend, and (for rootless cases)
  the windowing-system bridge.
- `miext/`: middle-machine-independent extras like `rootless/` (the
  per-top-level real-host-window plumbing XQuartz hooks into) and `damage/` and
  `shadow/`.

**XQuartz** is "xorg plus `hw/xquartz/`." It does not re-implement dispatch,
resource handling, the event queue, or the protocol itself. The actual
Mac-specific code is concentrated in `reference/xquartz-xserver/hw/xquartz/`:

- `X11Application.m` — subclass of `NSApplication` that owns the AppKit runloop.
  `X11ApplicationMain` at `X11Application.m:754` is the binary's entry point; it
  builds the NSApp, spawns the X server on a background pthread (see "Threading"
  below), then calls `[NSApp run]`.
- `quartzStartup.c` — wires AppKit and the X server's `dix_main` together.
  `server_thread` at `quartzStartup.c:61`.
- `darwinEvents.c` — translates AppKit events into the internal event format and
  pokes the X server thread via a pipe.
- `quartzKeyboard.c` — TIS keyboard → keysym translation, on the AppKit side.
- `xpr/xprFrame.c` — the per-top-level rootless framing, using the private
  `xp_*` framework. `xp_create_window` at `xprFrame.c:194` is the actual call
  that gives every X top-level a private CoreGraphics-backed window the X server
  draws into.
- `pbproxy/` — NSPasteboard ↔ X selection bridge (runs as a separate X11 client
  thread).

XQuartz also pushes window-management out of the server proper into a separate
Cocoa-aware X client; see "quartz-wm" section below.

**swift-x** has no such split. The whole server lives in two SwiftPM modules:

- `Sources/Framer/` — wire codec only. The closest analogue to a spec-defined
  boundary in the xorg tree; this is just the byte layout of every request,
  reply, event, and error. No semantics, no rendering. Used by the capture tool
  (Product 1) and the server (Product 2) alike.
- `Sources/SwiftXServerCore/` — everything else. 25 files, about 9900 lines.
  There is no DIX/DDX split. `ServerSession.swift` alone is 4000 lines and mixes
  the dispatcher (`dispatch(_:)`), the resource handlers (`handlePolySegment`,
  `handleClearArea`), AppKit-side callbacks (`handleMouseEvent`,
  `handleKeyEvent`), and event synthesis. `CocoaWindowBridge.swift` mixes what
  xorg would call "rootless miext" plus "darwin DDX" plus "darwinEvents input
  translation."

Is the missing split a problem? At swift-x's current scale (one session-class,
NSWindow-per-top-level rootless), no — the layering xorg has exists to support
12 DDX backends, 8 visual classes, and several rendering backends including
1-bit framebuffer. swift-x has one backend (Core Graphics via `FlippedXView`)
and one visual it actually cares about (`TrueColor` 24-bit), and a fixed
assumption about rootless mode. The xorg layering would be expensive ceremony
for something with one backend. The risk it introduces: anything that *would* be
a per-platform feature in xorg (e.g. an alternative fullscreen-rooted mode, a
software framebuffer, an offscreen render backend for tests) has no obvious seam
to slot into. Today that's not a real cost. If the project ever grows a second
rendering backend it'll need to grow a seam first.

## Dispatch

**xorg** is the textbook ProcVector design.
`reference/xquartz-xserver/dix/tables.c:67` declares `int (*ProcVector[256])
(ClientPtr) = { ProcBadRequest, ProcCreateWindow, ProcChangeWindowAttributes,
... };`. Indexed by the request's major opcode (first byte on the wire). The
dispatch loop is at `reference/xquartz-xserver/dix/dispatch.c:469`; the actual
call site is `dispatch.c:546`: `result =
(*client->requestVector[client->majorOp])(client);`. Each client also has a
`swapped` mirror (`SwappedProcVector` at `tables.c:326`) used when the client
declared opposite byte order on the wire. Extensions register their major opcode
at runtime and slot into the same vector above `EXTENSION_BASE` (135). X11R6
(`reference/X11R6/xc/programs/Xserver/dix/dispatch.c:229`, call site at line
305) is the same pattern; xorg inherited it verbatim from R6.

**swift-x** routes via a `switch` on an enum. `ServerSession.feed()` parses each
request into a `Framer.Request` enum case; `dispatch(_:byteOrder:)`
(`ServerSession.swift:2413`) is a 1500-line `switch` with 88 cases. Practical
equivalence to a ProcVector — Swift compiles an enum switch to a jump table —
but with structural differences:

- Extensions can't slot in at runtime. Adding extension support means growing
  the enum, which means rebuilding. Since the project plans to ship BIG-REQUESTS
  and SHAPE only, this is fine. `QueryExtension` at `ServerSession.swift:3151`
  currently always returns `present=false`.
- No swapped vector. The byte-order argument is passed *down* into decoders /
  encoders that handle byte-swap per-field. Equally correct.
- Sequence numbering is at the dispatch site rather than inside each ProcFoo, so
  an opcode handler that forgets to bump `sequenceNumber` isn't a class of bug
  here.

The 88 cases are in the right ballpark for a useful R6-era server (the spec
defines 119 core opcodes; not all matter for the targeted clients). Readable at
this scale.

## Resource model

**xorg** keeps a per-client resource hash table. Each client gets a slot in
`clientTable[]` (`reference/xquartz-xserver/dix/resource.c`) containing its own
resource hash, indexed by 29-bit resource ID. The top 3 bits of an XID are
reserved by the server; bits below `RESOURCE_ID_MASK` are the client's to
allocate. ID allocation handshake: on connection setup the server replies with
`resource-id-base | resource-id-mask`; the client OR's its own counter against
the base. xorg hands out `client->clientAsMask = client->index <<
RESOURCE_CLIENT_OFFSET` (`resource.c:1183`) so every client's IDs live in a
private 21-bit slice. When a client disconnects, `FreeClientResources(client)`
(`resource.c:1117`) walks every bucket in that client's hash and frees every
resource — that's the "automatic destruction cascade" of windows, pixmaps, GCs,
fonts, properties, etc. The cascade is also re-entered recursively when a window
is destroyed (children destroyed in post-order; properties on each window
dropped on the way).

**XQuartz** inherits this verbatim. No change.

**swift-x** has the rough shape but not the unification. Resources live in eight
separate typed tables on `ServerSession`:

```swift
public let colors = ColorTable()
public let windows = WindowTable()
public let gcs = GCTable()
public let pixmaps = PixmapTable()
public let fonts = FontTable()
public let cursors = CursorTable()
public let properties = PropertyTable()
```

Each is a `[UInt32: T]` dictionary keyed by XID. There is no single "resource of
any type" lookup; there is no "this XID is currently in use by *some* resource
type" check (the spec needs that for `BadIDChoice` detection). ID-base / ID-mask
follow the spec: `ServerCoordinator`
(`Sources/SwiftXServerCore/ServerCoordinator.swift:45`) hands out
non-overlapping `(base, mask)` pairs per accept, with a default of 21-bit slices
starting at `0x04400000`. Multi-client ID collision is prevented by
construction.

The destruction cascade on client disconnect exists but is partial.
`ServerSession.cleanupOnDisconnect()` (`ServerSession.swift:2246`) snapshots
every top-level (parent == root) and destroys those NSWindows via the bridge,
then drops them from `windows`. It does **not** walk the per-table dictionaries
to free GCs, pixmaps, fonts, cursors, or properties belonging to that client. In
single-client mode they go away when `ServerSession` is deallocated, which is
fine. In multi-client mode (which the listener now supports) those tables are
per-session and so the leak is bounded to the session's lifetime, but sub-window
children of a destroyed top-level aren't recursively destroyed and the in-flight
properties don't fire `PropertyNotify` on delete. The "automatic destruction
cascade" is materially incomplete.

The other place this matters: `DestroyWindow` should recursively destroy
children, fire `DestroyNotify` for each, and free resources that mention the
dead window. swift-x's behavior here lives in `destroySubtree`
(`ServerSession.swift:1279`) and probably handles windows correctly; resources
whose lifetime is tied to those windows (GCs pointing at the drawable,
properties on the dead window) need checking by the appropriate per-feature
fork. From this fork's distance, the structural risk is that swift-x has no
generic resource graph and so resource-lifetime correctness is a one-off per
type.

## Event pipeline

**xorg core** is single-threaded. Input devices feed events through
`mi/mieq.c`'s queue:

- `mieqEnqueue` (`mi/mieq.c:199`) — called by the DDX when a hardware event
  arrives (or, in xorg-with-evdev, by a signal handler). Appends to a ring
  buffer guarded by the input lock.
- `mieqProcessInputEvents` (`mi/mieq.c:514`) — drained from the dispatcher
  thread when it notices the queue is non-empty.
- The actual event-to-wire conversion happens inside dispatcher context: an
  EnterNotify, KeyPress, ButtonRelease, etc. gets formatted by `dix/events.c`
  and pushed onto the per-client output buffer via `WriteToClient`
  (`os/io.c:870`), which then drains on the next `FlushAllOutput()` (end of
  dispatch round).

**XQuartz** keeps the xorg event pipeline and bolts AppKit on top via a
pipe-and-poke pattern:

- `X11Application.m` is the AppKit event sink. AppKit `sendEvent:` hands
  NSEvents to translation functions that build internal-format X events.
- `DarwinSendPointerEvents` / `DarwinSendKeyboardEvents` (`darwinEvents.c:488`,
  `:567`) take the lock, call `mieqEnqueue`, then call `DarwinPokeEQ()`
  (`darwinEvents.c:410`), which writes a single null byte to
  `darwinEventWriteFD`.
- The server thread's `select()` set includes `darwinEventReadFD`; the byte
  unblocks `WaitForSomething`. After the select() returns,
  `mieqProcessInputEvents` runs in dispatcher context. From there it's identical
  to xorg.

So XQuartz's input pipeline crosses threads exactly once — at the mieq enqueue
point — and the cross is a lock + pipe-byte. The X event format isn't reached
until the server thread is back in charge.

**swift-x** has a different shape that landed for a different constraint set:

- AppKit fires NSEvents (`mouseDown:`, `keyDown:`, etc.) on `FlippedXView`
  (`Sources/SwiftXServerCore/FlippedXView.swift`). Per the AppKit contract those
  fire on the main thread.
- The view calls into the registered handler lists on `CocoaWindowBridge`
  (`mouseHandlers`, `keyHandlers`, `pointerMovedHandlers`...). All registered
  handlers fire in succession.
- Each handler is a closure that — per `SERVER_CONCURRENCY.md` — hops onto its
  session's `protocolQueue` via `queue.async`, where it calls
  `ServerSession.handleMouseEvent` (or `handleKeyEvent`, etc.). Those methods
  read the up-to-date grab/focus/pointer state, build the X event byte sequence,
  and append to a session-local outbound buffer.
- The protocol thread (also the queue running socket reads) flushes the outbound
  buffer to the client socket synchronously.

The end-state shape is structurally close to XQuartz's. The Mac runloop owns
NSEvents; everything else hops to a single serial queue per session that owns
session state and the socket. The crossing between the two threads is
`DispatchQueue.async` instead of pipe-and-lock, but the semantics are identical:
submission ordering is preserved, the dequeue side runs in-thread, no
cross-thread reads of session state happen.

`SERVER_CONCURRENCY.md` documents this as the post-refactor state and the
listener code at `Listener.swift:101` reflects it (single-source read on
`protocolQueue`, no separate write thread, no `OutboundQueue` producer/consumer
split). The brief named "split read/write socket threads" — the code says
otherwise as of this read. Captured below as a finding.

## Threading

The three servers stack up like this:

| | Threads | Cross-thread comms |
|-|---------|---------------------|
| **xorg / X11R6** | One (`Dispatch()`). Input devices feed via signal handlers + `BlockHandler`/`WakeupHandler` hooks. | None on the hot path. Signal handlers post to a flag; dispatcher drains. |
| **XQuartz** | Two: AppKit main thread + server thread (`pthread_create(server_thread, ...)` at `quartzStartup.c:94`). | self-pipe + `mieq` enqueue under `input_lock`. Server thread reads pipe to wake from `select()`. |
| **swift-x** | One protocol queue per session (serial GCD DispatchQueue) + AppKit main thread. | `DispatchQueue.async` from AppKit handlers into the session's protocol queue. |

**xorg single-threaded** has no races: wire order matches dispatcher order, no
lock acquisition costs in the hot loop. It's been shipping this way since 1987.
It only stops working when the host's GUI event source isn't signal-poke-able —
macOS being the canonical case, since AppKit demands main-thread ownership.
Modern xorg also accreted thread-safety annotations for concurrent extensions
(DRI2/DRI3, GLX); R6 didn't have to.

**XQuartz two-thread** preserves the xorg single-thread invariant inside the
server and confines AppKit cross-talk to one pipe-bounded edge. Wire ordering is
correct trivially because only the server thread writes to client sockets.
Fragile points: the input lock and the pipe are two primitives that need to stay
coherent (explicit thread checks throughout `darwinEvents.c`); synchronous
main-thread waits on the server thread have historically produced stalls. Each
enqueue adds a write+read syscall pair, which is invisible on a Mac but
historically mattered on slower hardware.

**swift-x's per-session serial queue** preserves the same invariant (one thread
owns session state and is the only writer to the socket) while replacing the two
primitives (input lock + pipe) with GCD's submit-and-forget. Strictly fewer
moving parts. Wrong if any AppKit handler ever needs a synchronous answer from
the X side (it doesn't today; the shape doesn't support it without a
completion-callback detour). Fragile in two ways: (1) a long dispatch handler
stalls input delivery (same as xorg; microseconds on modern hardware); (2) the
deadlock surface if anyone reaches for `DispatchQueue.main.sync` from the
protocol queue while main is waiting on the queue. `SERVER_CONCURRENCY.md` calls
this out under "Risks."

Net: swift-x's threading model is structurally the closest to XQuartz's of the
three pairings, with a Swift-idiomatic substitution (GCD serial queue for
pthread+pipe). The brief described swift-x as "split read/write socket threads +
NSApplication runloop"; that was the pre-refactor shape —
`Listener.swift:101-138` now has a single DispatchSourceRead per session
targeting the same `protocolQueue` that also writes, no separate write thread,
no `writeLock`.

## Genealogy

XQuartz is a fork of xorg-server with most code in lockstep and the
macOS-specific surface confined to `hw/xquartz/` and `miext/rootless/`. The
XFree86 → X.org fork happened around 2004; XQuartz inherits from the unified
xorg tree post that transition. XQuartz tracks xorg-server with a lag; the lag
mostly manifests in core layers (`dix/`, `os/`, `mi/`), and most divergence is
in `hw/xquartz/`. Occasional patches to `os/connection.c` and `os/access.c` deal
with launchd socket activation.

**In lockstep:** the protocol dispatcher, the resource model, the extension
registration mechanism, the event queue (`mi/mieq.c`), software font and
arc/polygon code, the connection setup handshake, almost all `Xext/` code.

**Drifted:** the rootless DDX (XQuartz only); macOS keyboard translation
(`quartzKeyboard.c`); the NSPasteboard bridge (`pbproxy/`); the AppleWM
extension; the GLX backend (Mac-specific Mesa build); display/RANDR
(`quartzRandR.c`).

**swift-x is clean-room.** Search `Sources/` for `dix_main`, `ProcCreateWindow`,
`mieqEnqueue`, `RESOURCE_CLIENT_OFFSET`, `ClientPtr`, `clientAsMask`: zero hits.
There are conceptual echoes — the resource-id-base/mask layout matches the spec,
which matches xorg because xorg implements the spec — but no structural borrow.
Symbol names follow Swift idiom (`ServerSession.dispatch`,
`ResourceTables.GCTable`), not the xorg ProcFoo / FreeBar / NoticeBaz naming.
The architecture in `Sources/SwiftXServerCore/` is what you'd write if you'd
read the X11 spec but never opened xorg's source. swift-x pattern-matched
XQuartz exactly twice that I can find: once for the two-thread model
(`SERVER_CONCURRENCY.md` cites `quartzStartup.c:60` and `darwinEvents.c:410` as
the inspiration for the GCD migration), and once for the rootless-per-NSWindow
shape (via quartz-wm, discussed next). Otherwise swift-x is its own thing.

## quartz-wm: a separate window manager process

XQuartz pushes window-management responsibility *outside* the X server entirely.
The X server (`hw/xquartz/`) does the bare minimum: it gives every top-level X
window a hidden CG-backed surface via `xp_create_window` in `xpr/xprFrame.c`,
but it doesn't make NSWindows, doesn't draw a title bar, doesn't handle dragging
or resize handles, and doesn't participate in the macOS application-switcher.
All of that is delegated to **quartz-wm**, a separate process launched by
`launchd` under XQuartz that connects to the X server as a normal X11 client (it
uses `XSelectInput`, `XGrabButton`, `XReparentWindow` — see
`reference/quartz-wm/src/x-window.m:106-121` and the `SubstructureRedirectMask |
SubstructureNotifyMask` mask at `quartz-wm.h:46`). When an X client maps a
top-level, quartz-wm catches the resulting `MapRequest` via
SubstructureRedirect, reparents the client into a frame X window of its own
creation, asks the X server (via the private AppleWM extension implemented in
`hw/xquartz/applewm.c`) to associate that frame with a real NSWindow, and from
then on translates AppleWM events (NSWindow drag start, close button click,
minimize, dock interaction) into X events the client understands. swift-x is its
own WM, in the sense that `CocoaWindowBridge` directly creates NSWindows for X
top-levels — there's no separate process, no SubstructureRedirect, no need for
the client to issue ICCCM-style WM hints to get drag/resize. The structural
implications cut both ways: swift-x avoids an IPC hop and gets tighter coupling
between "the X side knows where this window lives" and "the Mac side knows where
this window lives" (no PIDs to coordinate, no need for the AppleWM extension at
all). The cost is that swift-x conflates server and WM responsibilities — there
is no seam to insert a different WM (a tiled-WM mode, or twm-style decoration
inside fullscreen), and behaviors that XQuartz's WM gets for free (focus
stealing rules, app-switcher integration, drag-to-different-space) have to be
re-implemented inside the server. For the project's stated goal (vintage Sun
apps look native on Mac) the trade is right. Just acknowledge it.

## Plain language: how alike are these three?

XQuartz is xorg with a Mac DDX swapped in. Everything above `hw/xquartz/` is
shared code; everything inside `hw/xquartz/` is the Mac-specific glue. If you
wanted to build a "BSD console DDX" you'd add a sibling `hw/bsdconsole/`, leave
the rest alone, and have yourself a new X server. The two are 95% the same
program.

swift-x is a clean-room reimplementation that occasionally pattern-matched
XQuartz. The wire protocol is identical (it has to be). The threading shape is
structurally analogous to XQuartz with GCD in place of pthread+pipe. Everything
else — the dispatcher (switch on enum vs. ProcVector), the resource model (eight
typed tables vs. one generic hash), the WM integration (in-process NSWindow vs.
external quartz-wm), the rendering backend (Core Graphics vs. fb/cfb), the
layering (none vs. DIX/MI/OS/DDX) — is its own design, arrived at mostly by
reading the X11 spec and writing what made sense in Swift.

So: XQuartz ↔ xorg are siblings. swift-x is a cousin who's heard the family
stories but has been living abroad for twenty years. The three are not equally
similar to each other; the failure modes, the strengths, and the things you'd
want to verify before trusting them aren't the same set.

## Blog hooks

- **"Three X servers, one wire protocol."** The thesis of the comparison study:
  a server can be wildly different inside and still be indistinguishable on the
  socket. Hook off the dispatch comparison (ProcVector vs enum switch) to show
  the divergence.
- **"Why I don't have a DIX/DDX split."** A defense of the missing layering —
  explains what xorg's layering buys (n-DDX support, n-rendering-backend
  support, automated test backends) and what it costs (boilerplate at every
  layer crossing). swift-x has one backend; the seams xorg has would be theater.
- **"XQuartz reads the kernel's private symbols. I read NSWindow. The difference
  is more interesting than I thought."** Compare `xp_create_window` (private
  framework, gives you a CG-backed surface you draw into) with NSWindow + NSView
  (public framework, gives you the whole macOS window machinery for free,
  including drag/resize/minimize). XQuartz pays for the private framework with
  having to write quartz-wm separately. swift-x pays for NSWindow with the loss
  of fine-grained control over window levels and shaping.
- **"Threading X servers from 1987 to 2026."** R6 single-thread → XQuartz
  two-thread (pipe + lock) → swift-x serial queue. Same invariant (one writer of
  socket bytes; no contended state) reached three ways. The shape stays. The
  synchronization primitives keep collapsing into the language.
- **"A 4000-line file isn't always a code smell."** swift-x's
  `ServerSession.swift` is one file with 88 dispatch cases and every request
  handler in it. xorg fans out the same logic across `dix/*.c` (windows in
  `dispatch.c`, atoms in `atom.c`, properties in `property.c`...). For a small
  server with one author, the one-file shape is more navigable; for a project
  with 15 maintainers spread across the world it would fall apart. Discussion of
  when each shape pays.

## Findings the brief asked me to flag

- **swift-x's "split read/write socket threads" model named in the brief no
  longer matches the code.** `Listener.swift:101-138` uses a single
  `DispatchSourceRead` per session targeting the session's `protocolQueue`, with
  the same queue performing socket writes via `session.writeCallback`. There is
  no separate write thread, no `OutboundQueue` consumer thread, no `writeLock`.
  `SERVER_CONCURRENCY.md` describes this as the post-refactor target; the
  listener code is at the target. The brief's description appears to refer to
  the pre-refactor (pre-2026-05-09) shape.
- **swift-x's resource destruction cascade is partial.** `cleanupOnDisconnect`
  (`ServerSession.swift:2246`) destroys top-level NSWindows but does not iterate
  the GC, pixmap, font, cursor, or property tables. In the single-client model
  the entire session deallocates anyway, but in the now-active multi-client
  model the per-table dictionaries can hold stranded entries. Whether this
  causes a visible bug depends on whether any cross-session lookups exist (atoms
  are intentionally shared; XIDs aren't, so the strict answer is "no observable
  bug today"). Flagged as a structural risk rather than an active leak.
- **No generic resource type.** Eight typed tables, no "look up this XID as
  whatever it is" path. This is fine for the fixed R6 surface but blocks future
  error-correctness work — spec says `BadIDChoice` fires when a client asks the
  server to create a resource with an ID that collides with *any* existing
  resource of *any* type; swift-x can't currently check that cross-type.
