# Bridge-dispatch coalescing

Goal: replace every `bridge.<op>()` call that hits main thread with an
accumulator entry on a per-top-level deferred queue, flushed once per
top-level per read batch as a single `DispatchQueue.main.async` block.

This is the structural answer to the "server CPU is free, dispatch
overhead and client round-trips are the actual bottleneck" asymmetry.
Supersedes the earlier paint-only proposal; this one extends the same
mechanism to every bridge call so it helps xterm and any
non-shape-using client too, not just xcalc.

## What macOS already gives us for free

Each X top-level is its own NSWindow with its own CGBitmapContext. The
macOS WindowServer keeps that backing alive between AppKit redraws.
We've been getting backing-store-for-free at the **top-level
boundary** the whole time:

- Another macOS window covering our X top-level → no Expose needed,
  compositor restores from the saved NSWindow contents on uncover.
- A different X client's top-level covering ours → same, each is its
  own NSWindow.
- Dragging our X window around the screen → no Expose, compositor
  moves the rendered NSWindow.
- Mission Control / window-cycle transitions → free.

R6 had none of this — every cross-window cover/uncover triggered Expose
because the server had one shared framebuffer. This is a real reason
swift-x has felt fast despite the naive per-mutation dispatch model:
macOS is doing the hardest work invisibly.

**Where macOS does NOT help** is *intra*-NSWindow: descendant X
windows that live inside a single top-level all share that NSWindow's
backing CGContext. xcalc's 40 buttons live in one NSWindow; cover /
uncover / resize / reshape *among descendants of the same top-level*
gets no compositor assistance. That's the surface this refactor
targets.

## Motivation

The paint-per-mutation model dispatches every visible-pixel-affecting
bridge call to main async immediately. For real client patterns:

| Client / pattern | Dispatches per batch today |
|--|--|
| xcalc resize (40 buttons × 3 paints each) | ~120 |
| xterm `tail -f` long log (50 `ImageText8` ops per TCP batch) | ~50 |
| xterm resize (80×24 grid redraw) | ~2000 |
| oclock per-second tick | ~4 |
| xeyes per cursor motion event | ~3 |
| Motif menu pop (Configure cascade) | ~10-30 |

Every dispatch is a `DispatchQueue.main.async` block with its own
`saveGState` / `restoreGState` / `setNeedsDisplay`. The fill work
itself is cheap — CG eats thousands of rects in milliseconds. The cost
is the dispatch ceremony × N.

We also emit Expose events per-mutation. On a vintage Sun over a
WAN-bridged telnet link, each round-trip costs ~50-100ms. xcalc resize
generates ~80 Exposes = 4-8 seconds of client-side latency the user
perceives as "slow."

R6 batches paint within a single request via `pWin->valdata` +
`miPaintWindow`. We can do better: batch across requests within a read
batch. R6 had per-request batching because their server was
cycle-constrained and their clients were local. Our server is ~100×
faster than R6-era hardware and our clients are vintage / often
remote. The constraint shape is inverted.

## Principle

**Every bridge call that today does `DispatchQueue.main.async`
accumulates into a per-top-level deferred queue. Flush at well-defined
points dispatches the entire queue as a single main async block per
top-level.**

The "today does `DispatchQueue.main.async`" surface:
`paintWindowRects`, `clearArea`, `copyArea`, `drawPolySegment`,
`drawPolyLine`, `drawPolyFillRectangle`, `drawPolyRectangle`,
`drawPolyArc`, `drawPolyFillArc`, `drawFillPoly`, `drawImageText8`,
`drawPolyText8`, `drawPutImage`, `setWindowBoundingShape`, plus the
Expose-emit path on the wire.

Each accumulator entry is a recorded operation; the flush replays them
in arrival order. Pixmap-target draws stay synchronous — they're
already not dispatched today, no change.

## Wire-visible behavior

- **No protocol change.** Clients see the same Expose events, reply
  data, wire sequence — just batched.
- **Expose payload is the union of damage within the batch.** A
  mutation cascade dirtying the same window three times produces one
  Expose with the unified region, not three.
- **No mid-batch peek.** If a draw op needs to read the backing
  (`GetImage`, window-source `CopyArea`), we flush before reading.
  Caller perspective unchanged.

## Flush points

1. **End-of-read-batch on `protocolQueue`.** Primary. After
   `runAccepting` processes all currently-buffered bytes from a single
   `read()`, flush all sessions' accumulators before going back to
   block on the socket.
2. **Before each backing-bitmap read.** `GetImage` window source,
   `CopyArea` window source. Flush the source's top-level first so
   the read sees current state.
3. **Before sending Expose bytes on the wire.** Server bg paint must
   precede Expose per X11 spec. The end-of-batch flush already runs
   paints; the Expose accumulator emits its batched events as part of
   the same flush, in correct order.
4. **On session disconnect.** Final flush so the user doesn't see torn
   state.

## Architecture

```swift
/// One recorded bridge op queued for replay at flush time.
enum DeferredBridgeOp {
    case paintWindowRects(rects: [WindowBackgroundRect])
    case clearArea(rects: [Framer.Rectangle], background: RGB16)
    case drawPolySegment(...)
    case drawImageText8(...)
    case copyArea(...)
    case setWindowBoundingShape(rects: [Framer.Rectangle]?)
    // ... one case per existing bridge entry point that does main.async
}

final class TopLevelAccumulator {
    private var ops: [DeferredBridgeOp] = []
    func append(_ op: DeferredBridgeOp) { ops.append(op) }
    /// Strictly FIFO drain — caller dispatches one main async block
    /// that replays the captured ops in order.
    func drain() -> [DeferredBridgeOp] {
        let out = ops; ops.removeAll(keepingCapacity: true); return out
    }
}
```

`ServerSession` owns `[UInt32: TopLevelAccumulator]` (top-level id →
accumulator). Each existing `bridge.<op>(...)` call site becomes
`session.accumulator(for: topLevel).append(.<op>(...))`. Flush walks
the dict, drains each accumulator, and dispatches one `main.async`
block per non-empty top-level. Inside the block, each op replays via
the existing bridge-method body (just without the `main.async`
wrapper).

### Replay loop shape

```swift
DispatchQueue.main.async { [weak self] in
    guard let self = self,
          let view = self.slot(topLevel)?.view,
          let ctx = view.backing else { return }
    for op in capturedOps {
        switch op {
        case .paintWindowRects(let rects):
            self.replay_paintWindowRects(ctx: ctx, rects: rects)
        case .clearArea(let rects, let bg):
            self.replay_clearArea(ctx: ctx, rects: rects, background: bg)
        case .drawPolySegment(let args):
            self.replay_drawPolySegment(ctx: ctx, args)
        // ... one case per op kind
        }
    }
    view.setNeedsDisplay(view.bounds)
}
```

Each `replay_*` function is the body of today's bridge method minus
the `main.async` wrapper. The existing public methods become two
lines: build the op, append to accumulator. The replay functions
saveGState/restoreGState around each op's body so CG state doesn't
leak between ops.

### Expose accumulation

Sibling path. Mutation handlers call
`exposeAccumulator.add(window: id, region: r)` instead of writing
Expose bytes to `outbound` immediately. At flush time the accumulator
emits one Expose per window with the union of regions. Those bytes go
to `outbound` and ship to the socket alongside the main async paint
replay.

## Phase plan with validation gates

Every phase ends with **stop and validate** — Todd runs xcalc / xterm
/ whatever on the Sun and confirms behavior before the next phase
lands.

### Phase 1 — Accumulator skeleton + plumbing (no behavior change)

`TopLevelAccumulator`, `DeferredBridgeOp` enum, per-session dict. Each
existing `bridge.<op>` call routes to `accumulator.append(...)`. A
naive flush runs at the end of *every handler* so dispatch count and
behavior are identical, just routed through a buffer.

**Stop and validate:**
- Launch xcalc, render initial — should look identical to today.
- Press buttons, resize once.
- Expected: zero perceptible difference (same speed, same pixels). If
  it's faster, slower, or anything looks off, the plumbing has a
  routing bug. Don't proceed to phase 2.
- 1262 tests stay green.

### Phase 2 — End-of-read-batch flush

`Listener.runAccepting`'s read loop calls
`session.flushAccumulators()` at the bottom of each iteration. The
per-handler flush from phase 1 is removed. Now multiple handlers in
one read batch share one main async block per top-level.

**Stop and validate:**
- **xcalc resize on the Sun**: should be visibly snappier. Target
  3-4× faster on the slow-side (drag corner → buttons settle).
- **xterm `tail -f`** something noisy (e.g. `dmesg` or a long log):
  server-side feels lighter on CPU; visual throughput preserved.
- **xeyes following the cursor** + **oclock ticking**: smoothness
  preserved, no jitter introduced at flush boundaries.
- Expected: faster on slow ops, same on simple ones, nothing broken.
  If smoothness regresses (visible "stutter" at batch boundaries), the
  flush cadence needs revisiting.

### Phase 3 — Backing-read flush points

Add explicit `flush(topLevel:)` calls before any code path that reads
the backing: `GetImage` window source, `CopyArea` window source,
`readDrawablePixels` for window targets.

**Stop and validate:**
- **xterm page-scroll** (`man cc`, then space-bar through pages):
  every line of every page must be correct. No smeared / repeated /
  missing rows.
- **xterm `cat large.txt`**: scrolling should produce clean output
  with no carryover between rows.
- Specific risk being verified: missing flush before CopyArea source
  read = stale pixels carried during scroll.
- Expected: scrolling clean. If you see torn rows, we missed a flush
  site.

### Phase 4 — Expose accumulation

Per-window Expose accumulator. Mutation handlers route Expose intent
through it. Flush emits one Expose per window with union region.

**Scope of the win is intra-NSWindow only.** Inter-window cover /
uncover (dragging another macOS window over an X top-level, or
switching apps) is already handled by the macOS compositor — no
Exposes are emitted there in the first place. The Phase 4 win is
specifically for descendants inside a single NSWindow: xcalc's 40
buttons during a resize, Motif widget cascades on layout change,
descendant SHAPE updates. xcalc resize Expose count drops from ~80 to
~40, with each Expose carrying the final clipList rather than an
intermediate.

**Stop and validate:**
- **xcalc resize on the Sun, local network**: faster than phase 2.
  This is the intra-NSWindow case where the refactor's win lives.
- **xcalc resize on the WAN-bridged Sun** (the hardest case): should
  drop dramatically — target ≥4× from today. Same intra-window path,
  amplified by network latency.
- **Cover/uncover (inter-window)**: drag a macOS window over an X
  window then off again. Should be already-fast and unchanged by this
  refactor — macOS compositor handles it. Verifies we haven't broken
  that path.
- **Motif menu pop on dtpad / dtcalc**: popdown still triggers redraw
  of the underlying area. (Save-under isn't part of this refactor;
  we still rely on Expose for popup-revealed pixels — the underlying
  area is intra-NSWindow descendant territory.)
- Expected: drastically faster xcalc resize (intra-window win),
  inter-window cover/uncover unchanged (still free via macOS),
  popdowns still re-render. If a menu doesn't re-render its
  underlying area, we're coalescing an Expose we shouldn't.

### Phase 5 — Telemetry + STATUS + DECISIONS

`TopLevelAccumulator` exposes counters: ops queued per flush, flush
count per second, op-type histogram. Verbose log dumps after each
high-traffic operation. Roll `STATUS.md`. Append `DECISIONS.md` entry
about the deferred-dispatch architecture.

**Stop and validate:**
- Run `macxserver --verbose`, do one xcalc resize, check the log.
- Expected: 1-2 dispatches per top-level per batch instead of 120-ish.
  If the counts are higher than expected, the flush isn't running at
  the right point or some bridge call is still bypassing the
  accumulator.

## Non-goals

- Public X `DAMAGE` extension. Different surface; this is internal
  coalescing only.
- Pixmap-target deferred drawing. Pixmap draws stay synchronous.
- Cross-session merging. Each session owns its accumulators.
- Per-pixel diffing or region merging beyond unioning Exposes.
- Display-link / vsync alignment of flushes. Request-driven flushes
  are sufficient at our cadence.
- Backing store, per-window CALayer compositing, bit-gravity
  preservation. Those address a different bottleneck
  (overlapping-window workflows) we don't have at scale.

## Risks

- **Ordering correctness.** Replay must be strict FIFO so server bg
  paint precedes client draws and CopyArea source reads precede dst
  writes. Mitigation: accumulator never reorders; a unit test
  sequences `fill A, copy A→B` in one batch and verifies B has
  filled pixels.
- **CG state leak between replayed ops.** Each op must start with
  default CG state. Mitigation: every `replay_*` wraps in
  `saveGState`/`restoreGState`. Lint once, lock in.
- **Mid-batch read sees stale data.** Forgetting a flush before a
  backing read = pre-batch state. Mitigation: catalog the read-path
  call sites + the phase 3 scrolling test catches the obvious case.
- **Memory growth in pathological batches.** A read batch with
  thousands of ops queues a lot of recorded state. Practical batches
  are 50-200 ops; pathological case bounded by a soft cap (e.g.
  10K ops → early flush) added in phase 5 if telemetry shows we need
  it.
- **Diagnosability when something looks wrong.** Bug appears as "this
  op didn't happen" inside an opaque flush block. Mitigation: per-op
  `log?.log(...)` at append AND replay, gated on `--verbose`. The
  wire side is unchanged so capture-diff still works for
  protocol-level questions.
- **Re-entrancy from main thread.** Main thread replay must not
  mutate the accumulator. Mitigation: accumulator mutations are
  `protocolQueue`-only; main thread reads a captured snapshot.

## Done condition

- xcalc resize on the Sun box visibly faster (target ≥3× wall-clock
  speedup on local network; ≥5× on the WAN bridge).
- xterm `tail -f` server CPU drops measurably (Instruments check).
- All five validation gates passed by Todd's eye, in order.
- 1262 tests green plus new ordering + draw-then-read regressions.
- STATUS.md + DECISIONS.md rolled.
- PAINT_COALESCING_REFACTOR.md deleted (superseded by this doc).

## Sizing

- Phase 1: 600-800 lines (enum + accumulator + routing + `replay_*`
  extraction). 1 day.
- Phase 2: 100-200 lines (flush hook in `Listener.runAccepting`,
  remove per-handler flushes). Half a day.
- Phase 3: 100-200 lines (flush points + scrolling validation). Half
  a day.
- Phase 4: 200-300 lines (Expose accumulator + region union). Half a
  day.
- Phase 5: 100-200 lines + STATUS + DECISIONS. A couple of hours.

Total: ~2.5-3 days of focused work with a Sun-side validation pause at
the end of each phase.

## A note on what this isn't

This isn't backing store (X11-spec retained pixels for obscured
regions). It isn't per-window CALayer compositing. It isn't
bit-gravity preservation. It isn't damage-tracking in the per-pixel
sense. We evaluated those alternatives — they're solving a different
problem (overlapping-window-heavy workflows, which our target
Motif/Athena apps mostly don't have).

This refactor matches the actual constraint shape: fast server, slow
clients, batched protocol traffic, dispatch overhead and intra-NSWindow
Expose round-trips being the bottleneck. The architectural model is
"record + replay per batch," which is small, testable, and reversible
if a phase fails validation.

The split of labor that emerges:

- **Inter-NSWindow visibility** (top-level cover/uncover, app switch,
  Mission Control): handled by macOS for free. We do nothing.
- **Intra-NSWindow visibility** (descendant cover/uncover, resize
  cascade, SHAPE updates): handled by this refactor's Expose
  accumulation.
- **Intra-NSWindow drawing throughput** (xterm output stream, oclock
  tick, xeyes motion): handled by this refactor's dispatch
  accumulation.

Three layers, each at the right granularity. No reinvention of
macOS-provided mechanisms.
