# Status 2026-06-09

Motif move-during-menu corruption bug fixed end to end. The bug had
two layers — a spec-compliance miss in our grab state machine, and a
missing rootless-WM emulation of the hardware pointer grab. Both
landed today, plus the Mac-UX polish so the dismiss-and-drag
gesture feels atomic.

## What landed today

### Motif menu position corruption (root cause + UX layer)

**Observed**: Open a Motif menubar pulldown (dtcalc, dtpad). Move
the main window while the menu is up. Every subsequent menu
invocation from any cascade button pops up at the OLD window
position, forever. Survives across menu picks until app restart.

**Investigation path**:

1. First hypothesis was the synthetic ConfigureNotify (ICCCM 4.1.5)
   path was broken. It wasn't — we emit the event on every
   `windowDidMove`, encoded with the `0x80` synthetic bit, with
   correct root coords. `XtTranslateCoords` would have read the
   right shell `core.x/core.y`.
2. Real cause surfaced from a wire capture (`/tmp/macxcapture/`).
   On a Motif menubar click, the actual grab sequence is:
   - ButtonPress on menubar → our server installs an **implicit
     grab** (X11 spec: first ButtonPress with no other grab
     auto-installs one). Our `implicitGrab=true` flag set.
   - Motif issues `XGrabKeyboard` then `XGrabPointer` to take
     over the menu shell. Our `handleGrabPointer` saw
     `alreadyGrabbed=true` and did the right thing for the
     cursor/tracker but **did not clear `implicitGrab`**.
   - User releases the menubar button. Our implicit-grab release
     branch (`if !isDown && heldButtons.isEmpty && implicitGrab`)
     fired and tore down `pointerGrab` even though Motif's
     explicit grab was logically still in force.
   - With the server-side grab gone, the user could drag the Mac
     title bar (AppKit owns it; nothing was blocking the move).
     Each drag emitted synthetic ConfigureNotify — but Motif had
     other state machinery that snapshotted root coords at
     post-time and didn't re-key on the events queued during a
     `XtAppNextEvent` filtered to button/keyboard masks.

   Per X11 spec §11.4: an explicit `XGrabPointer` *replaces* any
   implicit grab. Release is via `XUngrabPointer` only.

**Fix layer 1 — spec compliance**: in `handleGrabPointer`,
unconditionally clear `implicitGrab = false` after the grab is
installed. One line + comment block. Safe regardless of prior
state (implicit, explicit, or none).

**Fix layer 2 — rootless emulation of the hardware pointer grab**:
real X11's pointer grab is server-wide and hardware-rooted, so the
WM's title-bar widget never sees a click while a menu shell holds
a grab. On our Mac, AppKit owns the title bar independently of
our X event pipeline; even with the spec-compliance fix, a fast
user could still drag during the brief grab window. The new
`WindowBridge.lockNativeWindowDrag(token:)` /
`unlockNativeWindowDrag(token:)` ref-counted lock blocks native
drag for the duration of any X-protocol pointer grab — passive
activation, implicit, or explicit. `CocoaWindowBridge.applyNativeDragLock`
sets `NSWindow.isMovable=false` on every session window and toggles
a new `MotifFrameView.isDragLocked` flag that short-circuits the
chrome's `mouseDown` before `dragOrigin` / `resizeEdge` get seeded.
On session disconnect, `removeHandlers(token:)` drops the token's
lock contribution so a mid-grab disconnect can't strand any
window non-movable.

**Layer 3 — Mac UX polish (chrome click dismisses + same gesture
drags)**: a real X11 user accepts the two-click pattern (first click
dismisses the menu, second click drags). On Mac the user expects
the gesture to be atomic. New flow on chrome click during grab:
- `MotifFrameView.mouseDown` fires `outsideGrabClickHandler` with
  the click in clientView-local coords (negative — well outside
  the popup geometry).
- Bridge synthesizes a ButtonPress + ButtonRelease pair to the X
  client. Motif's outside-popup detector dismisses regardless of
  whether it triggers on press or release.
- Bridge calls `releaseNativeWindowDragImmediate()` — clears the
  lock map and tears down the cross-window drag tracker on the
  spot, without waiting for the X client's `XUngrabPointer`
  round-trip.
- `MotifFrameView` seeds `dragOrigin` / `dragWindowOrigin` for
  title-drag clicks (skipped for resize-edge clicks) so the
  user's continuing `mouseDragged` events flow to the normal
  drag path. When `XUngrabPointer` eventually arrives, the
  session's matched `stopCrossWindowDragTracking` /
  `unlockNativeWindowDrag` calls hit zeroed state and safely
  no-op.

### Touched / new

- `Sources/SwiftXServerCore/WindowBridge.swift` — protocol gained
  `lockNativeWindowDrag(token:)` / `unlockNativeWindowDrag(token:)`
  with default no-op impls so mocks pick them up free.
- `Sources/SwiftXServerCore/CocoaWindowBridge.swift` — per-token
  lock map, `applyNativeDragLock`, `releaseNativeWindowDragImmediate`,
  `outsideGrabClickHandler` wiring on `MotifWindow` creation,
  lock cleanup in `removeHandlers(token:)`.
- `Sources/SwiftXServerCore/ServerSession.swift` — `implicitGrab=false`
  spec fix in `handleGrabPointer`; `lockNativeWindowDrag` /
  `unlockNativeWindowDrag` calls at every `pointerGrab` transition
  (passive activation, implicit grab install/release, explicit
  `XGrabPointer`, `XUngrabPointer`).
- `Sources/SwiftXServerCore/MotifFrame/MotifFrameView.swift` —
  `isDragLocked` flag, `outsideGrabClickHandler` callback,
  mouseDown short-circuit with synth-click + seed-drag-origin
  for atomic gesture.
- `.claude-memory/reference_implicit_grab_replaced_by_explicit.md`
  — saved the spec-semantics gotcha so future grab-lifecycle code
  doesn't re-learn this the hard way.

### What's working

- Motif menus stay at correct position across window moves
  (verified live against dtpad).
- Title-bar click during menu = menu dismisses immediately.
- Title-bar click-and-drag during menu = menu dismisses AND
  window moves in the same physical gesture (Mac-native UX).
- 1262 tests green.

### Known gaps (not blocking)

- Native title-bar windows (Motif Frame OFF) only get the
  `isMovable=false` layer of the protection — clicks on the
  native title bar during a grab do nothing (no dismiss). Mac
  muscle memory wouldn't try this, but it's a behavioral gap
  vs Motif Frame ON. Closing it needs an `NSEvent` local
  monitor on `mouseDown` that filters by hit-tested area
  (chrome vs FlippedXView). Left for a future session.
- Orphan xterm menu (the second bug reported today) wasn't
  separately verified. Likely fixed by the same
  implicit-grab-replaced-by-explicit clear since xterm's
  right-click menu uses the same `ButtonPress → XGrabPointer`
  upgrade pattern. Recheck next session.

## What to do next

1. Verify orphan xterm menu is gone (xterm right-click, dismiss,
   look for stranded popup).
2. Decide whether the native-title-bar gap is worth closing now
   or after the public release.
3. Resume public-release-plan execution (Phase 0 multi-Mac CLAUDE
   split → Phase 1 license/attribution/hostname sweep). Today's
   bugfix landed on `main`; nothing about the release path was
   touched.
