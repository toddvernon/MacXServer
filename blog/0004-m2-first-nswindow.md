# Post 4: First NSWindow (M2)

**Date range**: May 7, 2026
**One-line elevator**: A real macOS window pops up on the Mac when the X client maps its top-level window. Rootless from day one. The whole bridge between the X protocol's "windowing" abstraction and AppKit's NSWindow lives in a single layer.

## What this post covers

Product 2 milestone M2. The shift from "bytes on the wire" to "pixels on the screen, even if blank." The NSWindow bridge. Synthesizing the post-Map event sequence (ReparentNotify, ConfigureNotify, MapNotify, Expose) that Xlib expects. Rootless as the default mode.

## Setting

M1 shipped earlier the same day. xclock connects and stays connected, all protocol-level stubs fire correctly. Resource tables track every CreateWindow, but no NSWindow yet exists. The X client thinks it's mapped windows; the user sees nothing.

## The architectural decision

Rootless window mode as the primary mode (`DECISIONS.md` 2026-05-05). Each top-level X window becomes a native NSWindow with native macOS chrome.

- Native Mac chrome integrates with Spaces, Mission Control, Cmd-Tab
- Window operations (move, resize, focus) happen at native Mac speed without round-tripping to the client
- This is where we can clearly improve on XQuartz, which has a clunky rootless mode

The compromise: users who want full retro authenticity can run `mwm` on the Sun. The X server sees mwm's reparenting and decoration windows as just more X windows, and they display correctly.

## The WindowBridge protocol

`CocoaWindowBridge.swift` owns one NSWindow per top-level X window via the `WindowBridge` protocol. NSApplication runloop drives AppKit on main; the server's `Listener` runs read and write socket threads on background queues. `MockWindowBridge` lets unit tests run without a Cocoa runloop.

The bridge protocol has methods like:
- `mapTopLevel(id: ..., geometry: ..., descendants: ..., ...)`. create the NSWindow
- `unmapTopLevel(id: ...)`. orderOut
- `paintWindowRects(topLevel: ..., rects: ...)`. fill background
- `setTopLevelWindowTitle(id: ..., title: ...)`. for WM_NAME

The protocol-side dispatcher doesn't know anything about Cocoa. It just calls bridge methods. CocoaWindowBridge translates those calls into AppKit operations. MockWindowBridge records them for tests.

## The post-Map event sequence

When the client maps a top-level window, Xlib expects a specific sequence of events back:
1. `ReparentNotify`. the window has been reparented (synthesized; we use a synthetic parent ID since there's no real WM)
2. `ConfigureNotify`. final geometry confirmation (NSWindow positions the content area at the requested coords)
3. `MapNotify`. window is now mapped
4. `Expose`. content needs drawing

All four go out in that order via `emitMapSequence` in `MockWindowBridge.swift` (shared by Cocoa and Mock bridges so the emission order stays in one place).

Mistakes here are subtle. Wrong order, wrong sequence number, wrong byte format on Expose. the client doesn't always disconnect, but the drawing path goes wrong in ways that look like rendering bugs.

## Descendants and Expose

A subtlety that matters later: when a top-level window is mapped and it has already-mapped descendants (`MapSubwindows` was called before the top-level mapped), each of those descendants whose event mask has `ExposureMask` also needs an Expose. Otherwise xclock's inner drawing window never receives the signal to draw and the clock stays blank.

The bridge accepts a `descendants:` parameter and emits Expose for each one with ExposureMask set. xclock's pattern is: CreateWindow on root (outer), CreateWindow inside (inner), MapSubwindows on outer, MapWindow on outer. When the outer maps, both windows become viewable.

## WM_NAME → NSWindow.title

`ChangeProperty(WM_NAME, ...)` updates the NSWindow title. Trailing nulls in the property bytes are stripped. The bridge's `setTopLevelWindowTitle` is invoked with the resolved string.

Per-session log files take this further later (in M3 / Beyond M3): once `WM_CLASS` arrives, the log filename gets renamed to include the instance, and the NSWindow title gets prefixed with the instance. So `[xclock] My Clock` shows in the title bar instead of just `My Clock`.

## Pivotal moment

The first time `xclock` came up on the Mac as a native NSWindow, with the macOS traffic-light buttons and the title from WM_NAME, sized correctly per the client's geometry. The clock face was blank because M3 wasn't done. but the window was REAL. You could move it, you could close it, the X client did the right thing on close.

## What Todd should add

- The "first window" moment.
- The rootless decision in voice. Why rootless mattered to YOU specifically, not just "it's better." Probably ties to "I want this to feel like a Mac app, not like 1996."
- The mwm-as-compromise framing. You explicitly preserved the retro option. That's a perspective choice worth airing.
- The split between protocol-side and bridge-side. Why this matters for testability, why MockWindowBridge exists, what tests it enables.

## Anchors for fact-check pass

- Files: `PRODUCT_2_SERVER.md` (M2 section), `Sources/SwiftXServerCore/CocoaWindowBridge.swift`, `Sources/SwiftXServerCore/MockWindowBridge.swift`, `Tests/SwiftXServerCoreTests/WindowBridgeTests.swift`
- M2 commit: `4a0dd24` 2026-05-07 "Ship Product 2 M1-M3: xclock renders on swift-x server" (M1+M2+M3 all in one day)
- Decision: Rootless window mode as primary (DECISIONS.md 2026-05-05)
- Decision: No Motif implementation on the Mac side (DECISIONS.md 2026-05-05). relevant because mwm is preserved as the compromise
- The Listener: `Sources/SwiftXServerCore/Listener.swift`
- emitMapSequence: `Sources/SwiftXServerCore/MockWindowBridge.swift:92`

## Working title alternatives

- "M2: a window on the Mac"
- "From bytes to NSWindow"
- "Rootless from day one"
