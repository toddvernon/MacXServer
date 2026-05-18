# Status 2026-05-18 — End of day

Big day for a different reason than yesterday. The dt-Motif color bug
yesterday looked like a chase through pixel-color resolution and
glyph rendering, and we walked into the diag-log session this morning
expecting to instrument PolyText8 and trace which slot was wrong. The
diag *did* fire and concretely pin the wrong color (fg=(172,172,180),
matching `ColorTable[0x0D]`), but the real win came from stepping back
and asking what Motif was even *doing* listening to a CDE-customization
indirection on a server that isn't actually CDE. The fix landed by
deletion, not by debugging.

## Headline

**Retired the CDE customization daemon impersonation and the
3910-byte CDE-flavored RESOURCE_MANAGER fixture.** Both were
introduced earlier (2026-05-10 and 2026-05-17 respectively) to push
dt-apps past an Xt-wedge symptom that turned out to be our own
MATCH_SELECT-time bug, fixed separately. SS2 publishes neither
(verified against `dtcalc-running-on-u5-display-on-ss2.xtap` —
zero ASCII hits for `background`/`foreground`/`color`/`delphinium`
in the 37 KB S2C stream). With both cut, dtcalc + dtterm + quickplot
all render with full SS2-with-mwm visual parity: Motif fallback blue
panels with crisp white labels on every button. Both yesterday's
headline bugs (invisible grey-on-grey button labels, white-on-white
LCD digits) are gone in one commit.

What stayed: `_MOTIF_DRAG_WINDOW` and `_MOTIF_WM_INFO` — both
pre-CDE mwm-era signals that an SS2-with-mwm session would publish.
The framing that justifies the cut: **be SS2 running plain mwm, not
SS2 running CDE.** mwm-era signals stay; CDE-only signals go.

## Smoke results across the dt-app suite

| App | Result | Versus pre-cut |
|---|---|---|
| dtcalc | Renders correctly, full SS2 parity | invisible labels → readable; LCD digits show |
| dtterm | Terminal renders + works | unchanged (separate CreateCursor crash on Help menu, fixed below) |
| quickplot | Renders, known issues persist | unchanged |
| dthelpview | Window up, no text content | unchanged (pre-existing font issue) |
| dticon | Partial render + TT error | unchanged (same as via capture proxy) |
| dtpad | No display, TT error | unchanged (same as via capture proxy) |
| dtmail | TT dialog | unchanged (same as via capture proxy) |

No dt-app regressed. The "cutting CDE signals might unmask hidden
ToolTalk dependencies" worry did not materialize.

## New thread surfaced — Framer-shared bug

dtpad / dtmail / dticon all work **direct u5 → SS2**. They all
misbehave the same way through **swiftx-capture proxy → SS2** AND
through **swiftx-server**. The only common code between the proxy
and our server is the `Framer` module. So whatever is making these
dt-apps go down a ToolTalk-aware or otherwise-broken code path is
in shared framing logic, not server-only.

Working hypothesis: some opcode's encoding or decoding through Framer
is subtly wrong in a way these specific dt-apps notice but dtcalc /
dtterm / quickplot don't. Likely investigation: capture the same
small dt-app session both direct u5→ss2 and u5→capture→ss2, then
`swiftx-capture diff` the byte streams. Any divergence is the bug.

This is probably the next real blocker. Higher impact than the
Motif text-spacing issues remaining elsewhere.

## CreateCursor (opcode 93) stubbed

dtterm crashed on Help-menu open with
`BadRequest: opcode 93 (X_CreateCursor)`. We never had a Framer
decoder for it (CreateGlyphCursor=94 and FreeCursor=95 were there;
93 was the gap). Added `CreateCursor` struct in
`Sources/Framer/Requests/CreateCursor.swift`, wired the dispatch in
`Request.swift` (case + decode + encode), updated both dumper switches
(`ChronoDumper`, `Dumper`), and added a handler in
`ServerSession.swift` that validates source/mask pixmaps (BadPixmap
on unknown), records the cursor ID in `CursorTable` with sentinel
sourceGlyph=`0xFFFF` so crossing-time NSCursor lookup falls back to
`.arrow`. Custom-pixmap cursor bitmaps are NOT rendered — the cosmetic
cost is that Motif menu resize / busy / drag cursors all show as the
macOS arrow rather than their custom shapes. Documented in SHORTCUTS
and OPCODE_STATUS.

## Ledger updates landed today

- `DECISIONS.md`: new 2026-05-18 entry that retires the 2026-05-10
  customization-daemon decision and the 2026-05-17 RESOURCE_MANAGER
  fixture (the latter wasn't a formal DECISIONS entry at the time,
  closed here).
- `SHORTCUTS.md`: three CDE entries (fake daemon, hardcoded palette,
  hardcoded SDT Pixel Set) moved to **Closed**. The RESOURCE_MANAGER
  entry reworded — no longer publishing a minimal lie; now returns
  spec-correct empty like SS2. New stub-cursor caveat appended to
  the existing cursor entry.
- `OPCODE_STATUS.md`: CreateCursor (op 93) added as impl-stub.

## Test rebaseline

9 `CapturedAppReplayTests` baselines updated: each app's window
count dropped by 1 (the `0xFFFE_0003` daemon stub window is no
longer installed) and atom count dropped by 1 or 2 (depending on
whether the app itself interned `Customize Data:0` / `SDT Pixel Set`
over the wire). `ConvertSelectionTests.testSelectionMediatorDispatchesCorrectly`
had its stub-owner sub-check removed — the production server no
longer auto-installs a stub at init, and the same routing case is
already covered by `testStubDaemonReturnsEmptySelectionNotify` which
manually installs a stub.

**526 tests pass, 4 documented skips, 0 failures.**

## Working tree at end of day

Files changed but not committed:
- `Sources/SwiftXServerCore/ServerSession.swift` (CDE cuts, CreateCursor handler, name switch)
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` (diag log line reverted — yesterday's instrumentation no longer needed)
- `Sources/Framer/Requests/CreateCursor.swift` (NEW)
- `Sources/Framer/Requests/Request.swift` (case + decode + encode)
- `Sources/SwiftXCaptureCore/ChronoDumper.swift` (2 switches)
- `Sources/SwiftXCaptureCore/Dumper.swift` (1 switch)
- `Tests/SwiftXServerCoreTests/CapturedAppReplayTests.swift` (9 baselines)
- `Tests/SwiftXServerCoreTests/ConvertSelectionTests.swift` (stub-case removed)
- `DECISIONS.md`, `SHORTCUTS.md`, `OPCODE_STATUS.md`
- `STATUS.md` (this file)

Reasonable to split into two commits: one for the CDE retirement,
one for the CreateCursor stub. They're independent.

Stray artifacts (decide tomorrow):
- `captures/dtcalc-u5-on-swiftx-v3.xtap` + `.json` — captured this
  morning against the pre-cut server. The grey-palette baseline.
  Probably want a fresh v4 against the post-cut server before
  deleting v3.
- `connection.json` working-tree mod is leftover from earlier
  capture-proxy configuration; check and revert if not needed.

## Tomorrow's recommended starting points, in priority order

1. **Framer-shared bug investigation.** Compare `dtpad` or `dtmail`
   captures: direct u5→ss2 vs u5→capture→ss2. Any byte-level
   divergence in the C2S or S2C stream is the bug. This is probably
   the real next blocker — the framing layer is silently corrupting
   *something* for these specific apps.

2. **Capture a fresh `dtcalc-u5-on-swiftx-v4.xtap`** against the
   post-cut server for the new gold baseline, then delete v3.

3. **Delete the dormant `CDE palette` seeding in `ColorTable.swift`**
   (pixels 1-23) once a few more dt-app smoke runs confirm nothing
   silently still hits those pixel indices.

4. **Delete the commented-out impersonation code** in
   `ServerSession.swift` and the `CDEResourceManagerFixture.swift`
   source file after another round of validation. Currently kept
   commented so re-enabling is a comment-strip.

5. **Motif text-entry / text-widget character spacing.** Lower
   priority than the framer thread; the visible cost is small.

## Reflection

Yesterday's STATUS predicted today would be a focused chase on
foreground-color resolution. The diag log fired exactly as expected
and pointed at pixel 0x0D as the wrong slot. But the path forward
wasn't to fix the slot — it was to step back and ask why Motif was
indirecting through *any* CDE palette on a server that isn't CDE.
The right fix was deletion: stop pretending to be CDE, let Motif
fall back to its built-in defaults, end up looking exactly like SS2.

The architectural framing "be SS2 with mwm, not SS2 with CDE" is
the keeper from today. It explains why we keep `_MOTIF_DRAG_WINDOW`
and `_MOTIF_WM_INFO` (mwm-era), why we cut the customization daemon
and SDT Pixel Set (CDE-only), and why we publish nothing for
RESOURCE_MANAGER (SS2 doesn't either). It should guide future "do
we need to fake X to make Y happy?" calls — only if SS2-with-mwm
would have faked it, no.
