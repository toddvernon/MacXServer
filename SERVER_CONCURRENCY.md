# Server concurrency: the single-thread refactor

Status: draft, 2026-05-09. Sketched after the Motif click-dispatch dead-end
turned out to involve a real wire-order race ("Xlib: sequence lost") plus a
broader race surface around event synthesis on the main thread. Validated
against the R6 server source and the XQuartz Cocoa bridge before drafting.

## Why we're doing this

Two things drove this:

1. **Confirmed wire corruption.** Quickplot from SS2 produced
   `Xlib: sequence lost (0x1054d > 0x554) in reply type 0x16!` on one run.
   That message means a reply hit the client with a sequence number lower
   than the prior reply, i.e. wire-order inversion. It was intermittent
   (didn't reproduce on the next run with the same setup), which is what
   a thread race produces.
2. **Cross-thread session-state reads.** The bridge fires on the AppKit
   main thread and synthesises events by reading `sequenceNumber`,
   `pointerGrab`, `keyboardGrab`, `currentInputFocus`,
   `currentPointerWindow`, `heldButtons` etc. while the read thread is
   mutating those fields. Even when the wire byte order is correct, the
   *content* of the synthesised event can be wrong: a torn read of
   `currentPointerWindow` sends the ButtonPress to the wrong subwindow;
   a torn `heldButtons` produces a nonsense state mask; a torn
   `sequenceNumber` stamps an event with a number that races backwards.

Either is enough to break Motif. Motif's translation manager is the most
paranoid X11 dispatch path that exists. It cross-checks sequence numbers,
modifier masks, time monotonicity, and grab state on every event before
deciding whether to invoke an action.

## What R6 actually does

Single-threaded `select`-driven main loop, as I expected. The relevant
files in `reference/X11R6/xc/programs/Xserver/`:

- `dix/main.c:194` — `main()` initialises everything, calls `Dispatch()`.
- `dix/dispatch.c:229` — `Dispatch()` is the only meaningful loop. It calls
  `WaitForSomething(clientReady)`, then for each ready client services
  requests one at a time via `(* client->requestVector[MAJOROP])(client)`.
  Between request batches it checks the input flag and runs
  `ProcessInputEvents()`. After each client batch it calls
  `FlushAllOutput()`.
- `os/WaitFor.c:134` — `WaitForSomething()` is a `select(2)` over all
  client sockets plus a timeout for timers. Before `select()`,
  `BlockHandler` lets the ddx (device-dependent) layer hook in to drain
  device queues; after `select()`, `WakeupHandler` lets it process
  whatever device input arrived.
- `os/io.c:870` — `WriteToClient()` writes reply/event bytes to a
  per-client output buffer in the dispatcher's memory. `FlushAllOutput`
  flushes those buffers to sockets at the end of each dispatch round.

There is no separate writer thread. There is no lock anywhere on the
hot path. The dispatcher thread owns all server state, all output
buffers, all socket I/O. Input devices feed into the same thread via
the BlockHandler/WakeupHandler hook.

## What XQuartz does

Validated under `reference/xquartz-xserver/hw/xquartz/`:

- `quartzStartup.c:60` — `server_thread()` runs the X server's
  `dix_main()` on a dedicated pthread.
- `quartzStartup.c:84` — `QuartzInitServer()` spawns the server thread
  before the AppKit runloop starts on the main thread.
- `quartzStartup.c:120` — `pipe(fd)` creates a self-pipe;
  `darwinEventReadFD` is added to the X server's `select()` set;
  `darwinEventWriteFD` is what the AppKit main thread writes to.
- `darwinEvents.c:410` — `DarwinPokeEQ()` writes a null byte to the pipe
  from the AppKit thread to wake the server.
- `darwinEvents.c:395` — drain function the server runs when the pipe is
  readable: read all queued bytes, then call `mieqProcessInputEvents()`.
- `darwinEvents.c:420` — example AppKit-side enqueue path:
  `input_lock(); QueuePointerEvents(...); DarwinPokeEQ(); input_unlock();`

So XQuartz has two threads, exactly the shape I want:

- AppKit main thread (NSApplication runloop, NSWindow / NSView / cursors)
- Server thread (the R6 single-thread `Dispatch()` loop)

The bridge between them is a single self-pipe plus a locked event queue
(`mieq`). AppKit threads `lock → enqueue → poke → unlock`; the server's
`select()` wakes on the pipe, reads it dry, and drains the queue inside
its own thread context. After drainage all event delivery
(`WriteToClient`) happens on the server thread, with no cross-thread
state access.

This is the same pattern I want. We're going to use a GCD serial queue
instead of pthread+pipe (GCD handles the wakeup automatically), which
is the modern Swift idiom for the same shape.

## Today's architecture (the race surface)

```
                ┌──────────────────────────┐
                │   AppKit main thread     │
                │   (NSWindow, NSView,     │
                │    AppKit events)        │
                └──┬───────────────────────┘
                   │ direct calls into ServerSession
                   │ (read sequenceNumber, grab state, focus, etc.)
                   │ direct outbound.append(event-bytes)
                   ▼
    ┌──────────────────────────────────────────┐
    │              ServerSession               │
    │   (state: windows, GCs, atoms, grabs,    │
    │    focus, sequence, pointer-window…)     │
    └──┬───────────────────────────┬───────────┘
       │                           │
       │ feed() drains/appends      │ outbound.append(reply)
       ▼                           │
    ┌────────────────┐         ┌───┴───────────┐
    │ read thread    │─────────│ OutboundQueue │
    │ (POSIX read,   │         │  (FIFO bytes) │
    │  feed,         │         └──┬────────────┘
    │  writeAll)     │            │
    └────────┬───────┘            ▼
             │              ┌─────────────────┐
             │              │  write thread   │
             │              │  (waitAndDrain, │
             │              │   writeAll)     │
             │              └────────┬────────┘
             │                       │
             ▼                       ▼
        ┌────────────────────────────────┐
        │   client socket (writeLock)    │
        └────────────────────────────────┘
```

Three threads (counting AppKit main) all touch session state, all
touch the outbound queue, all race for the writeLock.

The races we know exist:

- **Wire-order race.** `writeAll` calls from read thread and write thread
  serialise on `writeLock`, but lock-acquisition order is not the same
  as call order. NSLock is not FIFO. So the byte stream on the socket
  can invert relative to which thread *built* the bytes first.
- **Outbound-drain race.** `feed()` calls `outbound.drain()` to collect
  in-flight bytes; the write thread's `outbound.waitAndDrain()` can
  pull bytes out from under feed() between calls. Either thread might
  write partial sets, in non-deterministic order.
- **Session-state read race.** The bridge runs on the main thread and
  calls back into ServerSession on every AppKit event. ServerSession
  reads `sequenceNumber`, `pointerGrab`, `keyboardGrab`,
  `currentInputFocus`, `currentPointerWindow`, `heldButtons`, etc. on
  the main thread while the read thread is writing them. No locks.
- **Atomicity race.** A request handler that emits multiple messages
  (e.g. ChangeProperty also fires PropertyNotify; mapWindow on a
  top-level fires MapNotify + ConfigureNotify + Expose) can have main
  thread events squeezed in between. The wire-level sequence is then
  not what either side expects.

## The new shape

```
       ┌───────────────────────────────────────┐
       │          AppKit main thread           │
       │   (NSWindow / NSView / AppKit only)   │
       │                                       │
       │  on event:                            │
       │    1. read NSView → X-window-id       │
       │       (under bridge.slots lock)       │
       │    2. queue.async { handler(args) }   │
       │  (no session-state access)            │
       └─────────────────┬─────────────────────┘
                         │ posts work
                         ▼
       ┌───────────────────────────────────────┐
       │     Protocol thread (DispatchQueue,   │
       │     serial, one per session)          │
       │                                       │
       │   sole owner of:                      │
       │     - all ServerSession state         │
       │     - the client socket (read+write)  │
       │     - all event synthesis             │
       │                                       │
       │   work sources, all serialised:       │
       │     ◦ DispatchSourceRead on socket    │
       │       → read bytes, dispatch requests │
       │     ◦ queue.async {} from main thread │
       │       → handle UI event               │
       └───────────────────────────────────────┘
```

The protocol thread is a single serial GCD DispatchQueue. AppKit-side
operations that *must* run on the main thread (NSWindow.show,
makeKeyAndOrderFront, NSCursor, NSView.setNeedsDisplay) keep using
`DispatchQueue.main.async` from the protocol thread. That's the only
direction we cross threads from server → AppKit, and it's
fire-and-forget; the protocol thread doesn't wait for completion.

There is no OutboundQueue. There is no writeLock. There is no separate
write thread. The protocol thread builds bytes and writes them to the
socket synchronously, in the order it produced them. Wire order is
trivially correct, like R6.

The XQuartz mapping:

| XQuartz                          | Us                                  |
|----------------------------------|-------------------------------------|
| `server_thread` (pthread)        | `protocolQueue` (GCD serial)        |
| pipe + `select` wake             | GCD source + `queue.async` wake     |
| `input_lock` + `mieq` enqueue    | `queue.async { … }` (atomic)        |
| `mieqProcessInputEvents`         | the async closure body itself       |
| `WriteToClient` per-client buf   | session-local `[UInt8]` flush buf   |
| `FlushAllOutput` end of round    | direct `write(2)` after each batch  |

GCD's serial queue replaces both XQuartz's pipe-based wakeup and its
explicit `mieq` lock. Submitting a block via `queue.async` is
thread-safe by construction; submission ordering is preserved; the
queue runs them serially. This is strictly simpler than the XQuartz
implementation of the same idea, with identical semantics.

## The closure surface that needs to redirect

Today the bridge calls back into ServerSession via closures (defined in
`Sources/SwiftXServerCore/WindowBridge.swift`). Each closure currently
runs synchronously on the AppKit main thread and synthesises X events
via direct mutation of session state. After the refactor, each closure
does only:

```swift
queue.async { [weak session] in
    session?.handleButton(topLevel: topLevel, x: x, y: y, button: button, isDown: isDown)
}
```

`handleButton` runs on the protocol thread, reads grab state / focus /
pointer window, builds the ButtonPress event, writes it to the socket.
All that logic already exists in ServerSession; the change is moving
*when* it runs from "synchronously in the AppKit handler" to
"asynchronously on the protocol thread".

The closures (every one currently invoked on main thread):

- `setOnMouse` — ButtonPress / ButtonRelease
- `setOnMouseDragged` — MotionNotify with button held
- `setOnPointerMoved` — MotionNotify and the EnterNotify/LeaveNotify chain
- `setOnPointerEnteredView` — EnterNotify chain
- `setOnPointerExitedView` — LeaveNotify chain
- `setOnKey` — KeyPress / KeyRelease
- `setOnFocus` — FocusIn / FocusOut
- `setOnTopLevelResize` — ConfigureNotify
- `setOnPaste` — synthesised KeyPress/Release sequence
- `setOnCopy` — ConvertSelection roundtrip kickoff
- `setOnCloseRequest` — WM_DELETE_WINDOW ClientMessage

Drawing calls go the other direction (protocol thread → main thread)
and already use `DispatchQueue.main.async` inside the bridge. Those
don't need to change.

## Bridge slot map

The bridge keeps `slots: [UInt32: WindowSlot]` mapping X-window-id to
NSWindow + NSView. It's mutated when the protocol thread creates or
destroys windows, and read on the main thread when AppKit events fire
to translate "which NSWindow got the click" to "which X-window-id".

Small race surface, the existing `bridge.lock` already handles it.
Keep as-is. This matches XQuartz: their `mieq` enqueue is also under a
lock; only the server-side dequeue is lock-free.

## What stops needing locks

Once the protocol thread is sole owner of session state:

- Remove `@unchecked Sendable` cargo culting from `ServerSession`
- Remove `OutboundQueue` entirely. Replies and synth-events get
  appended to a session-local `[UInt8]` buffer the protocol thread
  flushes at the end of each unit of work
- Remove `writeLock` in `Listener.runConnection`
- Remove the `writeThread` in `Listener.runConnection`

What still needs locks:

- `bridge.slots` (small, read-mostly, separate from session state)
- `coordinator.atoms` and `coordinator.selectionOwner` (server-global,
  shared across sessions, intentionally so)

## Wakeup mechanism

`DispatchQueue` (custom, serial, target queue = global userInitiated)
plus `DispatchSourceRead` on the client socket fd. Standard Swift
idiom, no kqueue plumbing needed. The serial queue guarantees handler
blocks run in submission order.

`DispatchSourceRead` fires when the fd becomes readable. We read
non-blocking until EAGAIN inside the source's event handler, which
runs on the queue. While that handler is running, additional fd-ready
events get coalesced into a single pending fire. UIIntent posts via
`queue.async` queue up behind the in-progress handler. Both paths
serialise naturally.

Ordering caveat: if the user clicks (intent posted) while there are
unread bytes from the client that include requests sent later in
wall-clock time, the source handler may read those requests before the
intent runs, so the click ends up with a higher sequence stamp than its
"real" wall-clock moment. This is fine per X11: events are stamped with
the most recent request the server processed when the event was
emitted, not with what would have been "fair" by clock time. R6 has
the same property.

## Migration order

Each step keeps `swift test` green and the live xterm/xcalc demos
working before moving on.

1. Add `protocolQueue: DispatchQueue` to `ServerSession` (serial,
   custom target). Don't use it yet; create and own it. Tests pass
   unchanged.
2. Wrap each AppKit-side closure that currently synthesises events to
   `protocolQueue.async { … }`. ServerSession's handler bodies don't
   change yet (they still do the same work; just running on the new
   queue now). Run live xterm + xcalc to verify nothing breaks.
3. Replace the read-thread loop in `Listener.runConnection` with a
   `DispatchSourceRead` on the client socket targeting `protocolQueue`.
   The dispatch source's event handler reads bytes non-blocking, calls
   `session.feed`, writes the returned bytes synchronously (no lock,
   only writer now).
4. Remove the write thread and `OutboundQueue`. Replies and
   synth-events get appended to a session-local `[UInt8]` flush buffer
   during dispatch, written at the end of each handler.
5. Remove `writeLock` from `Listener.runConnection`. Only one writer
   thread, lock is dead code.
6. Audit ServerSession for any remaining `@unchecked Sendable` hacks
   that were only needed because of the racy access pattern.
7. Run quickplot from SS2 again. If clicks now dispatch, race confirmed
   as the cause. If they don't, we've at least eliminated the variable
   and can go back to the XQueryPointer / focus-chain hypotheses with
   a clean baseline.
8. Run the full M1/M2/M3 fixture suite + the captured-replay
   regression test to confirm we haven't broken anything else.

## What stays unchanged

- AppKit code on the main thread (NSApplication runloop, drawing,
  NSWindow lifecycle). Modern macOS forces these onto main and we want
  them there anyway. Same as XQuartz.
- `coordinator.atoms` and `coordinator.selectionOwner` (server-global,
  cross-session, intentionally shared). Existing locks stay.
- The capture format, the replay path, OPCODE_STATUS, RENDERING_DESIGN.
- WindowBridge's protocol surface (the `setOn…` closures). The closure
  bodies change to "post to queue and return" but the protocol on
  `WindowBridge` itself is unchanged.

## Risks

- **Deadlock between protocol thread and main thread.** If protocol
  thread calls `DispatchQueue.main.sync` while main thread is blocked
  waiting on the protocol queue, deadlock. Avoid by keeping all
  protocol→main calls `async`. Audit for `.sync` after the refactor.
  XQuartz has the same risk and handles it by having no .sync calls
  from the server thread to AppKit.
- **AppKit operations dispatched from protocol thread might land in
  wrong order with respect to events.** E.g. protocol thread tells
  main "show this NSWindow" via async, then immediately emits MapNotify
  to the client. The client sees MapNotify before the NSWindow is
  visible. This is fine — clients don't care, and AppKit will draw the
  window on the next runloop tick. XQuartz has the same property.
- **Latency.** Single-threaded means a slow request (e.g. a big
  PolyText with font lookup) blocks event delivery briefly. In practice
  on a modern Mac this is microseconds. R6 has the same property and
  has been shipping like that since 1994.
- **Test fixtures that drive `session.feed` directly.** Unit tests
  don't go through the listener, so they don't hit the dispatch queue.
  They exercise the same handler logic. Tests should pass without
  modification.

## Open questions

- One protocol queue per session, or one shared serial queue for all
  sessions? Multi-client mode shares the coordinator already. Per-
  session queue matches today's "thread per client" model and is
  simpler. R6 uses a single thread for *all* clients. Either works on
  modern hardware. Going per-session unless something forces otherwise.
- Sequence-number stamping on events fired by the AppKit main thread:
  the closure carries the AppKit data, and the protocol thread reads
  `sequenceNumber` at the moment it processes the work. Events get
  stamped with whatever seq is current at the moment the closure
  runs, not at the moment the user clicked. Per spec, that's correct.
  R6 does the same thing because it reads the sequence number when
  emitting the event, not when the device produced it.

## References

- `reference/X11R6/xc/programs/Xserver/dix/dispatch.c:229`
  (`Dispatch()` — the main loop)
- `reference/X11R6/xc/programs/Xserver/os/WaitFor.c:134`
  (`WaitForSomething()` — single `select()` over all clients)
- `reference/X11R6/xc/programs/Xserver/os/io.c:870`
  (`WriteToClient` — per-client output buffer, dispatcher-thread only)
- `reference/xquartz-xserver/hw/xquartz/quartzStartup.c:60`
  (`server_thread` — the X server thread on macOS)
- `reference/xquartz-xserver/hw/xquartz/quartzStartup.c:120`
  (the self-pipe that wakes the server from the AppKit thread)
- `reference/xquartz-xserver/hw/xquartz/darwinEvents.c:410`
  (`DarwinPokeEQ` — the AppKit-side enqueue + poke)
