# Motif input dispatch — open investigation

Last touched 2026-05-09. Dropped here so the next session can pick up cold.

## Headline

quickplot from SS2 (and probably any older Motif app) renders correctly on swift-x but **clicks don't fire callbacks**. The X protocol path is verified clean — events reach the right widget, byte format matches what xev / a real Sun X server expect. The failure is somewhere inside Motif's translation manager.

## What's verified working

- xev tested: ButtonPress/Release/KeyPress format is textbook correct (state, time, button, keycode, keysym → XLookupString → "a"). Same wire bytes Motif sees.
- xcalc (Athena widgets) is fully functional — clicks, button highlights, math operations all work.
- xterm renders, scrolls, resizes, accepts keyboard input, ANSI colors, Cmd-C/V copy roundtrip.
- xclock, xeyes (less SHAPE-eyes themselves), xfontsel — all render or work as expected.
- quickplot renders all top-levels, mouse hover triggers EnterNotify/LeaveNotify chain correctly per X spec, focus events fire on top-level activation.
- Capture proxy (post-2026-05-09 fix) is now transparent; no longer a confounder.

## What's broken

- quickplot: every widget click delivers Press+Release to the correct window (verified in capture trace) but quickplot issues **zero subsequent X protocol requests** in response. Compare to gold (Sun→Sun via proxy) where the same click triggers `GrabKeyboard` + focus shuffle + drawing requests immediately.
- dtcalc, dtterm, dtmail, dtfile (CDE Motif): some don't even render, presumed CDE resource-file dependencies missing on local Solaris install.
- dtpad never displays (against u5 gold either — install issue, not our problem).

## What's special about the failure

- Motif IS alive after the click — Enter/Leave events keep firing for hover, the app remains responsive to mouse position.
- Motif just doesn't trigger any *action* on Btn1Down/Btn1Up.
- This means the dispatch reaches Motif's `XtDispatchEvent` but the translation table either has no matching entry or the matched action no-ops.
- It's NOT a focus-stealing issue — focus is on the right top-level at click time per the capture.

## Strongest hypotheses, ranked

1. **Pre-click focus bounce** — at app startup we emit FocusIn(0x4400118) → FocusOut(0x4400118) → FocusIn(0x4400053) within ~40ms because macOS activates the second NSWindow then the first as both come up. Gold has just one FocusIn(0x4400053). Motif may have a state machine that gets confused by the bounce and never re-arms its dispatcher even though focus settles correctly.
   - **Test:** debounce focus events at the bridge level — only emit FocusIn/Out for the *final* state if multiple key/resign-key events fire within e.g. 100ms.

2. **Missing focus-chain emission per X spec** — when X-protocol focus moves to a window with the pointer inside, the spec says emit `FocusOut` + `FocusIn` events with `detail=pointer` along the pointer-to-focus path. We only emit a single `nonlinear` event on the top-level. Xt's internal focus dispatcher may be waiting for the chain.
   - **Test:** add the "pointer detail" focus chain emission in `handleFocusChange`. Match what gold's server emits when activating a window.

3. **Missing `XQueryPointer` reply** — Motif's `XmManagerGadgetArm()` and similar dispatch functions may call XQueryPointer to refine which gadget the click hit (gadgets share the parent's window so the X server can't dispatch to them directly). We silent-drop XQueryPointer.
   - **Test:** implement a basic XQueryPointer reply that returns the current pointer position + the pointer-window. Likely small, ~30 lines.

4. **`ManagerGadgetArm` translation needs an XAutomatic field** — Sun-era Motif may have action procs that depend on Xt's `event_handler` chain, which depends on XSendEvent or similar we don't fully wire.

5. **Translation-table compilation silent failure** — even after our keysym work, some specific keysym / virtual binding lookup might still fail and reject part of the table. Hard to verify without Xt-side tracing.

## Captures available for diffing

`captures/` has clean (post-recorder-fix) pairs for several apps:

| App | Gold (Sun→Sun) | Swift-x | Status |
|---|---|---|---|
| quickplot | `quickplot-sun.xtap` | `quickplot-swiftx.xtap` | Renders, no input |
| dtcalc | `dtcalc-sun.xtap` | (need new capture, old one broken) | TBD |
| dtterm | `dtterm-sun.xtap` | (need new capture) | TBD |
| dthelpview | `dthelpview-sun.xtap` | (need new capture) | TBD |
| xfontsel | `xfontsel-sun.xtap` | (need new capture) | TBD |
| xeyes | `xeyes-sun.xtap` | `xeyes-swiftx.xtap` | Window appears, eyes don't (SHAPE missing) |

**Re-capture the swift-x side for any app you want to diff** — the older `*-swiftx.xtap` files were taken before the recorder I/O fix and contain artifacts from that bug.

## Tools

- `.build/release/swiftx-capture dump <path>` — chronological per-message dump
- `.build/release/swiftx-capture summary <path>` — aggregate counts
- `.build/release/swiftx-capture replay <path>` — fire C2S bytes at a target server (could replay broken sequence to a fresh swift-x to reproduce deterministically)
- `./run-all.sh` — builds + runs swift-x + capture proxy in front
- `./run-server.sh` — server-only, no capture (for direct connection testing)

## Known good debugging method

For any new failure mode:
1. Capture the broken pair (Sun→swiftx).
2. Find the gold (Sun→Sun) capture of the same app.
3. `dump` both, find the first protocol divergence.
4. Look for either: a server reply we got wrong, or a request we silent-drop.

The capture+diff method has now found and fixed several bugs this session. It's the right tool.

## Useful prior-session clues

- "Cannot convert string `<Key>KP_Insert` to type VirtualBinding" stderr was the smoking gun for the keymap fix. Applying that pattern: any keysym-related stderr from a Motif app is worth following.
- SS2 (older Motif) is *more strict* about protocol than SS5 (newer Motif). Use SS2 as the witness whenever possible.
- Recorder I/O can confound results — verify the capture proxy isn't lying by re-running with `output: "/dev/null"` (skips recording entirely) if a hang or crash seems proxy-related.

## What to NOT do

- Don't try to implement full Motif drag-and-drop coordination unless something specifically depends on it. The pre-set `_MOTIF_DRAG_WINDOW` workaround is enough to dodge the SS2 init segfault.
- Don't add keysyms speculatively unless a specific stderr warning identifies one.
- Don't rebuild the proxy / capture format. The on-disk `.xtap` format is stable.
