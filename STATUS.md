# Status 2026-06-02 (end of day)

Layer 2 of the scale picker shipped: Preferences > Display now exposes the
size choice as a UI control, so the CLI `--scale {2,3}` flag isn't the
only way to land at 2x. SCALE_PICKER.md called this out as the natural
next step after yesterday's "kind of OK, not jarring" read.

## What landed

A three-way radio in Preferences > Display:

- **Auto — picks best size for display.** Defers to the picker (today
  that prefers 3x). Default for fresh installs.
- **Comfortable — window size parity with Mac (3×).**
- **Compact — slightly smaller windows (2×).**

Backed by a new UserDefaults key `display.scale` ("auto" / "comfortable"
/ "compact"). Read once at server startup via a transient `Preferences()`
instance, mapped to a `forcedScale: Double?` and passed into
`DisplayConfig.forMainDisplay(forcedScale:)` the same way the CLI flag
does. CLI still wins for the process when present; without it, the
preference applies. Restart-the-server contract unchanged.

Display tab also got a small layout pass: panel header relabelled from
"Window Frame" to "Display" (it now covers both Display Size and the
existing Window Frame controls), trailing `Spacer()` changed to
`Spacer(minLength: 16)` so when the content fills the dialog the bottom
description doesn't sit flush against the edge.

## Files touched

- `Sources/SwiftXServer/Preferences.swift` — new `displayScale`
  accessor, `DisplayScalePreference` enum with `.auto/.comfortable/.compact`
  cases and a `forcedScale` mapping.
- `Sources/SwiftXServer/ServerEntry.swift` — `forcedScale = CLI ??
  Preferences().displayScale.forcedScale`. `--help` updated to note
  the precedence.
- `Sources/SwiftXServer/PreferencesPanelView.swift` — Display tab
  restructured; new `@Published displayScale` on the panel model.
- `MacXServer.xcodeproj` — `xcodegen generate` ran clean (no tracked
  changes since no new files).

Build green, 1253 tests pass.

## What I didn't verify

I didn't launch the app and eyeball the Preferences panel myself. The
labels and the bottom-padding fix came from Todd's feedback in the
session; the panel needs a real visual check next time the laptop is
in front of someone. The three-way radio plus the existing Window Frame
section plus the Motif Resources block makes the Display tab the densest
one in the dialog; if it overflows on a small window, it'll want a
`ScrollView` wrapper, but I'd rather see that on screen before adding
one speculatively.

## Carrying forward

The Sun-box validation pass from yesterday's STATUS is still open:
launch real quickplot from u5 against `macxserver` set to Compact (or
`--scale 2`) on the laptop, confirm the command window USPosition
(30, 260) fits at 1280×900. The new control just changes the way you
opt in, not the underlying picker behavior, so yesterday's test plan
applies as written. After that, the open question from yesterday
("promote to Preferences UI or revert?") is half-answered: the UI is
in. The other half — keep or revert — still needs the live look.

The orthogonal AllocColor pixel-value drift on cross-session replay is
still parked. Same status as yesterday.

The xmmap blit-on-move (Step F) is also still on the back burner.
