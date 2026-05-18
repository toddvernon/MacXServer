# What to do this week

Working doc for a week away from the vintage workstation collection. No u5, no SS2, no live X clients to test against. The whole point of this is: figure out which work on swift-x is actually doable (and meaningful) without live-hardware verification, and which work is risky to attempt blind.

The short version: foundation + tooling. Don't touch anything that needs "does it look right on screen" to know if you're done.

## Tier 1: foundation work, fully unit-testable

### 1. Region-based visibility tracking

The big one. Implement proper per-window visible-region tracking so the server can decide what Expose events to emit, what pixels to preserve under moved descendants, when to emit `VisibilityNotify`, and what `GraphicsExpose` vs `NoExpose` to emit after CopyArea.

**Why this matters.** It's the foundation that unblocks several open issues at once: dt-Motif button chrome (parked 2026-05-10), the quickplot idle 6-request poll loop, stale-pixels-under-moved-descendants, the GraphicsExpose path being permanently "NoExpose" today. Without it, every Motif-style cosmetic bug becomes its own special case.

**How to start.** Read `reference/X11R6/xc/programs/Xserver/mi/miexpose.c` and `mivaltree.c`. The X.org implementation is the reference. The data structure is a "region" = list of non-overlapping rectangles, with a small algebra (union, intersect, subtract). Port the algorithms; don't have to follow the X.org code structure literally.

**Test cases that don't need live hardware.**
- Window A at (0,0) 100×100; window B at (10,10) 50×50 child of A and mapped. A's visible region = original rect minus B's rect.
- Window A at (0,0) 100×100; sibling C at (50,0) 100×100, higher-stacked, mapped. A's visible region = A's rect minus C's rect (clipped to A).
- Window A at (0,0) 100×100; A unmapped, then mapped again. Expose region = A's full rect.
- Window A at (0,0) 100×100 with child B at (10,10) 50×50 already mapped; A maps. Expose region for A = A's rect minus B's rect. Expose region for B = B's full rect.

All of these are pure-Swift, pure-state, no AppKit or NSWindow needed. Write them as `RegionTests.swift` and `ExposeTests.swift`.

**Rough scope.** 2-4 sessions of focused work. Not a one-day thing.

**Pitfall.** The temptation will be to ship the region library without wiring it into the dispatcher. Don't. Land it incrementally: region library + tests, then plumb into MapWindow/UnmapWindow, then plumb into ConfigureWindow, then plumb into stacking changes. Each step should pass `swift test` cleanly before the next.

### 2. Backing-store advertise + Expose suppression

Smaller, complementary move. Advertise `backing-store = Always` in the screen attributes. Stop emitting Expose for region-uncovering events (a covered window appears above, a descendant moves away). Real first-paint Expose still happens.

**Why this matters.** Eliminates a category of correctness issues. We already de facto have backing-store at the NSWindow level since every top-level has a persistent CGContext. Aligns server behavior with the real Sun X server's pattern of "few Exposes."

**Doesn't fix dt-button chrome by itself.** That bug is upstream of visibility-change Exposes. Backing-store eliminates a class of unrelated bugs.

**Test against the corpus.** Replay every captured app via the existing replay tool. Should see no crashes, no behavior changes for things that worked before. The change is in what we DON'T emit, not what we do emit.

**Rough scope.** A day or so. Smaller than #1 and could be done alongside or before.

## Tier 2: tooling that multiplies the next live session

### 3. Capture-diff tool

Add a `swiftx-capture diff <gold> <swiftx>` subcommand that walks both `.xtap` streams in lockstep and reports differences: same sequence numbers seen, replies with different byte structures, requests in one stream not in the other, points where one stream stalls. Produce a markdown report by default.

**Why.** When something breaks on u5 next week, the current workflow is: take a gold capture, take a swiftx capture, write ad-hoc Python to compare. We did that twice on 2026-05-10. A real tool would have saved hours.

**Where to look.** `Sources/SwiftXCaptureCore/ChronoDumper.swift` already walks frames and decodes messages. The diff command would walk two simultaneously and compare. Output format: markdown table with seq / direction / message-type / "same" or "different" / first differing bytes.

**Rough scope.** A focused day. Pure Swift, no hardware.

### 4. Replay-based regression tests for every captured app

Existing pattern: `XclockReplayTests.swift`. Extend to one test file per captured app in `captures/`:
- `XcalcReplayTests.swift`
- `XtermReplayTests.swift`
- `XfontselReplayTests.swift`
- `QuickplotReplayTests.swift`
- `DtcalcReplayTests.swift`
- `DttermReplayTests.swift`
- `DthelpviewReplayTests.swift`
- `DticonReplayTests.swift`

Each test: load the gold `.xtap`, feed the C2S bytes through a fresh `ServerSession`, assert:
- No crashes
- No `unknownOpcodes` entries
- Expected resource counts (windows, GCs, fonts, atoms; eyeball from the dump)
- No XError-worthy conditions (once XErrors are real)

**Why.** Locks in current state. Next time we make a change like MATCH_SELECT, the test suite catches anything we broke. Also: when you DO get back to u5 and try a fix, you'll know immediately if it broke anything else.

**Doesn't replace live testing.** These tests don't tell you if rendering looks right. They tell you the protocol path is stable.

**Rough scope.** ~20 minutes per app. Half a day to do them all.

## Tier 3: tech debt with no testing dependency

### 5. XErrors emission

Real error replies for: unknown atom (BadAtom), bad window/drawable/gc/pixmap/font/cursor IDs (BadWindow/BadDrawable/BadGC/etc.), bad request length, bad enum values. Spec section 5 defines the format precisely: error code, sequence, bad value, minor opcode, major opcode.

**Why.** Currently we silent-drop or fake replies. Some clients hang because they expect an error and never see one. Others end up in inconsistent state. The "no XErrors emitted" SHORTCUT entry has been open since M3.

**Test infrastructure.** Easy. Feed a known-bad request, assert outbound contains the right error bytes.

**Rough scope.** 1-2 sessions. The framework is small but landing it requires touching every handler that currently silent-drops.

### 6. Selection-mediator refactor

The fake CDE daemon setup is currently inline in `ServerSession.init`: stub window registration, atom interning, property pre-population, ConvertSelection short-circuit. Pull it into a `SelectionMediator` class with a clean API:

```swift
public protocol SelectionMediator {
    func registerOwner(selection: UInt32, window: UInt32, ...)
    func handleConvertSelection(...) -> SelectionConversionResult
}
```

Two implementations:
- `RealClientSelectionMediator` (forwards SelectionRequest to actual client owners)
- `StubDaemonMediator` (impersonation pattern from today)

Then the ConvertSelection handler dispatches to whichever mediator owns the selection. Sets up real clipboard mediation, real drag-drop coordination, and the dt-app daemon impersonation as parallel use cases of the same machinery.

**Why.** Today's daemon-impersonation code is a wall of inline init that mixes concerns. A clean abstraction sets up the next round of selection work without locking in the hardcode.

**No behavior change.** Pure structural refactor. Existing tests should pass unchanged.

**Rough scope.** Half a day.

### 7. SHORTCUTS audit

Walk every open entry. For each, classify:
- "Cheap fix possible now without hardware" → do it
- "Needs hardware to verify" → leave it but add the verification plan to the entry
- "Wrong / stale / doesn't apply anymore" → close it

Some entries are 5-line code changes that just haven't been prioritized. The empty Closed section is a code smell: entries get added but rarely retired.

**Rough scope.** A focused half-day to walk + decide; cheap fixes might add up to another day.

## Tier 4: risky without verification

Don't do these. They look temptingly fast but you won't know if they worked until u5 is back.

- **VisibilityNotify emission for dt-button chrome.** Cheap to implement, but if it doesn't fix the bug there's no way to find out blind. Also the chance it introduces a subtle regression in a working client is real. Hold for live testing.
- **Menu placement fix.** Same: implement and verify visually in the same session, don't split.
- **Motif Text widget spacing.** Need to see the text rendering to know if it's right.
- **About-dialog animation clip rectangles.** Hooks into the GC clip plumbing (SHORTCUTS open item). Could be implemented, but the verification depends on seeing the animation.
- **Any palette adjustment.** The hardcoded CDE-Default palette in ColorTable is a guess. Tuning it without live feedback is just guessing harder.
- **Anything affecting input handling.** Easy to regress dragging, focus, click dispatch without noticing.

## Order I'd actually do them in

1. **Day 1**: backing-store advertise + Expose suppression (#2). Small win, ships.
2. **Day 1-2**: capture-diff tool (#3). Force multiplier for everything else.
3. **Day 2-3**: regression tests for every captured app (#4). Locks state.
4. **Day 3-7**: visibility tracking (#1). The big chunk. Probably the whole rest of the week.
5. **Fill-in / context-switch work**: XErrors (#5), selection mediator refactor (#6), SHORTCUTS audit (#7).

By the end of the week the project would have: a cleaner foundation (visibility tracking, backing-store), better tooling (capture diff), regression coverage that catches the next MATCH_SELECT-style mistake, and less tech debt (XErrors landed, mediator cleaner).

When u5 comes back, the first session is: capture quickplot fresh, run the diff tool against the gold, see what changed. Then tackle the deferred verification items (VisibilityNotify, menu placement, text spacing). The diff tool plus regression suite means the live-test session is targeted instead of exploratory.

## Hard rules

- **Capture before code on any new client problem.** This bit us on day 1 of dt-app investigation when we shipped `_MOTIF_WM_INFO` + `RESOURCE_MANAGER` speculatively and they didn't help. Should have captured first.
- **If you can't write a test that fails before your fix and passes after, don't ship the fix.** This rule alone keeps Tier 4 out of scope this week.
- **Don't add bandaids.** Reference memory entry: "don't fix opcodes one-at-a-time when a client breaks; sweep gaps systematically using reference/X11R6/." This week is about going the OTHER direction: foundation work that retires bandaids rather than adding them.
- **Every Tier 1-3 item should result in either deleted SHORTCUTS entries or new test coverage.** If neither, ask whether it was actually worth doing.
