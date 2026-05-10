# Motif / dt-app investigation — current status

Last touched 2026-05-10. dt-Motif apps now run; widget chrome redraw is parked.

## Headline (2026-05-10)

**CDE dt-apps boot, accept input, and render their primary widgets.** dtcalc, dtterm, dthelpview, dticon all launch from a u5 CDE session and display under swift-x. The LCD/text-display areas render correctly with the right colours. **Button rendering inside Motif panels is the remaining visual gap** — buttons exist as X resources, have correct geometry, and the panel bg paints correctly, but Motif's PushButton class doesn't fire its draw method (shadows + label) in response to our Expose flood. dt-apps are functional-but-cosmetically-incomplete.

dtpad doesn't launch — `no valid tooltalk client` from u5's CDE side, not our problem (needs `ttsession` running on the Sun).

**quickplot now works** as of 2026-05-10 (same evening). User confirmed widget callbacks fire, menus post, dialogs open, buttons respond, xlib plotting renders. The unlock was the same `MATCH_SELECT` time-preservation fix that got dt-apps booting — Xt's selection event match was silently dropping our SelectionNotify mid-dispatch any time the client used `CurrentTime`. Worth a fresh capture (u5→swiftx) + diff against gold as the first thing in any next round on Motif work, to confirm exactly which fixes mattered and lock the baseline. See `.claude-memory/project_motif_quickplot_status.md` for open cosmetic issues observed (menu placement, text spacing, idle poll loop, clip-rect animations).

## What was fixed today

Two bugs in series got dt-apps booting:

**1. CDE customization daemon impersonation.** Every CDE dt-app probes `Customize Data:N` at init. On a real Solaris install, `dtsession` owns this selection and publishes an `SDT Pixel Set` property containing the colour-palette pixel-index manifest. Without an owner, dt-apps fall to a formal `ConvertSelection` then wait for the conversion response. Our prior `SelectionNotify(property=None)` reply *should* have signalled "no data" per spec, but Solaris-Xt's "no daemon" path is apparently never tested in real installs (CDE always has dtsession running), so it wedges indefinitely after the None reply.

Fix: register a server-internal stub window (`0xFFFE_0003`) as owner of `Customize Data:0`, pre-publish the `SDT Pixel Set` property with byte-for-byte content captured from u5's real daemon, and short-circuit `ConvertSelection` requests on stub-owned selections by writing empty bytes to the requestor's property and emitting `SelectionNotify(property=success)`. See `DECISIONS.md` 2026-05-10 and `SHORTCUTS.md`.

**2. `SelectionNotify` time field preservation.** Even with the daemon impersonation in place, dt-apps still wedged after our SelectionNotify. Tracked to `reference/X11R6/xc/lib/Xt/SelectionI.h:165` `MATCH_SELECT` macro, which requires `event->time == info->time` — the SelectionNotify's `time` must equal the value Xt put in the corresponding `ConvertSelection` request. We were substituting `serverTime` when `r.time == 0` (correct for server-generated ButtonPress/KeyPress, wrong for ICCCM selection events). Xt's `HandleSelectionReplies` silently dropped our reply, so dtcalc never issued the followup GetProperty and waited forever.

Fix: pass `r.time` verbatim through both the no-owner and stub-owner SelectionNotify paths. General lesson: any X-protocol event generated *in response to* a client request must round-trip every echoed field unchanged.

**3. CDE-palette pre-seeding in ColorTable.** dt-apps use the SDT Pixel Set as a manifest of "already-allocated colormap pixels you can reference directly." With nothing seeded, `resolveColor` falls back to black for any reference to pixel 9 (panel bg), pixel 14 (LCD bg), etc. Result before fix: entire calculator paints black. ColorTable's init now seeds pixels 1..23 with a hardcoded approximation of the CDE "Default" colour scheme. Hardcoded values; no runtime palette switching.

## What's still broken — Motif widget chrome

dt-apps render their containers, LCD area, and any window with explicit non-bg `BackPixel`. The deep button hierarchy renders as flat panels with no button shadows or labels visible.

Gold-vs-swiftx trace diff (2026-05-10):

| event/op | gold | swiftx | ratio |
|---|---|---|---|
| Expose events s2c | 7 | 451 | gold sparse, ours floods |
| PolyText8 c2s | 86 | 0 | gold draws labels, we get none |
| PolyFillRectangle c2s | 311 | 20 | gold fills shadows, we get none |
| PolySegment c2s | 367 | 211 | partial |
| CopyArea c2s | 75 | 9 | gold uses backing pixmaps |

dtcalc receives our flood of Expose events on the button hierarchy but emits zero drawing requests in response. Drawing only happens for windows dtcalc itself drives via `XClearArea(exposures=true)` — Motif's button redraw isn't firing on the Map-induced Exposes we synthesize.

### Leading hypothesis (not verified)

Real Sun X servers track per-window visibility regions. When MapWindow makes a subtree viewable, the server only emits Expose for the *truly visible* regions — child windows that fully cover their parent leave the parent's covered area without an Expose. Our X server has no visibility tracking; we emit Expose for every mapped descendant on `mappedDescendantSnapshots`. Motif's PushButton redraw, tuned against the sparse gold Expose pattern, treats our flood as spurious and skips drawing.

Alternative possibility: Motif gates the redraw on a different event we never emit — `VisibilityNotify` (gold=2, ours=0) is the most plausible candidate. Worth checking before doing real visibility tracking.

### Fix not pursued this round

Two paths:

1. **Real visibility tracking.** Walk window tree, compute per-window visible regions (intersection of parent's visible region minus higher-stacked siblings minus children's covered regions), emit Expose only for the visible parts. Adds region arithmetic + stacking-order tracking. Substantial work.

2. **Test the VisibilityNotify hypothesis.** Emit `VisibilityNotify(unobscured)` for each newly-viewable top-level + descendants with VisibilityChangeMask. ~30 lines. May or may not satisfy Motif's redraw gate.

Path 2 is the cheap experiment to try first if revisiting.

## Per-app scorecard (verified 2026-05-10 from u5 CDE session)

| App | Renders | Buttons visible | Input | Notes |
|---|---|---|---|---|
| dtcalc | yes | no | mouse hover registers | LCD shows "0.00" |
| dtterm | yes | no | not tested | flat panel |
| dthelpview | yes | no | not tested | flat panel |
| dticon | yes | no | not tested | flat panel |
| dtpad | no | — | — | u5-side: missing ttsession (ToolTalk daemon) |
| dtmail | not tested | | | likely same as others |
| dtfile | not tested | | | likely same as others |
| quickplot (SS2) | yes | yes | **clicks fire, menus post, dialogs open** (2026-05-10) | menu-placement bug, text spacing odd, idle poll loop, see memory note |

## What didn't help

- `_MOTIF_WM_INFO` root property advertising a fake MWM (libXm reads this for `XmIsMotifWMRunning`). Set but apparently dt-apps don't gate on it.
- `RESOURCE_MANAGER` root property with `*customization: -color`. Set but no observable effect.
- Pre-setting SDT Pixel Set with empty bytes (dtcalc fell through to ConvertSelection regardless because the only-if-exists InternAtom returned None).

These changes are still in place — harmless, and might matter for dt-apps we haven't tested yet.

## Tools / methodology

- `./run-all.sh` builds swiftx-server + capture proxy, listens on `:6000`, forwards to `:6001`. Edit `connection.json` to change the capture filename.
- `.build/release/swiftx-capture dump <path>` chronological message dump
- `.build/release/swiftx-capture summary <path>` aggregate counts
- Python parser for extracting specific reply bytes from `.xtap`: little-endian frame header (`<Q` ts, `<I` length), big-endian X reply bodies (Sun is MSB-first). See conversation 2026-05-10 for example snippets.
- gold/swiftx pair captures in `captures/`: `dtcalc-sun.xtap` is gold, `dtcalc-swiftx.xtap` is ours.

The capture-and-diff method continues to be the right tool for any new Motif failure. Gold captures pre-2026-05-09 are pre-recorder-I/O-fix and contain artifacts; retake before diffing.

## Useful prior clues (still relevant)

- "Cannot convert string `<Key>...` to type VirtualBinding" stderr was the smoking gun for the SS2 keymap fix. Any keysym-related stderr from a Motif app is worth following.
- SS2 (older OpenWindow libXm) is more strict about protocol than SS5 (newer libXm). Use SS2 as the witness whenever possible.
- Don't try to implement full Motif drag-and-drop coordination. The pre-set `_MOTIF_DRAG_WINDOW` workaround is enough to dodge the SS2 init crash.
