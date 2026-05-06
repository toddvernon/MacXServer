# Product 2: Swift X server

The main event. A real X server in Swift on macOS that real Sun X clients connect to and display correctly, with rendering quality that's a clear step up from XQuartz.

## Goal for the proof of concept

Run xclock from a real Sun (u5) against the Swift X server. The clock displays. The hands tick. It's a window on the Mac with native chrome. The user can close it via the macOS close button and xclock exits cleanly.

xclock is the smallest possible target that exercises connection setup, resource creation, drawing primitives, mapping, exposes, the close protocol, and the NSWindow integration. Everything bigger is a strict superset.

The reference for what xclock does on the wire is `captures/xclock_transcript.md`.

## Milestones

### M1: xclock connects and stays connected

Server listens on `:6000`. On connect:

1. Read SetupRequest via the framer.
2. Send a hardcoded SetupAccepted: one screen, one PseudoColor 8-bit visual, one pixmap format, vendor "swift-x", a fabricated resource-id-base.
3. For every C2S request that arrives, parse it via the framer.
4. Send stub replies for the requests xclock waits on: GetProperty (empty), AllocColor (synthetic pixel), InternAtom (monotonic), QueryFont (minimal valid stub), GetInputFocus.
5. Track resources internally (windows, GCs, pixmaps, fonts, atoms) but don't render anything.

**Done when** `xclock` running on u5 against `swiftx-server` doesn't disconnect with a protocol error for 60 seconds.

**Out of scope for M1:** any rendering, any NSWindow, any input handling, any events fired beyond the immediate handshake.

### M2: empty window appears

When the client maps a top-level window (CreateWindow with parent=root, then MapWindow on it), the server creates a real NSWindow on the Mac. Window has the right dimensions, title from WM_NAME, and disappears when the client disconnects.

Send back the events the client expects after MapWindow:
- ConfigureNotify with the actual NSWindow position
- ReparentNotify (synthesized; the NSWindow's frame view as the synthetic parent ID)
- MapNotify
- Expose covering the full window region

Drawing requests are accepted but still don't render — the window stays blank.

**Done when** mapping an X window produces a correctly-sized blank NSWindow on the Mac with native chrome and the right title.

### M3: clock face renders

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

### Beyond M3

Out of scope for the PoC, listed in expected priority order:

- xterm as the next target (text rendering, keyboard input, selections)
- Cursor handling (X cursor font → macOS substitution)
- Real font handling (Core Text + lie strategy per `DECISIONS.md`)
- Multi-client support (resource ID isolation per connection)
- Selection bridging (X PRIMARY / CLIPBOARD ↔ NSPasteboard)
- SHAPE and BIG-REQUESTS extensions
- Transport selectability for Product 4 (CrossFeed)

## Resource design

These are the X11 resource types the server has to model. The PoC needs the first six.

| Resource | M1 | M2 | M3 |
|---|---|---|---|
| Atom | monotonic; same name → same ID | unchanged | unchanged |
| Window | tracked internally | top-level → NSWindow | full subtree, drawing target |
| Pixmap | accepted, stored, never read | unchanged | unchanged |
| GC | tracked, attributes stored | unchanged | translated to CG state at draw time |
| Font | accepted, stub QueryFont | unchanged | unchanged (xclock doesn't draw text) |
| Colormap | synthetic pixels | unchanged | pixels → RGB at draw time |

Decisions that hold across M1-M3 (per `DECISIONS.md`):

- Single NSView per top-level X window. The X window subtree is internal to the server, with drawing clipped against subwindow geometry.
- Synthetic monotonic pixel allocation for AllocColor in PseudoColor mode. A real palette implementation is post-M3.
- Core Text + lie for font handling, deferred until xterm. xclock works with stub QueryFont because it never draws text.
- Cursor substitution via macOS standard cursors, deferred until any app actually changes cursors.

## Package layout

Adding to the existing Swift package, no new package:

```
swift-x/
  Sources/
    Framer/                 (existing, unchanged)
    SwiftXCapture/          (existing, unchanged)
    SwiftXCaptureCore/      (existing, unchanged)
    SwiftXServer/           NEW: executable, the server itself
    SwiftXServerCore/       NEW: library, server logic (so tests can drive it)
  Tests/
    SwiftXServerCoreTests/  NEW
```

The `Core` split mirrors Capture: the executable is a thin shell; the library is what we test.

## Testing strategy

- **Unit tests on the server core.** Drive the server library with byte sequences from the corpus (`captures/*.xtap`) and assert it produces expected replies, events, resource state. The framer's encode/decode is already trusted (corpus round-trip test passes); we're now testing that the server's *response* to a known input is correct.
- **The xclock capture as integration fixture.** Replay xclock's C2S bytes into the server library; assert specific resources get created, specific events get sent, specific drawing happens.
- **Live tests against u5.** The real ground truth. Run the server, point u5's xclock at it, observe.

The reason replay-as-test makes sense here when it didn't make sense for testing the framer: the framer was already-correct against the corpus; the *server* is the new thing. Replaying captured C2S into the server tests the server's output, which we have ground-truth for from the original capture.

## Order of work for M1

1. Add `SwiftXServer` and `SwiftXServerCore` targets to `Package.swift`. Empty stubs. Build green.
2. Set up TCP listener (similar to `SwiftXCaptureCore/Proxy.swift` but listen-only, no forward).
3. On connect: read enough bytes for the SetupRequest, parse via framer, build a hardcoded SetupAccepted, send.
4. Sequence-numbered request reader. After SetupRequest, every incoming chunk is one or more requests of variable length; parse the request length from bytes 2-3 and slice.
5. Per-opcode handler dispatch. For M1, every opcode is either: ignore (no reply needed), or stub-reply.
6. Live test against xclock on u5.

## What this isn't

PRODUCT_1's `replay` subcommand is not the testing tool for Product 2. Replay is a framer smoke test. Product 2 testing is done with live Sun clients (M1 verification onward) and with replay-into-the-server-library for unit tests (where the server is what's under test, not the framer).
