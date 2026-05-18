# Architectural risk register

Three buckets per the comparison study convention. Architecture-only;
opcode-specific risks belong with the per-feature forks.

## Actively bleeding now

(Nothing in this bucket. The architectural problems I found are either latent or
limited in blast radius.)

## Will bleed when X happens

### Multi-client handler broadcast fan-out

`CocoaWindowBridge` (`Sources/SwiftXServerCore/CocoaWindowBridge.swift:43-54`,
`:114-160`) stores handler lists, not a routed dispatch. Every AppKit NSEvent
fires *every* registered handler on every session: `fireMouse` calls all
`mouseHandlers`, `fireKey` calls all `keyHandlers`, etc. Each session's handler
filters by checking whether the window-id is in its own `windows` table;
non-owners no-op. xorg, by contrast, routes events to the owning client at the
dispatcher level — there's no "ask each client whether this event is for them"
step.

This works today because the project is mostly single-client. Once two real
clients connect simultaneously (e.g. xterm + xcalc, the M3 "two NSWindows on
screen at once" case), every keystroke runs all session handlers, each session
hops to its own protocol queue, and each non-owning session does the filter work
before dropping the event. The cost scales with N²: N sessions, each handler's
work runs N times, the queue hop happens N times.

For the project's target of "a few X clients from one Sun at a time" this isn't
a real cost. It becomes a real cost the moment we run something like a CDE
session with 10+ X clients (`dtwm`, `dtterm`, `dtcalc`, `dthelpview`, panel
processes — easily 8 connections).

Fix shape: bridge keeps a `(topLevelId → session)` map and routes events
directly. Each session registers itself, not free closures. Won't be hard; not
urgent.

### Deadlock surface between protocol queue and AppKit main

The post-2026-05-09 threading model (per `SERVER_CONCURRENCY.md`) is sound *as
long as nothing on the protocol queue ever calls `DispatchQueue.main.sync`*.
Today it doesn't — drawing and NSWindow manipulations from the server side use
`.main.async`. But there's no linter for this and no audit gate; the next
contributor who needs to read an NSWindow property from server context could
reach for `.main.sync` and instantly introduce a deadlock that only triggers
under load.

XQuartz has the same shape and the same risk; their solution is "no .sync calls
from server thread to AppKit, ever, and code review enforces it." swift-x should
adopt the same rule explicitly.

Concrete check: grep `Sources/SwiftXServerCore/` for `DispatchQueue.main.sync`
and any `.sync(execute:)`. Today (2026-05-14) it should return zero hits. Adding
a CI check that grep returns zero would make this guarantee survive future
contributors.

### Resource destruction cascade is type-by-type, partial

`ServerSession.cleanupOnDisconnect` (`ServerSession.swift:2246-2261`) walks
top-level windows and destroys their NSWindows + window-table entries. It does
**not** walk the per-table dictionaries for `gcs`, `pixmaps`, `fonts`,
`cursors`, or `properties` to drop entries the disconnecting client created.

In single-client mode this is invisible: the session deallocates when the
listener returns and Swift's ARC drops the tables wholesale. In multi-client
mode each session owns its own per-table state, so the leak is bounded to the
session — but the session lives as long as the listener thinks it does. Property
entries against destroyed windows hang around indefinitely. GC entries against
destroyed drawables can't be garbage-collected without an explicit walk.

In practice on the targeted clients this is silently fine because disconnects
are rare. It's a structural pattern-match bug rather than an observable one.
xorg's `FreeClientResources` (`reference/xquartz-xserver/dix/resource.c:1117`)
is the canonical shape: a single function that walks every entry in the client's
resource hash and calls the appropriate per-type free routine.

Fix shape: extend `cleanupOnDisconnect` to walk each table and drop entries.
Pseudo-trivial.

### No generic resource type means no cross-type ID collision check

Spec: `BadIDChoice` fires when a client creates a resource with an ID that's
already in use by *any* existing resource of *any* type. xorg implements this
with the unified resource hash: the existence check is cheap (single lookup,
type-agnostic).

swift-x has eight typed tables. A `CreateGC` with an ID that collides with an
existing window won't raise `BadIDChoice` — the GC table is checked, the window
table is not. The reverse is also true. In practice clients allocate IDs
sequentially within the base/mask slice they were told, so collisions are
vanishingly rare, but they aren't impossible (a buggy client, or a client doing
ID-recycling for long-running sessions).

This is the kind of bug that doesn't bite until it bites very hard. Severity is
real but probability is low for the targeted Sun-era clients. Fix shape: add an
`xidInUse(_ id: UInt32) -> Bool` query that ORs across all eight tables, call it
at the top of every create handler.

## Theoretical / spec-only

### Layering absence blocks alternate backends

swift-x has no DIX/MI/DDX seam. There is one rendering backend (Core Graphics
via `FlippedXView`), one input backend (AppKit NSEvents via
`CocoaWindowBridge`), and one window-system backend (rootless NSWindow per
top-level). If the project ever grew a second of any of these (a software
framebuffer for tests, an offscreen renderer for capture validation, a Metal
backend), there's no obvious seam to slot it into.

Theoretical only because the project explicitly doesn't plan to grow them.
PROJECT.md scopes scaling and rendering decisions to one backend with three
scaling planes. If a contributor ever wants to add an offscreen rendering mode
for headless testing (which would genuinely be useful), the missing seam will
become a refactor task.

### Single-process serial-queue model can't survive a real multiplayer
extension

If swift-x ever needed to support an extension that requires real concurrent
work (e.g. SHM with another process feeding pixels in parallel, or SHAPE with a
long region computation that should not block input delivery), the
single-protocol-queue model would have to grow. xorg has the same property and
has been kludging around it for 25 years with thread-local extension state.
swift-x has the advantage of writing this in Swift today; it has the
disadvantage of having committed to "one serial queue owns everything" as a
correctness property.

Theoretical because the project's stated extension surface (`BIG-REQUESTS`,
`SHAPE`) is small and all the extensions are synchronous request/reply. Don't
fix now; remember when extending.

### Single 4000-line `ServerSession.swift` is fine until it isn't

The dispatcher, every request handler, every event-synthesis routine, and every
grab/focus/crossing helper all live in one file. 88 cases in a single `switch`
is at the upper edge of "still navigable in a text editor." Adding another 30
cases for extension opcodes would push it over the edge.

Theoretical: today it's readable. Future refactor seam is "split the dispatch
switch into per-feature handler files." xorg does this with one file per
resource type (`dix/window.c`, `dix/property.c`, `dix/atom.c`); the equivalent
in Swift would be moving the `case .changeProperty:` body to a
`handleChangeProperty` function in a `PropertyHandlers.swift`. Mechanical, not
urgent.
