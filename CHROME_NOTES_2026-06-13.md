# Motif chrome tuning — notes from a failed first attempt (2026-06-13)

Tried to slim down the Motif window-manager frame at 3x scale. Made
things worse. Reverted. Notes for the next attempt.

## What we tried

1. Per-scale chrome multipliers (`titleScale = 0.70`, `edgeScale = 0.5`
   at scale=3) in `ServerEntry.run`. Goal: shrink the 3x defaults to
   feel closer to native Mac chrome.

2. Same multipliers duplicated in `ServerSession.setupResourceManagerProperty`
   (the post-resource-file install path).

3. `titleBarRect()` extended to fill corners when buttons are hidden
   via `_MOTIF_WM_HINTS`.

4. `raisedTileCentered` floor()'d its offsets to avoid half-pixel blur.

## What went wrong

- **Resource-file values got auto-scaled.** Todd's
  `~/.macxserver-resources` has explicit values
  (`Mwm*titleBarHeight: 32`, etc.). My code multiplied those user-set
  values by 0.70/0.5, shrinking what the user explicitly wanted to be
  the default. The right behavior: resource-file values are
  authoritative; only auto-scale when falling back to in-code defaults.

- **Per-field "did the user set it?" check is fragile.** Tried checking
  `frameSettings["Mwm*titleBarHeight"] == nil` to decide whether to
  scale. Works in principle but easy to forget when adding new
  resource keys.

- **Dialog title bars got worse.** Two issues compounded:
  (a) `titleBarRect()` carve-out for hidden buttons leaves chunks of
      empty chrome at the corners on dialogs that use
      `_MOTIF_WM_HINTS` to hide menu/min/max (quickplot's About,
      Question dialog, Quit dialog).
  (b) The auto-shrink + the carve-out together produced visibly
      broken chrome where buttons were missing AND the title band was
      smaller than expected.

- **Two MotifTheme install paths with duplicated scaling formula.**
  `ServerEntry.run` does one install (from defaults, scaled).
  `ServerSession.setupResourceManagerProperty` does a second (from
  resource file, scaled with the same formula). They have to agree or
  the resource path silently overrides startup. Code smell — should
  be factored into one helper that takes (theme, scale) and returns
  the scaled theme.

- **Existing windows don't pick up theme changes.** Motif chrome is
  baked at NSWindow create time. Old open windows kept the old
  chrome; only newly-mapped top-levels showed the new sizing. Made
  debugging confusing because it looked like the change wasn't
  applying when it actually was — just only to the new windows.

## Things worth keeping from the attempt

- **`raisedTileCentered` floor() the offsets.** Half-pixel offsets
  rasterise blurry — straightforward bug, low-risk fix. Worth keeping
  even after reverting the rest. (`round(titleBarHeight * 0.64)` can
  produce parity mismatches with the button rect; floor() locks the
  icon to integer pixels regardless.)

- **`titleBarRect()` should honor hidden-button decorations.** When
  `_MOTIF_WM_HINTS` hides menu/min/max, the title bar should span the
  area those buttons would occupy instead of carving out empty
  corners. Real bug, real fix; do it cleanly next time.

## Recommended next-attempt approach

1. **Don't auto-scale resource-file values.** If user pinned a value
   in `~/.macxserver-resources`, treat that value as authoritative —
   no multiplier, no scale-aware shrink. Auto-scale only applies to
   the in-code `MotifTheme.default` fallback path.

2. **Factor the scaling into a single helper.** Something like
   `MotifTheme.scaledForDisplay(_ scale: Double) -> MotifTheme` so
   `ServerEntry` and `ServerSession` can't drift apart.

3. **Fix the title-bar carve-out first, in isolation.** That's a
   real bug independent of any size tuning. Land it as its own
   commit with a test (snapshot or geometry assertion).

4. **THEN tune sizes if needed.** And only via the resource file
   if Todd wants a specific look — don't bake new numbers into the
   in-code defaults.

5. **Tell the user "close existing windows and reopen" when testing
   chrome changes.** Otherwise the comparison is misleading.

## State of the tree

Reverted three files via `git checkout`:
- `Sources/SwiftXServer/ServerEntry.swift`
- `Sources/SwiftXServerCore/MotifFrame/MotifFrameView.swift`
- `Sources/SwiftXServerCore/ServerSession.swift`

Last committed state (`87caf85` = STATUS roll for v0.9.3) is what's
shipping. The Motif chrome at 3x is the original "32-point title,
2-point bevel + frame" sized for unscaled defaults. Todd's resource
file overrides are honored as-written by the existing code.
