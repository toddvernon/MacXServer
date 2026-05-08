# Product 2: Swift X server

The main event. A real X server in Swift on macOS that real Sun X clients connect to and display correctly, with rendering quality that's a clear step up from XQuartz.

## Status as of 2026-05-07

M1, M2, M3 all shipped and live-verified against xclock running on u5 (a real SPARCstation 2). Static dial renders correctly; user-driven NSWindow resize triggers a clean re-render at the new dimensions.

**Phase 1 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md` shipped same day** (2026-05-07): display-adaptive integer scaling at startup, Core Text scalable font substitution with cell-snapping, ImageText8 + PolyFillRectangle rendering, plus the Xlib-startup replies xterm needs (ListFonts, GetKeyboardMapping, GetModifierMapping, GetPointerMapping, QueryColors, GetSelectionOwner). Captured xterm session (752 requests) replays cleanly through the session.

295/295 tests green. The xclock PoC is fully met; the xterm rendering foundation is in place.

**Live xterm from u5 working as of 2026-05-07.** xterm renders, prompt appears, keys echo (US-ASCII keymap via `USKeymap.swift`), output scrolls when it fills the window (CopyArea + NoExpose follow-up), resize repaints correctly (ConfigureNotify + Expose on descendants, live-resize bracketed via windowDidEndLiveResize). Known cosmetic issue: cursor outline boxes around characters left behind by the cursor PolyLine — not visually-blocking, deferred per the metrics-tightening discussion in `CHATGPT_REVIEW.md`.

**Live xcalc from u5 working as of 2026-05-08.** xcalc connects, renders the calculator panel with button outlines (window borders) and labels (PolyText8), responds to mouse clicks (ButtonPress / ButtonRelease), and the LCD updates with computed values. The arc surfaced and closed: AllocNamedColor (xcalc looks up colors by name; we now embed the full X11R6 rgb.txt and parse hex specs per `libX11/src/ParseCol.c`), PolyText8 (xcalc's only text path), window background + border painting on map (was missing entirely; xcalc's panel + button shapes are stacked colored sub-windows that depend on the X server's "newly viewable" bg fill), ChangeWindowAttributes honoring CWBackPixel + CWBorderPixel, mouse plumbing through FlippedXView → bridge → ServerSession.handleMouseEvent, and Expose emission for ClearArea(exposures=true) and for non-top-level MapWindow (xcalc maps individual digit-toggle subwindows after each click and waits for Expose to draw them). Cosmetic: libX11 prints `Missing charsets in String to FontSet conversion` warnings because we ship `iso10646-1` font variants only — xcalc still renders fine because it falls back to its core font path.

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

**Done when** `xclock` running on u5 against `swiftx-server` doesn't disconnect with a protocol error for 60 seconds.

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

Out of scope for the PoC, listed in expected priority order:

- **Phase 1 of `SERVER_RESOLUTION_SCALING_AND_FONTS.md`: display-adaptive integer scaling + scalable font substitution.** This lands before xterm — the rendering quality bar set in that doc is the actual headline goal of Product 2. Implementation cuts: detect main display at startup, pick logical/scale from preset table, wire `CGAffineTransform` into the backing context pipeline, ship Monaco/Helvetica Neue/Courier New/Andale Mono/Times New Roman/Symbol substitutes, implement cell-snapped `OpenFont`/`QueryFont`/`ImageText8`/`PolyText8`.
- xterm as the next target (depends on the scaling/fonts foundation above): full keyboard mapping, `CopyArea` for scrolling, `GrabPointer`/`GrabKeyboard` for selection, selection bridging
- Cursor handling (X cursor font → macOS NSCursor substitution per the scaling/fonts doc)
- Multi-client support (resource ID isolation per connection)
- Selection bridging (X PRIMARY / CLIPBOARD ↔ NSPasteboard)
- SHAPE and BIG-REQUESTS extensions
- Transport selectability for Product 4 (CrossFeed)

Also worth doing before xterm gets serious (or while building it, as gaps surface):
- Real PseudoColor palette (today's `ColorTable` just synthesises monotonic pixels; M3 PoC works because xclock allocates colors via AllocColor and the bridge resolves them)
- TrueColor 24-bit visual exposed alongside PseudoColor 8-bit (`DECISIONS.md` 2026-05-05 commits to both)
- XErrors emitted for bad requests / unknown resources (today's server is forgiving — see `SHORTCUTS.md`)
- Honour CWBackPixmap, CWBorderPixel, and CWBitGravity (today only CWBackPixel is read, for ClearArea)
- Pointer crossings (EnterNotify / LeaveNotify) — xclock didn't need them; xterm will

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

- Single NSView per top-level X window. The X window subtree is internal to the server, with drawing clipped against subwindow geometry.
- Synthetic monotonic pixel allocation for AllocColor in PseudoColor mode. A real palette implementation is post-PoC.
- Core Text + lie for font handling, deferred until xterm. xclock works with stub QueryFont because it never draws text.
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

## What this isn't

PRODUCT_1's `replay` subcommand is not the testing tool for Product 2. Replay is a framer smoke test. Product 2 testing is done with live Sun clients (M1-M3 verification) and with replay-into-the-server-library for unit tests (where the server is what's under test, not the framer).
