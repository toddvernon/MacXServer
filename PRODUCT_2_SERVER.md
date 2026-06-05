# Product 2: Swift X server

The main event. A real X server in Swift on macOS that real Sun X clients connect to and display correctly, with rendering quality that's a clear step up from XQuartz.

## Status as of 2026-05-30

For day-by-day progress see `STATUS.md`. Highlights since 2026-05-09:

- **CDE dt-apps + Motif boot end-to-end** (2026-05-10 → 05-18). MATCH_SELECT-time fix was the actual unlock.
- **Server bg-paint contract honored end-to-end** (2026-05-19): clipping + paint-on-grow + GCState bg default.
- **x11perf 254/254** (2026-05-22) + 69 new error-path tests catching 6 silent-drop bugs.
- **Optional Motif WM frame** (2026-05-24) -- opt-in via Preferences → Display.
- **Resize architecture landed** (2026-05-25, see DECISIONS) -- minimal-spec position, matching XQuartz's 20-year-old consensus.
- **Root-window properties moved to ServerCoordinator** (2026-05-27) -- oldest architectural bug, unblocked Motif clipboard cross-session copy/paste.
- **Remote app launcher** (2026-05-27) -- telnet → vintage Sun → DISPLAY+launch from a Mac menu.
- **Configurable Motif frame chrome** (2026-05-27) -- `[motif-frame]` section in `~/.macxserver-resources`.
- **SHAPE extension** (2026-05-28) -- major opcode 128; oclock round + xeyes oval; Motif-frame integration for shaped clients. Bounding-on-top-level visual; clip + descendant shape stored but not yet rendered (SHORTCUTS).

## Status as of 2026-05-09

**M1–M3 shipped 2026-05-07**, live-verified against xclock on u5 (real SPARCstation 2). 296/296 tests green.

**Live xterm and xcalc from u5 working** (2026-05-07 / 2026-05-08). Full keyboard via US-ASCII keymap, scrollback via CopyArea, resize, ANSI colors. xcalc renders panels and labels via PolyText8, mouse clicks update the LCD. Required filling in: AllocNamedColor with embedded X11R6 rgb.txt, window-bg + border painting on map, CWBackPixel/CWBorderPixel, ButtonPress/Release plumbing, Expose-on-ClearArea(exposures=1) and Expose-on-mapDescendant.

**Cut/paste both directions** (2026-05-08). PRIMARY selection roundtrips: xterm SetSelectionOwner → on Cmd-C the session SelectionRequests STRING into a server pseudo-window, intercepts the ChangeProperty, pushes to NSPasteboard. Two trigger modes in Preferences (Mac behavior, Xterm behavior). Limits: PRIMARY only, STRING only, no INCR.

**Real Mac app shell** (2026-05-08). `setActivationPolicy(.regular)` for top menu bar; status item shows the resolved IP for `xterm -display`; tabbed Preferences window persisting via UserDefaults.

**Multi-client server** (2026-05-08). Per-connection read+write thread pair via `Listener.runAccepting`. `ServerCoordinator` owns the cross-session AtomTable + selection-owner table; per-session state (windows/GCs/props/fonts/pixmaps/colors) stays per-session. Bridge's setOnX handlers fan out to every registered session.

**Per-session log files + WM_CLASS** (2026-05-08). One `FileLogSink` per connection writing to `~/Library/Logs/macxserver/`, renamed to `<instance>-<timestamp>.log` once WM_CLASS arrives. WM_CLASS instance also prepended to the NSWindow title.

**Phase 1 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md`** (2026-05-07) and the **font-fit fix** (2026-05-09). Display-adaptive integer scaling, scalable Mac font substitution. Final cell-sizing rule per `DECISIONS.md` 2026-05-09: integer pointSize, CTFont-derived metrics, cell follows font (XLFD's named cell becomes a hint). xterm and xcalc render crisply with no "feels bold" residue. See `XTERM_FONT_QUALITY.md` for the empirical alias map.

## Goal for the proof of concept

Run xclock from a real Sun (u5) against the Swift X server. The clock displays. The hands tick. It's a window on the Mac with native chrome. The user can close it via the macOS close button and xclock exits cleanly.

xclock is the smallest possible target that exercises connection setup, resource creation, drawing primitives, mapping, exposes, the close protocol, and the NSWindow integration. Everything bigger is a strict superset.

The reference for what xclock does on the wire is `captures/xclock_transcript.md`.

## Milestones

### M1: xclock connects and stays connected — DONE 2026-05-07

Server listens on `:6000`. On connect:

1. Read SetupRequest via the framer.
2. Send a hardcoded SetupAccepted: one screen, one PseudoColor 8-bit visual, one pixmap format, vendor "swift-x", a fabricated resource-id-base.
3. For every C2S request that arrives, parse it via the framer.
4. Send stub replies for the requests xclock waits on: GetProperty (empty), AllocColor (synthetic pixel), InternAtom (monotonic), QueryFont (minimal valid stub), GetInputFocus.
5. Track resources internally (windows, GCs, pixmaps, fonts, atoms) but don't render anything.

**Done when** `xclock` running on u5 against `macxserver` doesn't disconnect with a protocol error for 60 seconds.

**What shipped:** `Sources/SwiftXServerCore/ServerSession.swift` is the per-connection state machine. SetupRequest handshake works for both byte orders with partial-buffer tolerance. Per-opcode dispatch covers every request xclock issues. Stub replies for GetProperty, AllocColor, InternAtom, QueryFont, GetInputFocus, QueryExtension. Resource tables for windows, GCs, pixmaps, fonts, atoms, colors, properties (`ResourceTables.swift`, `AtomTable.swift`, `ColorTable.swift`). The `XclockReplayTests` test feeds the captured xclock C2S byte stream through the session and asserts no XErrors and expected resource counts.

### M2: empty window appears — DONE 2026-05-07

When the client maps a top-level window (CreateWindow with parent=root, then MapWindow on it), the server creates a real NSWindow on the Mac. Window has the right dimensions, title from WM_NAME, and disappears when the client disconnects.

Send back the events the client expects after MapWindow:
- ConfigureNotify with the actual NSWindow position
- ReparentNotify (synthesized; the NSWindow's frame view as the synthetic parent ID)
- MapNotify
- Expose covering the full window region

Drawing requests are accepted but still don't render — the window stays blank.

**Done when** mapping an X window produces a correctly-sized blank NSWindow on the Mac with native chrome and the right title.

**What shipped:** `CocoaWindowBridge.swift` owns one NSWindow per top-level X window via the `WindowBridge` protocol. NSApplication runloop drives AppKit on main; the `Listener` runs read and write socket threads on background queues. ReparentNotify (with a synthetic parent ID) + ConfigureNotify + MapNotify on the top-level emit in order, plus Expose on the top-level *and* each already-mapped descendant whose event mask has ExposureMask. xclock's inner window registers ExposureMask, so it gets the Expose and starts drawing. WM_NAME and WM_ICON_NAME ChangeProperty calls update the NSWindow title (with trailing-null stripping). `WindowBridgeTests` covers the bridge contract; `MockWindowBridge` lets unit tests run without a Cocoa runloop.

### M3: clock face renders — DONE 2026-05-07

CreateWindow on a non-root parent creates an internal X window node, not an NSView. The single top-level NSWindow has one NSView for its content; drawing requests against any X window in that subtree render into the NSView, clipped against the X window geometry.

Drawing primitives implemented (in this order of priority for xclock):

- PolySegment (the 60 minute ticks)
- FillPoly (hand bodies, convex)
- PolyLine (hand outlines, dial details)
- ClearArea (for the erase-before-redraw step on resize)
- ConfigureWindow on a non-top-level window (the child resize on parent resize)

Render via Core Graphics into the NSView's backing layer.

Send Expose events when:
- A window is first mapped
- ConfigureWindow changes a window's size

**Done when** xclock running on u5 displays a correct analog clock on the Mac, the hands tick on the minute, and a user resize on the macOS window propagates correctly so xclock redraws at the new size.

**What shipped:**
- `GCState.swift` materialises a typed GC state (foreground / background / line-width / fill-rule) from the raw mask+valueList stored in `GCEntry`.
- `ServerSession` resolves a drawable to its top-level ancestor and offset (`topLevelAndOffset`), translates request coordinates, and resolves pixel values to RGB16 via `ColorTable`.
- `CocoaWindowBridge` runs all CGContext drawing on the main thread, into a `FlippedXView` whose backing CGBitmapContext uses top-left origin (per `RENDERING_DESIGN.md`).
- PolySegment / PolyLine / FillPoly / ClearArea all draw via CGContext per the per-opcode mapping in `RENDERING_DESIGN.md`.
- M3 part-b (resize): `NSWindowDelegate.windowDidResize` resizes the FlippedXView's backing context, updates `WindowTable`, and emits ConfigureNotify on the top-level. xclock responds with ConfigureWindow on its inner drawing window; the session emits Expose to descendants with ExposureMask, and xclock cleanly redraws at the new size.
- `WindowTable` is NSLock-protected since both the read thread and the Cocoa main thread now mutate it.
- `DrawingDispatchTests` covers coordinate translation + GC + color resolution. `ResizeHandlingTests` covers the resize path. `XclockReplayTests` proves the captured xclock byte stream replays cleanly with the right map and expose events.

### Beyond M3

Things still on the list (most of Beyond-M3 from earlier drafts has shipped — see status above):

- Real PseudoColor palette (today's `ColorTable` synthesises monotonic pixels)
- TrueColor 24-bit visual alongside PseudoColor 8-bit (`DECISIONS.md` 2026-05-05)
- XErrors for bad requests / unknown resources (today's server is forgiving — see `SHORTCUTS.md`)
- Honour CWBackPixmap and CWBitGravity (today only CWBackPixel and CWBorderPixel are read)
- ~~SHAPE extension~~ (shipped 2026-05-28; bounding-on-top-level visual). BIG-REQUESTS deferred (no client we host needs it; see SHORTCUTS).
- CLIPBOARD selection (today only PRIMARY is wired)
- INCR transfer for selections larger than the request-size limit

## dt-app coverage matrix (as of 2026-05-18)

Built from the local CDE source (`reference/cde/cde/`) by grepping each
app's main entry and TT init code paths. The split between "works on
swiftx" and "doesn't" tracks how each app handles ToolTalk init failure,
not anything about our X server's protocol coverage — for the apps that
present, our protocol implementation is sufficient.

| App | TT dependency | Bypass available? | Status on swiftx |
|---|---|---|---|
| dtcalc | None | N/A | Works (verified 2026-05-18) |
| dthelpview | None | N/A | Works (font rendering issue separate) |
| dthello | None | N/A | Untested, expected to work |
| dtaction | None | N/A | Untested, expected to work |
| dtterm | Optional | `-standAlone` flag; default-fresh launches also bypass via `attrs.serverId` check (`DtTermMain.c:432,799,1311`) | Works (verified 2026-05-18) |
| dtpad | Default-fatal | `-standAlone` flag (`main.c:178,205`; `fileCB.c:644,787`) | Works with `-standAlone` (verified 2026-05-18) |
| dtfile | Optional-graceful | No flag, but `ToolTalkError` in `dtfile/ToolTalk.c:191` has explicit `case TT_ERR_NOMP` that removes the TT input handler and continues. Works iff ttsession's RPC roundtrip returns NOMP rather than PROCID. | Untested; likely works if ttsession returns the right error code |
| dticon | Fatal-on-failure | None — `main.c:304-306` calls `DieFromToolTalkError(..., "Exiting ...")` | Cannot bypass |
| dtmail | Fatal-on-failure | None — `RoamApp.C:429,567,1231,1267` calls `dieFromTtError(...)` | Cannot bypass |
| dtsession | Fatal — IS the session manager | N/A | Not a target (we don't host it) |

Bottom line for project scope:

- **In scope, working today**: dtcalc, dthelpview, dthello, dtaction, dtterm, dtpad (with `-standAlone`)
- **In scope, plausibly fixable**: dtfile (the path exists; depends on the u5-side ttsession RPC behavior, which is mostly out of our hands)
- **Out of scope, written off**: dticon, dtmail (no bypass in source; would require running `ttsession` on the Mac, which is huge scope for a feature the project doesn't actually need)

Two interesting things falling out of this:

1. **dtterm doesn't actually need `-standAlone` for fresh-launch.** The source check is `if (attrs.standAlone || !attrs.serverId)` — without a server-mode invocation (`-server` flag), the second branch fires anyway. Today's smoke-test where dtterm worked without any flag is consistent with this.

2. **dtfile is the surprise.** It has a real `TT_ERR_NOMP` graceful-degradation branch. The reason it currently fails (or might) on swiftx isn't anything about our X server — it's downstream in the RPC handshake between u5's ttsession and dtpad/dtfile/etc.

## Resource design (as shipped)

These are the X11 resource types the server models. All six required for the PoC are in place; rows describe what landed.

| Resource | What's there |
|---|---|
| Atom | `AtomTable` — monotonic IDs starting at 69, predefined 1-68 baked in, name-stable across calls |
| Window | `WindowTable` — full subtree, NSLock-protected; top-level → NSWindow via `CocoaWindowBridge`; drawing translates descendant coords to top-level via `topLevelAndOffset` |
| Pixmap | `PixmapTable` — id/depth/dimensions tracked; bytes from PutImage are dropped (xclock's icon pixmaps aren't used in rootless mode) |
| GC | `GCTable` + `GCState` — raw mask+valueList stored, materialised to typed state on demand; foreground / background / line-width / fill-rule honoured |
| Font | `FontTable` — name stored, no Core Text mapping yet; QueryFont returns a stub reply (xclock doesn't render text) |
| Colormap | `ColorTable` — synthetic monotonic pixels from 16 with `pixel → RGB16` cache for draw-time resolution; black + white pre-seeded |

Decisions that hold (per `DECISIONS.md`):

- Single NSView per top-level X window. The X subtree is internal to the server, with drawing clipped against subwindow geometry.
- Synthetic monotonic pixel allocation for AllocColor in PseudoColor mode. A real palette implementation is post-PoC.
- Core Text scalable substitutes for fonts, with cell-fits-font (2026-05-09): integer pointSize, CTFont-derived metrics, named XLFD cells become hints not contracts.
- Cursor substitution via macOS standard cursors, deferred until any app actually changes cursors.

## Package layout (as shipped)

```
swift-x/
  Sources/
    Framer/                 (existing — gained 3 reply encoders for M1)
    SwiftXCapture/          (existing, unchanged)
    SwiftXCaptureCore/      (existing, unchanged)
    SwiftXServer/           executable; thin CLI + NSApplication runloop
    SwiftXServerCore/       library: ServerSession, resource tables, bridges
  Tests/
    SwiftXServerCoreTests/  unit tests for the library
```

The `Core` split mirrors Capture: the executable is a thin shell; the library is what we test. `SwiftXServerCore` imports AppKit for `CocoaWindowBridge` / `FlippedXView`; the rest of the module (session, resource tables, bridge protocol) is AppKit-free, so unit tests run headless against `MockWindowBridge`.

## Testing strategy (as shipped)

- **Unit tests on the server core.** `SwiftXServerCoreTests` drives the library directly. `MockWindowBridge` records bridge calls so tests run headless. Coverage:
  - `SetupHandshakeTests` — both byte orders, partial-buffer handling
  - `AtomTableTests` — predefined atoms + monotonic interning
  - `WindowBridgeTests` — top-level vs descendant lifecycle, WM_NAME → title, full xclock-replay drives the bridge correctly
  - `DrawingDispatchTests` — coordinate translation through descendant trees, GC + color resolution
  - `ResizeHandlingTests` — top-level resize → ConfigureNotify; descendant ConfigureWindow → Expose if ExposureMask
  - `XclockReplayTests` — feeds the captured xclock C2S byte stream into the session, asserts no XErrors, expected resource counts, byte-for-byte identical output across chunked vs one-shot delivery
- **Live tests against u5.** The real ground truth. Run the server, point u5's xclock at it, observe. M1, M2, M3 (static + resize) all live-verified 2026-05-07.

The reason replay-as-test makes sense here when it didn't make sense for testing the framer: the framer was already-correct against the corpus; the *server* is the new thing. Replaying captured C2S into the server tests the server's output, which we have ground-truth for from the original capture.

Caveat: replayed CreateGC requests reference pixel values the *original* Sun's AllocColor returned (those bytes are baked into the capture). Our `ColorTable` doesn't know those pixels, so it falls back to black. Replay rendering is therefore monochrome by design. Live clients see our AllocColor reply and use our pixel values, so they render in correct colors.

