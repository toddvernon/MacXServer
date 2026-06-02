# Status 2026-06-01 (end of day)

Two pushes today: xmmap Expose analysis in the morning (kept in git, see
commit 04873d5 for the detailed write-up), and a `--scale 2` opt-in
feature in the afternoon-evening. The scale-picker feature is the
operative thread for the next session.

## Scale picker — shipped, awaiting Sun-box validation

`--scale {2,3}` CLI flag on macxserver. Default unchanged (picker still
prefers 3x). `--scale 2` re-picks the logical-root via the existing
preset table at scale=2, which on a 14"/16" MBP lands at 1280×900 (the
Sun-authentic size SunOS-era Motif apps assume) instead of the 3x
picker's 1008×648 or 1280×720. Motif frame chrome auto-scales by
`scaleFactor/3` with integer-point snap so bevels stay crisp at any
backingScale. Native NSWindow chrome stays 28pt (no public AppKit API
to scale it; the cost is honest).

Two commits on main:
- `4b11510` — the hack version (CLI flag + scaling, no polish)
- `43934f7` — spec'd polish (integer-point snap on Motif dims, 5 new
  tests for forcedScale, removed phantom pixmap-Lanczos item from spec
  because nearest-neighbor was already in place)

1253 tests green. SCALE_PICKER.md documents the design and known
orthogonal issues. Revert path is one commit (or two) on the `4b11510`
ancestor.

Visual evaluation on the 16" MBP with `xterm` and `quickplot` replays
side-by-side (2x on :0, 3x on :1): Todd's read is "kind of OK, not as
jarring as expected" — which is the read this feature has bailed on
twice before for being too jarring on paper. The aesthetic worry that
killed prior attempts didn't survive seeing it run.

### What still needs validation

The functional argument for the feature ("quickplot's USPosition fits
at 1280×900 root, doesn't at 1008×648 / 1280×720") is currently
unverified against live quickplot — we tested with the captured replay
from `/tmp/swift-x-captures/2026-05-30T13-05-57-qp.xtap`, which proves
the math but not the live behavior. Sun-box test tomorrow with real
quickplot from u5 closes that.

### Open decision

After tomorrow's Sun-box test, two paths:

- **Promote to Preferences UI (Layer 2).** SCALE_PICKER.md describes
  it: a "Display: Comfortable / Compact" toggle plus the existing
  Motif-frame toggle. Straightforward wiring; ~1 hour.
- **Revert and move on.** Two commits, one revert each. Spec and
  memory stay in git history for the next time the topic surfaces.

## Orthogonal issue surfaced today (not addressed)

`AllocColor` pixel-value drift on cross-session replay. Replaying a
swiftx-captured `.xtap` against a fresh swiftx server can produce
wrong colors because our PseudoColor allocator may return different
pixel values than the original session did, while the captured
drawing bytes still reference the originals. Visible when comparing
quickplot replays today. Pre-existing issue documented in DECISIONS
as "stateful translation needed for cross-server replay." Not
specific to the scale picker.

If we want capture-based regression testing to work cleanly, this
needs to be addressed eventually. Not urgent — same-server replay
(SunOS→SunOS) already works fine; the issue only bites when
swiftx→swiftx replay is the testing strategy.

## Carrying forward from this morning

xmmap Expose over-emit is still the open architectural thread from
this morning's investigation. R6 source reveals the over-emit is a
*workaround* for a missing `CopyWindow` blit, not a bug. The
"tighten the Expose to newly-revealed region" approach was reverted
(b09640d) because without the blit, it leaves stale content in the
intersection region. Real fix is the blit-on-move pipeline (Step F
in the ledger). Not yet attempted; deferred.

ss2 app status memo (`project_ss2_app_status.md`) remains the ground
truth for per-app status. STALE-stamped memos for quickplot, dt-apps,
and dthelpview are accurate on architectural lessons, not on current
behavior — pending u5 recapture.

## For next session

1. **Sun-box validation pass for `--scale 2`.** Launch real quickplot
   from u5 against `macxserver --scale 2` on the laptop. Confirm:
   - Command Window at USPosition (30, 260) fits on screen instead of
     going off the bottom
   - Other dt-apps and Motif apps render at appropriate sizes
   - Motif chrome bevels look crisp (not muddy) at the integer-snapped
     21pt title bar
   - No new console warnings or rendering glitches vs 3x
2. **Decide on Layer 2 (Preferences UI) or revert.**
3. **Optionally re-attempt the xmmap blit-on-move (Step F).** Separate
   thread; pick up the morning's investigation when ready.

Memory has fresh entries for the +0.5 offset analysis (which we
re-derived today after I couldn't recall a prior session's claim).
No new feedback memories to log; Todd's "kind of OK, not jarring" read
was the operative signal of the day.
