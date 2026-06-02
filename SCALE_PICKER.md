# Display scale picker

A tiny opt-in: let the user pick 2x instead of the default 3x, mostly for SunOS-era apps that assume a 1280×900 screen. Default behavior unchanged. Off-ramp easy: one CLI flag, one commit to revert.

This is the realized form of "Phase 2: Selectable integer scale" from `SERVER_RESOLUTION_SCALING_AND_FONTS.md`, with concrete design choices made.

## What the user picks

One choice at server startup: the scale at which X content renders. Two values:

- **3x (default).** Today's behavior, unchanged. Picker chooses the largest preset logical-root that fits at 3x. Studio Display picks 1280×900. 14" MBP picks 1008×648.
- **2x (opt-in).** Picker re-runs at scale=2, choosing the largest preset logical-root that fits at the new scale. Studio Display picks 1280×900 (same as 3x). 14" MBP picks 1280×900 (instead of 1008×648), because at 2x that combination fits the display.

If there's ever a Preferences UI for this, the user-facing language should be "Comfortable" (3x) and "Compact" (2x), not the engineer-facing "1x/2x/3x." For now the lever is CLI-only.

## Why 2x exists

Two reasons, both worth knowing:

1. **Smaller X content relative to Mac UI.** At 3x the X content feels a touch larger than native Mac controls. At 2x it feels a touch smaller. Some users will prefer one, some the other. Not a "right answer" question.
2. **SunOS apps fit the screen room they were designed for.** Quickplot, dt-apps, and similar SunOS-era Motif apps assume a 1152×900-ish screen and place windows accordingly. The 3x picker on a 14" MBP gives them 1008×648, which is smaller than their assumptions. Apps use `WM_NORMAL_HINTS USPosition` to place windows that go off the bottom. The 2x picker on the same display gives them 1280×900, which is what they expected. Their placement works without WM-emulation clamping.

The second reason matters even for users who'd otherwise prefer 3x. On constrained displays (laptops), 2x is the path that makes Sun apps work the way they were designed to.

Concrete example from `/tmp/swift-x-captures/2026-05-30T13-05-57-qp.xtap`: quickplot's command window is `CreateWindow 430x500 at (30,260) WM_NAME="Command Window"` with `USPosition=(30,260) USSize=430x500`. Bottom edge at y=760. Fits in a 900-tall root, doesn't fit in a 648-tall root.

## Why no 1x option

Skipped. On a Retina laptop, 1x would produce a 215×250-point command window with a 6pt title font and an X content area too small to use. No audience.

For non-Retina displays the picker already falls back to 1x at native logical dimensions when neither 2x nor 3x fit. No CLI lever needed for that path.

## Motif frame auto-scales

When scaleFactor changes, the Motif frame's chrome scales with it. Concretely:

```swift
let chromeScale = displayConfig.scale / 3.0
var theme = MotifTheme.fromResourceFile(loadedSettings)
theme.titleBarHeight *= chromeScale
theme.bevelWidth *= chromeScale
theme.frameWidth *= chromeScale
MotifTheme.install(theme)
```

At 2x, the 32pt baseline title bar becomes ~21pt, the 2pt bevel becomes ~1.3pt. All derived dimensions (button size, title font size, menu glyph sizes) follow because they're computed from these three primitives.

`Mwm*titleBarHeight` etc. in `~/.swiftx-resources` still wins. Order of operations: read resource file, apply base theme, then scale. Explicit user overrides override the scaling.

Title font size floor remains `max(9, titleBarHeight * 0.55)`, which prevents pathological-tiny text if someone constructs a weird theme.

## Native NSWindow chrome stays 28pt

We don't scale Mac chrome. We can't, cleanly. macOS gives one fixed title-bar height for regular NSWindow. The NSPanel utility-style alternative comes with behavioral baggage (floating level, hides on deactivate, Mission Control treatment, Cmd-\` window cycling) that we're not willing to fight, and is documented in the planning conversation that produced this spec.

The honest consequence: native mode at 2x looks slightly off. A 28pt title bar sits over ~33% smaller content than at 3x, so the chrome is proportionally chunkier. We ship it that way. Users who care about the look at 2x will switch to Motif mode; users who don't will stay on native.

This pairing also generates the "should we ditch native mode?" signal over time. If 2x usage correlates with Motif mode, that's the indication that native chrome can go.

## CLI surface

One flag on `macxserver`:

```
--scale {2,3}
```

Default (omit the flag): picker behaves exactly as today (prefers 3x, falls back to 2x or 1x where 3x doesn't fit).

Explicit `--scale 2`: re-pick at scale=2 regardless of whether 3x would have fit. If no preset logical-root fits at scale=2 (very small displays), error out with a clear message; do not silently fall back.

Explicit `--scale 3`: same as default behavior. Included for symmetry and explicitness in scripts.

No `--logical-root` flag in v1. Defer until a real need surfaces.

## Implementation

Three changes, ~50 lines total plus tests:

1. **`DisplayConfig.pick`**: add an optional `forcedScale: Double?` parameter. When set, skip the scale-candidate loop and use only that value. Existing zero-arg path unchanged.

2. **`ServerEntry`**: parse `--scale` from CommandLine. Pass the value to `DisplayConfig.forMainDisplay(forcedScale:)` (also new). After getting back the chosen displayConfig, compute the scaled MotifTheme and install it before the bridge is built.

3. **Tests**: extend `DisplayConfigTests` with cases for `forcedScale: 2` on each preset display dimension. Verify the picker chooses the expected logical-root or surfaces an error when no preset fits.

No changes to:

- `CocoaWindowBridge`. It reads `scaleFactor` from its init parameter; doesn't care where that came from.
- `MotifFrameView`. It reads `MotifTheme.current` on every draw; auto-picks up the scaled theme.
- `ResourceTables`, `PixelBuffer`, anything else holding scaleFactor as `let`. They're all initialized from the chosen displayConfig.
- The resource file loader. Order of operations is documented (load resources, then apply scale) but no API change.

## What's out of scope

- **Preferences UI.** Add when ship decision is made.
- **Live restart-on-change.** Restart-the-server is the contract.
- **Fractional scales.** Phase 3 of the original doc; separate feature if ever pursued.
- **Per-display scale.** Phase 4 polish.
- **`--logical-root` override.** Defer until needed.
- **XRandR fake-resize notifications.** Not needed for restart-the-server model.

## Test plan

Two machines, two chrome modes, two scales, two test apps. Eight launches total.

| Machine | Chrome | Scale | Test app | Looking for |
|---|---|---|---|---|
| Studio Display | native | 3x | xclock | Baseline; no regression vs today. |
| Studio Display | native | 2x | xclock | Chunky chrome confirmation, no other regressions. |
| Studio Display | Motif | 3x | xclock | Baseline. |
| Studio Display | Motif | 2x | xclock | Proportional chrome, sharp text. |
| 14" MBP | native | 3x | quickplot | Confirms the placement bug (command window off bottom). |
| 14" MBP | native | 2x | quickplot | Command window fits at 1280×900 root. Chunky chrome. |
| 14" MBP | Motif | 3x | quickplot | Placement bug still present (logical-root same as native@3x). |
| 14" MBP | Motif | 2x | quickplot | Placement works. Chrome proportional. The "shipped form" of the feature. |

Pass criteria: every launch produces a window with intelligible text and no visual artifacts (other than the known chunky-chrome case in native@2x). No new console warnings. Quickplot's command window position matches its USPosition in the 2x cases.

The 14"-MBP-native-3x → 14"-MBP-native-2x pair is the diagnostic pair: it confirms the SunOS-app-fits framing from the "Why 2x exists" section above.

## Done condition

CLI flag works. Motif theme scales. Tests green. Eight launches in the test grid above complete without surprises. If the test pass surfaces something unexpected, file it as its own ticket rather than blocking this commit.

If the feature feels not-worth-shipping after using it for a week, revert is one commit. If it feels worth shipping, the next step is the Preferences UI (Layer 2 from the planning conversation), which is straightforward wiring on top of the foundation this lays.
