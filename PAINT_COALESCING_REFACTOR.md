# Paint coalescing

Goal: replace synchronous `paintWindowRects` dispatches with damage-region
accumulation + coalesced flush. Match R6's `miPaintWindow` / `pWin->valdata`
shape at our bridge's granularity, so multi-mutation request batches
produce one main-thread paint cycle instead of N.

## Motivation

Today every X11 mutation that touches what's visible (`ConfigureWindow`,
`MapWindow`, `ShapeMask`, `ChangeWindowAttributes` with new bg,
`ClearArea`, restack, descendant move/resize cascade) dispatches its own
`paintWindowRects` to main thread immediately. For one isolated mutation
that's fine. For the dominant toolkit pattern — a related batch of
mutations on the same window, arriving in one read cycle — we
rasterize N times in a row when one paint at the end would produce
identical pixels.

Concrete cost from `/tmp/swift-x-captures/2026-06-03T10-51-17-xcalc.xtap`:

- xcalc resize → 40 buttons × 3 dispatches each (`Configure` paint,
  `ShapeMask Bounding` paint, `ShapeMask Clip` paint) = **120 main
  `DispatchQueue.main.async` tasks**, each with its own `saveGState` /
  `setNeedsDisplay` cycle. The first 80 are wasted — the intermediate
  bitmap states get fully overwritten by the trailing 40.
- xterm scroll → `ConfigureWindow` + `ClearArea` + several `PolyText8`s
  in one read batch, each currently a separate dispatch.
- dtpad / Motif menu pops → Configure cascade across many widgets (the
  dtpad menu-erase regression 2026-05-25 was exactly this pattern
  overwhelming the paint loop).

This isn't a per-app fix; it's the systemic mismatch between R6's
batched-paint model and our paint-per-mutation model.

## R6 reference and our divergence

R6 doesn't paint synchronously on each mutation. Each one stashes
intent on `pWin->valdata->after`. At validate-time (`miValidateTree`,
`mi/mivaltree.c`), the damage tree is walked once and `miPaintWindow`
runs per-window with the accumulated dirty region. The framebuffer ends
in the same state as paint-per-mutation but the actual rasterization
work happens once per validate.

We diverged because we wired bridge dispatch directly into every
handler's mutation point. It worked for early M1-M3 because each
test/replay scenario was a single mutation. As soon as real toolkits
landed (Athena, Motif), the per-batch cost showed up.

## Principles

1. **Damage is accumulated, not dispatched.** A mutation that changes
   visible pixels marks a `DamageRecord` on a per-top-level accumulator.
   No `DispatchQueue.main.async` at the mutation point.
2. **Flush is explicit.** A flush coalesces the accumulator's contents
   into a single main-thread paint cycle per top-level and dispatches.
   Flush points are clearly defined (see below) and load-bearing —
   missing one is a bug.
3. **Order is preserved within a flush.** R6's paint order matters
   (parent bg before child bg before client draws); we preserve relative
   order of `DamageRecord` operations within a flush.
4. **One read-batch = one flush per top-level.** The simplest flush
   point is at the end of `protocolQueue`'s read drain, before the
   thread blocks on the socket again. That's also where R6's batched
   processing lines up.
5. **Reads from the backing trigger a flush.** Any handler that needs
   the backing bitmap to be current (`GetImage`, window-source
   `CopyArea`, `bitmapToRegion` if it ever runs on a window target)
   flushes its top-level's accumulator first.

## Flush points

1. **End-of-read-batch on `protocolQueue`** — primary. After
   `runAccepting`'s read loop processes all currently-buffered bytes,
   flush all top-levels with pending damage before going back to
   `read()`. Most flushes happen here.
2. **Before emitting `Expose`** — the spec says the bg must be painted
   before Expose. Today we already paint then emit. With damage
   accumulation we flush the affected top-level's damage right before
   the Expose batch goes on the wire.
3. **Before any backing-bitmap read** — `GetImage`, `CopyArea` with a
   window source. Flush the source's top-level first.
4. **On session close** — final flush so the user doesn't see torn
   state if their last action was a paint-triggering mutation.

## Damage record shape

Two MVP candidates; pick one in phase 1.

**Option A: opaque op list.** Each accumulator holds an ordered list of
`(topLevel, [WindowBackgroundRect])` records. Flush concatenates per
top-level and dispatches one main async block per top-level. Coalesces
dispatch overhead but doesn't merge paints — every rect still gets
filled. Probably 3-4× speedup on xcalc resize.

**Option B: dirty-region tree.** Per-window dirty `Region` + final
color → bg / border. Flush walks the dirty tree and paints in
parent-first order. Drops overlapping earlier paints (the intermediate
xcalc paints get discarded because the trailing Clip paint covers
them). Probably 8-10× speedup but requires region algebra at flush
time and careful "which color wins" semantics for overlapping records
with different colors.

Recommendation: **A first, B as a stretch.** A is the structural change
(flush model); B is an internal optimization within A's contract.

## Phase plan

### Phase 1 — Plumbing

`PaintAccumulator` type. Per `ServerSession` instance (sessions don't
share backings). Methods: `add(topLevel:, rects:)`, `flush()`,
`flushTopLevel(_:)`. Owns a `[UInt32: [WindowBackgroundRect]]` dict
(top-level → ordered rect list, option A).

All `bridge.paintWindowRects(topLevel:, rects:)` callsites in
`ServerSession.swift` and `ShapeExtension.swift` route through the
accumulator instead. No behavior change yet because we flush at the
end of every handler (= same dispatch count, just routed differently).

Tests: refactor-style, behavior unchanged. 1262 stays green.

### Phase 2 — End-of-read-batch flush

`Listener.runAccepting` already loops on read. Add a hook at the end of
each "batch processed" iteration (right before the next `read()`
blocks) that calls `session.paintAccumulator.flush()`. Remove the
per-handler flush from phase 1.

Now multiple handlers in one read batch share one flush. xcalc resize
goes from ~120 dispatches to (in the best case) ~1 dispatch per
top-level per batch.

Tests: capture-replay tests verify final-state pixels match the
pre-refactor version. Reuse `2026-06-03T10-51-17-xcalc.xtap` as a
regression baseline.

### Phase 3 — Expose-time and read-time flushes

Add the other two flush points:

- Before each batch of Expose events emits, flush the affected
  top-level.
- In `validateDrawTarget` (or wherever `CopyArea`'s source resolves to
  a window), flush the source's top-level before the bridge's
  `readDrawablePixels` runs.
- Same for `GetImage` window source.

Tests: add a unit test for "fill then read" — `PolyFillRectangle` then
`GetImage` should see the fill, not pre-fill bitmap.

### Phase 4 — (Stretch) Dirty-region tree

Move from option A (op list) to option B (dirty region). Per-window
`damage: Region` accumulated. Flush walks parent-first, computes the
visible damage for each window (`window.damage ∩ window.clipList`),
emits one paint per window with the merged color/region. Drops paints
fully covered by later paints in the same flush.

Tests: pixel-perfect equivalence to phase 3 on the xcalc capture; ~3×
fewer fill ops at flush time.

### Phase 5 — Telemetry + STATUS

`PaintAccumulator` exposes counts: dispatches issued, rects coalesced,
flushes per second. Verbose log dump on `SIGINFO` or after each
top-level resize. Helps catch regressions.

Roll STATUS and update DECISIONS.md with the validate-style architecture
choice.

## Non-goals

- Damage as a public X protocol extension. The X `DAMAGE` extension is
  client-visible; this refactor is purely internal coalescing of our
  own paints.
- Cross-session damage merging. Each session paints into its own
  top-level windows; no shared accumulation.
- Per-pixel difference detection. Even option B operates on regions,
  not pixel diffs.
- Display-link / vsync alignment. Flush is request-driven, not
  refresh-driven. Could come later as a perf knob.
- Pixmap-target paint coalescing. Pixmap draws are already synchronous
  (no main async); leave them alone.

## Open questions

- **Where does the `PaintAccumulator` live?** `ServerSession` is the
  natural owner (it owns the bridge handle and the wire), but the
  end-of-read-batch flush is driven by `Listener.runAccepting`, which
  doesn't know about `ServerSession`. May need a small hook /
  per-session "batch end" callback.
- **Does `ClearArea` need to flush before its own fill?** Probably not
  — the fill IS the paint, no read-back. But worth pinning in tests.
- **What about the `Configure-time paintRectsForWindow` block in
  handleConfigureWindow?** With damage tracking it gets coalesced with
  the subsequent ShapeMask paints automatically — the dual-rep
  patches we deleted in DEVICE_COORDS_REFACTOR.md phase 6 are NOT
  reintroduced; they're subsumed by the flush model.
- **MapTopLevel timing.** Today `mappedBackgroundPaints` runs on
  initial map and dispatches a paint immediately. Under damage
  accumulation it'd queue and flush at batch-end. Need to make sure
  the NSWindow shows up with its first paint already applied (or at
  worst, with a one-frame delay).
- **Bridge protocol changes?** Minimal — `paintWindowRects` stays as
  the bridge entry point; only the call site changes (now invoked by
  flush, not handlers directly).

## Done condition

- xcalc resize on the Sun box: visibly faster (target 3-4× on the
  obvious cycle-count, validated with timestamps in the bridge log).
- 1262 tests green, plus a new flush-ordering regression test.
- Capture-replay against
  `/tmp/swift-x-captures/2026-06-03T10-51-17-xcalc.xtap` produces
  identical final pixels to pre-refactor (verified via reading the
  bitmap into a test).
- STATUS.md + DECISIONS.md rolled.
- The 2026-06-03 "Cheap follow-up: skip Configure-time
  paintRectsForWindow for shaped windows" idea is **rejected as
  superseded** — the damage flush subsumes it without needing the
  shape-specific special-case.

## Risk

- **Mid-batch reads.** If a handler reads the bitmap mid-batch and we
  forget to flush, it sees stale data. Mitigation: lint the
  bitmap-read call sites + a test that does PolyFillRect followed by
  GetImage in the same batch.
- **Dropped Exposes.** If we flush after Expose instead of before, the
  client sees its draw target empty. Mitigation: flush is a
  pre-condition for Expose emit.
- **Visual stutter on slow operations.** If a multi-second handler
  doesn't flush mid-stream, the user sees no progress. Mitigation:
  none of our handlers should be multi-second; if any are, we have a
  different problem to fix.
- **The dual-representation pattern returning.** Damage accumulation
  could theoretically grow into its own parallel state. Mitigation:
  the flush MUST go through `paintWindowRects` and the existing
  device-coord pipeline — no new bridge entry points, no new state
  fields beyond the accumulator dict.

## Sizing

- Phase 1: 300-500 lines (accumulator + plumbing). Half a day.
- Phase 2: 100 lines (flush hook + remove per-handler flushes). 1-2
  hours.
- Phase 3: 100-200 lines (flush points + tests). Half a day.
- Phase 4 (stretch): 500-800 lines (region merging + tests). Day plus.
- Phase 5: 100 lines + status doc. 1-2 hours.

Total without stretch: ~1.5 days. With stretch: ~3 days.
