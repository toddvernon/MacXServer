# Status 2026-06-03 (end of day, second update)

Three landings today, all in the "make the server feel right across
multiple sessions" bucket. The xcalc paint-region investigation from
earlier this morning is in the previous status snapshot (now in
git log, commit `168193a`); today's afternoon work is below.

## What landed

### `9e2df18` -- xeyes tracks across sessions + over Motif frame chrome

Root cause: each `ServerSession` had a per-session `lastPointerXY` that
only updated from mouseMoved events on that session's own NSWindows.
xeyes (or any XQueryPointer poller) saw stale coords whenever the cursor
crossed into a different session's window or our Motif frame chrome.

Fix: server-global pointer cache on `CocoaWindowBridge` (it's already a
per-process singleton). All sessions push X-root coords to it on every
pointer-update path; `QueryPointer` reads from it. Added `mouseMoved` +
an active-always tracking area to `MotifFrameView` so the cursor stays
tracked while it's over frame chrome on the same NSWindow.

Caught a subtle bug while wiring it up: out-of-bounds frame-chrome
events would have triggered a spurious EnterNotify on the top-level
(FlippedXView's mouseExited had already cleared `currentPointerWindow`).
Added a bounds guard in `handlePointerMoved` that runs *after* the
global-cache update but *before* the deepestMappedWindow walk.

Pre-existing limitation kept: cursor over third-party Mac windows while
our server is foreground still freezes the cache. That one needs a
CGEventTap / accessibility hook, out of scope.

### `d246604` -- composite chrome thinning replaces per-dialog enumeration

The seed for `~/.swiftx-resources` used to enumerate ~30 dt-app dialog
instance names (Dtcalc*rframe*, Dtcalc*frframe*, Dtterm*terminal*,
Dtpad*Warn*, ...) and set shadowThickness / highlightThickness /
defaultButtonShadowThickness to 1 on each. Collapsed to 12 global
`*XmPushButton.shadowThickness: 1`-style rules. Safe against quickplot
because XtSetArg pins in its own source (about_dialog.c:178,
legend_dialog.c:483) win over Xrm regardless of rule specificity.

Also added `*XmPushButton.borderWidth: 1` to mirror what quickplot
does per-button via XtSetArg in dialog.c:738-755, and deliberately
left `defaultButtonShadowThickness` unset:

  - Quickplot's Form-based dialogs: dbst=0 -> no BulletinBoard machinery
    fires -> default button has no separate ring, just the bevel.
  - dt-apps (XmTemplateDialog / XmMessageBox / XmDialog, BulletinBoard
    derivatives): BulletinBoard auto-sets dbst > 0 via
    ShowAsDefault(DEFAULT_READY), which triggers AdjustHighLightThickness
    silently inflating highlight_thickness by Xm3D_ENHANCE_PIXEL (= 2,
    hardcoded in `reference/motif/lib/Xm/XmP.h:161`). That's the 2-px
    "trough" we see on dtterm's OK button between the button bevel and
    the default-button ring. Tried setting dbst=1 in Xrm directly to
    bypass the auto-inflation (Motif source suggested it would); the
    inflation didn't budge. Documented as a Motif-level artifact we
    accept.

Net effect on the seed: ~290 lines of per-dialog enumeration collapse
to 12 global rules. Tests for the load-bearing fontList rules (Helvetica
class set, Courier for Dtpad) still pass; 1262 tests green.

### `a0d0612` -- launcher seed docs `$HOME` vs `~` gotcha

Live debugging: u5 launcher for quickplot was failing with
`~/dev/quickplot/quickplot`. Cause: we force `/bin/sh -c` on the remote
side, and `/bin/sh` on a vintage Sun is often the original Bourne shell
which doesn't do tilde expansion (POSIX feature added later). The user's
interactive csh/ksh login handled `~` fine; `/bin/sh` didn't. Fix in
the launcher file is `$HOME/dev/quickplot/quickplot` (variable expansion
works in every shell back to v7). Documented in the seed comment along
with the single-quote-breaks-the-wrapper warning.

## Carrying forward

- AllocColor pixel-value drift on cross-session replay (still parked).
- xmmap blit-on-move (Step F).
- Preferences Display Size radio (Auto / Comfortable / Compact)
  shipped 2026-06-02 -- still wants live Sun-box validation.
- Cursor over third-party Mac windows while server is foreground:
  needs CGEventTap or accessibility hook. Low priority; the in-session
  + Motif-frame coverage we shipped today handles every case where
  it actually matters for X-client tracking.
- dt-app default-button trough is now documented as a Motif-internal
  artifact. If we ever want to truly fix it, the answer lives in
  Motif's AdjustHighLightThickness (PushBG.c:2857); would require
  patching/replacing Motif's default-button setup machinery, not Xrm.
- Bigger picture: today validated the silent-lie-audit recipe
  (memory `feedback_silent_lie_audit_recipe`) -- the server-global
  pointer cache was a "hidden lie" via stale per-session cache; the
  user noticed the wrong behavior in xeyes and we traced it cleanly.

## What today's afternoon investigation cost

About a session on the Motif default-button ring/trough analysis,
reading PushBG.c / BBUtil.c / BulletinB.c carefully before realizing
the trough is a Motif-internal hardcoded constant. The investigation
was worth the time: now documented in the resources seed so future-me
doesn't try the same dbst-via-Xrm experiment again.
